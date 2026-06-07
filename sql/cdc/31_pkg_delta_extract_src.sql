-- 差分抽出方式: SYS.delta_extract プロシージャ (oracle-src 用) ★Phase1: COMMIT_SCN版
-- LogMiner(DICT_FROM_ONLINE_CATALOG + COMMITTED_DATA_ONLY)で SRC_SCHEMA の
-- コミット済み変更を COMMIT_SCN 基準で抽出し cdc_schema.delta_queue に貯める。
--
-- ★Phase1 改修点（docs/phase1-commit-scn-redesign.md）:
--   G2: 境界を SCN > last_scn から COMMIT_SCN > last_commit_scn へ
--   G3: COMMITTED_DATA_ONLY を有効化（未コミット/ROLLBACK分を除外）
--   - XID / seq_in_tx / change_scn を delta_queue に格納
--
-- アーキテクチャ:
--   XEPDB1 読取  → cdc_schema.delta_extract_state (進捗 = last_extracted_commit_scn)
--   CDB$ROOT     → START_LOGMNR / V$LOGMNR_CONTENTS 収集
--   XEPDB1 書込  → cdc_schema.delta_queue に INSERT
--
-- フェーズ1スコープ: SYSTEM_EVENTS のみ対象（最小構成で貫通確認）
-- 実行ユーザー: SYS AS SYSDBA (CDB$ROOT) / Oracle 12c 互換

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

CONNECT / AS SYSDBA

CREATE OR REPLACE PROCEDURE SYS.delta_extract(
    p_run_name IN VARCHAR2 DEFAULT 'delta_run_01'
)
    AUTHID CURRENT_USER
AS
    TYPE t_change_rec IS RECORD (
        commit_scn NUMBER,
        xid        VARCHAR2(40),
        change_scn NUMBER,
        seq_in_tx  NUMBER,
        table_name VARCHAR2(100),
        operation  VARCHAR2(20),
        sql_redo   VARCHAR2(4000)
    );
    TYPE t_change_tab IS TABLE OF t_change_rec INDEX BY PLS_INTEGER;

    v_changes        t_change_tab;
    v_last_commit    NUMBER;           -- 高位水準点(HW): commitフィルタ基準
    v_mine_start     NUMBER;           -- 低位水準点(LW): START_LOGMNR の採掘開始点
    v_oldest_open    NUMBER;           -- v_end_scn 時点で実行中の最古Txの START_SCN
    v_next_hw        NUMBER;           -- 今回更新後の HW
    v_next_lw        NUMBER;           -- 次回更新後の LW
    v_end_scn        NUMBER;
    v_current_scn    NUMBER;
    v_max_commit     NUMBER := 0;
    v_extract_cnt    NUMBER      := 0;
    v_idx            PLS_INTEGER := 0;
    i                PLS_INTEGER;
    v_pk_val         VARCHAR2(100);
    v_pk_col         VARCHAR2(100);
    v_err_code       NUMBER;
    v_err_msg        VARCHAR2(4000);
    v_container      VARCHAR2(30) := 'CDB$ROOT';

    -- ★全テーブル化: 追跡対象テーブル（cdc_table_catalog の is_active='Y'）
    v_tables         SYS.ODCIVARCHAR2LIST;            -- V$LOGMNR_CONTENTS の SEG_NAME フィルタ用
    v_pk_cols        SYS.ODCIVARCHAR2LIST;            -- 上記と同順の pk_column 配列
    TYPE t_pk_map IS TABLE OF VARCHAR2(100) INDEX BY VARCHAR2(128);
    v_pk_map         t_pk_map;                        -- table_name → pk_column（pk_value抽出ヒント）

    PROCEDURE go_to(p_container IN VARCHAR2) IS
    BEGIN
        IF v_container != p_container THEN
            EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = ' || p_container;
            v_container := p_container;
        END IF;
    END go_to;

    PROCEDURE add_logfiles(p_start_scn IN NUMBER) IS
    BEGIN
        FOR rec IN (
            SELECT NAME AS MEMBER FROM V$ARCHIVED_LOG
            WHERE NEXT_CHANGE# > p_start_scn
              AND STANDBY_DEST = 'NO' AND DELETED = 'NO'
            ORDER BY FIRST_CHANGE#
        ) LOOP
            BEGIN DBMS_LOGMNR.ADD_LOGFILE(rec.MEMBER, DBMS_LOGMNR.ADDFILE);
            EXCEPTION WHEN OTHERS THEN NULL; END;
        END LOOP;
        FOR rec IN (
            SELECT DISTINCT l.MEMBER
            FROM V$LOGFILE l JOIN V$LOG g ON l.GROUP# = g.GROUP#
            WHERE g.STATUS IN ('CURRENT', 'ACTIVE') OR g.NEXT_CHANGE# > p_start_scn
        ) LOOP
            BEGIN DBMS_LOGMNR.ADD_LOGFILE(rec.MEMBER, DBMS_LOGMNR.ADDFILE);
            EXCEPTION WHEN OTHERS THEN NULL; END;
        END LOOP;
    END add_logfiles;

BEGIN
    -- フェーズ1: XEPDB1 で進捗（last_extracted_commit_scn）を取得
    go_to('XEPDB1');

    -- ★HW(commitフィルタ基準) と LW(採掘開始点) を両方読む
    BEGIN
        EXECUTE IMMEDIATE
            'SELECT last_extracted_commit_scn, mine_start_scn ' ||
            'FROM cdc_schema.delta_extract_state WHERE run_name = :1'
        INTO v_last_commit, v_mine_start USING p_run_name;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            EXECUTE IMMEDIATE
                'INSERT INTO cdc_schema.delta_extract_state ' ||
                '(run_name, last_extracted_commit_scn, mine_start_scn, status) ' ||
                'VALUES (:1, 0, 0, ''IDLE'')'
                USING p_run_name;
            COMMIT;
            v_last_commit := 0;
            v_mine_start  := 0;
    END;

    -- 初回（last_commit=0）は現在SCNを起点にする（過去全部は対象外）
    SELECT CURRENT_SCN INTO v_current_scn FROM V$DATABASE;
    IF v_last_commit = 0 THEN
        v_last_commit := v_current_scn - 1;
        v_mine_start  := v_last_commit;   -- LW も同点から開始
        EXECUTE IMMEDIATE
            'UPDATE cdc_schema.delta_extract_state ' ||
            'SET last_extracted_commit_scn = :1, mine_start_scn = :2, baseline_scn = :3 ' ||
            'WHERE run_name = :4'
            USING v_last_commit, v_mine_start, v_last_commit, p_run_name;
        COMMIT;
    END IF;

    v_end_scn := v_current_scn;

    -- ★低位水準点の再算出基礎: v_end_scn 時点で実行中の最古トランザクションの START_SCN。
    --   COMMITTED_DATA_ONLY は Tx の開始レコードが採掘窓に入っていないと再構成できないため、
    --   未コミットの長時間Txがあれば、その開始SCNより前を次回 LW として保持する必要がある。
    --   V$TRANSACTION は XEPDB1 コンテナ内(PDBローカル)の実行中Txを返す。
    BEGIN
        SELECT NVL(MIN(START_SCN), v_end_scn) INTO v_oldest_open FROM V$TRANSACTION;
    EXCEPTION WHEN OTHERS THEN
        v_oldest_open := v_end_scn;   -- 取得不能時は安全側で end_scn（LW前進を抑制しない）
    END;

    -- ★全テーブル化: 追跡対象テーブル一覧と PK 列マップをカタログから読む（XEPDB1）
    --   proc は CDB$ROOT で作成されるため cdc_schema への静的参照は不可 → 動的SQLで読む。
    EXECUTE IMMEDIATE
        'SELECT table_name, pk_column FROM cdc_schema.cdc_table_catalog WHERE is_active = ''Y'''
        BULK COLLECT INTO v_tables, v_pk_cols;
    FOR k IN 1 .. v_tables.COUNT LOOP
        v_pk_map(v_tables(k)) := v_pk_cols(k);
    END LOOP;

    -- HW 基準で「これ以上コミットTxが無い」場合は採掘不要
    IF v_last_commit >= v_end_scn THEN
        go_to('CDB$ROOT');
        RETURN;
    END IF;

    EXECUTE IMMEDIATE
        'UPDATE cdc_schema.delta_extract_state ' ||
        'SET status = ''RUNNING'', last_run_at = SYSTIMESTAMP WHERE run_name = :1'
        USING p_run_name;
    COMMIT;

    -- フェーズ2: CDB$ROOT で LogMiner 起動・収集
    go_to('CDB$ROOT');

    BEGIN
        -- ★採掘窓は LW(mine_start) から開始。HW(last_commit) ではない。
        --   LW は未コミットの最古Tx開始より前に保たれているため、baseline を跨ぐ
        --   長時間Txの開始レコードも採掘窓に含まれ、COMMITTED_DATA_ONLY が正しく再構成できる。
        add_logfiles(v_mine_start);

        -- ★G3: COMMITTED_DATA_ONLY を追加
        --   コミット済みTxだけがコミット順で返る。ROLLBACK/未コミットは除外。
        DBMS_LOGMNR.START_LOGMNR(
            STARTSCN => v_mine_start,
            ENDSCN   => v_end_scn,
            OPTIONS  => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG
                      + DBMS_LOGMNR.NO_ROWID_IN_STMT
                      + DBMS_LOGMNR.COMMITTED_DATA_ONLY
        );

        -- ★G2: COMMIT_SCN 基準で抽出。XID/seq_in_tx を付与。
        FOR rec IN (
            SELECT COMMIT_SCN,
                   XID,
                   SCN AS change_scn,
                   ROW_NUMBER() OVER (
                       PARTITION BY XID ORDER BY SCN, RS_ID, SSN
                   ) AS seq_in_tx,
                   SEG_NAME AS table_name,
                   OPERATION,
                   DBMS_LOB.SUBSTR(SQL_REDO, 4000, 1) AS sql_redo_str
            FROM V$LOGMNR_CONTENTS
            WHERE SEG_OWNER  = 'SRC_SCHEMA'
              -- ★全テーブル化: カタログの追跡対象テーブルに限定
              AND SEG_NAME   IN (SELECT column_value FROM TABLE(v_tables))
              AND OPERATION IN ('INSERT', 'UPDATE', 'DELETE')
              -- 注意: DICT_FROM_ONLINE_CATALOG 使用時、PDBの変更は CON_ID=1 として
              --       報告されるため CON_ID フィルタは使わない（SEG_OWNER で一意）。
              AND COMMIT_SCN > v_last_commit
              AND COMMIT_SCN <= v_end_scn
            ORDER BY COMMIT_SCN, XID, SCN, RS_ID, SSN
        ) LOOP
            v_idx := v_idx + 1;
            v_changes(v_idx).commit_scn := rec.COMMIT_SCN;
            v_changes(v_idx).xid        := rec.XID;
            v_changes(v_idx).change_scn := rec.change_scn;
            v_changes(v_idx).seq_in_tx  := rec.seq_in_tx;
            v_changes(v_idx).table_name := rec.table_name;
            v_changes(v_idx).operation  := rec.OPERATION;
            v_changes(v_idx).sql_redo   := rec.sql_redo_str;
            IF rec.COMMIT_SCN > v_max_commit THEN
                v_max_commit := rec.COMMIT_SCN;
            END IF;
        END LOOP;

        DBMS_LOGMNR.END_LOGMNR;
    EXCEPTION WHEN OTHERS THEN
        BEGIN DBMS_LOGMNR.END_LOGMNR; EXCEPTION WHEN OTHERS THEN NULL; END;
        RAISE;
    END;

    -- フェーズ3: XEPDB1 に戻って delta_queue に INSERT
    go_to('XEPDB1');

    i := v_changes.FIRST;
    WHILE i IS NOT NULL LOOP
        -- PK 値を SQL_REDO から抽出（参照用ベストエフォート。delta_apply は SQL_REDO を直接 replay）。
        -- ★全テーブル化: テーブルごとの PK 列名をカタログマップから引いて動的に抽出。
        --   UPDATE/DELETE の WHERE 句形式 '"<PK>" = <数値>' のみ対応。
        --   未登録テーブル・INSERT(VALUES形式)・非数値PKは NULL 許容。
        v_pk_val := NULL;
        BEGIN
            IF v_pk_map.EXISTS(v_changes(i).table_name) THEN
                v_pk_col := v_pk_map(v_changes(i).table_name);
                IF v_pk_col IS NOT NULL THEN
                    -- LogMiner は数値PKも引用符付き（= '5'）で出力するため引用符をオプション化
                    v_pk_val := REGEXP_SUBSTR(
                        SUBSTR(v_changes(i).sql_redo, 1, 2000),
                        '"' || v_pk_col || '" = ''?(\d+)''?', 1, 1, NULL, 1);
                END IF;
            END IF;
        EXCEPTION WHEN OTHERS THEN v_pk_val := NULL; END;

        EXECUTE IMMEDIATE
            'INSERT INTO cdc_schema.delta_queue ' ||
            '(delta_id, commit_scn, xid, change_scn, seq_in_tx, ' ||
            ' table_name, operation, sql_redo, pk_value) ' ||
            'VALUES (cdc_schema.seq_delta_queue.NEXTVAL, :1, :2, :3, :4, :5, :6, :7, :8)'
            USING v_changes(i).commit_scn, v_changes(i).xid,
                  v_changes(i).change_scn, v_changes(i).seq_in_tx,
                  v_changes(i).table_name, v_changes(i).operation,
                  v_changes(i).sql_redo, v_pk_val;

        v_extract_cnt := v_extract_cnt + 1;
        i := v_changes.NEXT(i);
    END LOOP;

    COMMIT;

    -- ★進捗更新（HW/LW を別々に前進させる）
    --
    -- HW(last_extracted_commit_scn): commitフィルタの基準。
    --   抽出が0件でも end_scn まで進めると、ENDSCN直前にコミットされた未完結Txを
    --   取りこぼす恐れがあるため「実際に抽出した最大commit_scn」を採用する。
    --   0件のときは v_end_scn まで進める（その範囲にコミットTxが無いことが確定）。
    v_next_hw := CASE WHEN v_extract_cnt > 0 THEN v_max_commit ELSE v_end_scn END;
    --
    -- LW(mine_start_scn): 次回の採掘開始点。未コミットの最古Tx開始(v_oldest_open)より
    --   前に保つ。未コミットTxが無ければ HW 直後まで前進してよい。
    --   LEAST により「オープンTxの開始」と「HW+1」のうち小さい方を採る。
    --   ※ v_oldest_open は v_end_scn 時点のスナップショット。これより後に始まったTxは
    --     START_SCN > v_end_scn なので次バッチの採掘窓に自然に含まれ、欠落しない。
    v_next_lw := LEAST(v_oldest_open, v_next_hw + 1);

    EXECUTE IMMEDIATE
        'UPDATE cdc_schema.delta_extract_state ' ||
        'SET last_extracted_commit_scn = :1, mine_start_scn = :2, status = ''IDLE'', ' ||
        '    last_run_at = SYSTIMESTAMP, error_message = NULL ' ||
        'WHERE run_name = :3'
        USING v_next_hw, v_next_lw, p_run_name;
    COMMIT;

    go_to('CDB$ROOT');

    DBMS_OUTPUT.PUT_LINE(
        'delta_extract: extracted=' || v_extract_cnt ||
        ' rows, mine_start=' || v_mine_start ||
        ', commit_scn_range=(' || v_last_commit || ',' || v_next_hw || ']' ||
        ', next_mine_start=' || v_next_lw);

EXCEPTION WHEN OTHERS THEN
    v_err_code := SQLCODE;
    v_err_msg  := SUBSTR(SQLERRM, 1, 4000);
    IF v_container != 'XEPDB1' THEN
        BEGIN go_to('XEPDB1'); EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;
    BEGIN
        EXECUTE IMMEDIATE
            'UPDATE cdc_schema.delta_extract_state ' ||
            'SET status = ''ERROR'', error_message = :1, last_run_at = SYSTIMESTAMP ' ||
            'WHERE run_name = :2'
            USING v_err_msg, p_run_name;
        COMMIT;
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN go_to('CDB$ROOT'); EXCEPTION WHEN OTHERS THEN NULL; END;
    RAISE;
END delta_extract;
/
SHOW ERRORS PROCEDURE SYS.delta_extract;

PROMPT SYS.delta_extract (COMMIT_SCN version) created on oracle-src.
EXIT;
