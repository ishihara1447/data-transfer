-- 差分抽出方式: SYS.delta_extract プロシージャ (oracle-src 用) ★Phase2: SQL_REDO安全性判定版
-- LogMiner(DICT_FROM_ONLINE_CATALOG + COMMITTED_DATA_ONLY)で SRC_SCHEMA の
-- コミット済み変更を COMMIT_SCN 基準で抽出し cdc_schema.delta_queue に貯める。
--
-- ★Phase1 改修点（docs/phase1-commit-scn-redesign.md）:
--   G2: 境界を SCN > last_scn から COMMIT_SCN > last_commit_scn へ
--   G3: COMMITTED_DATA_ONLY を有効化（未コミット/ROLLBACK分を除外）
--   - XID / seq_in_tx / change_scn を delta_queue に格納
--
-- ★Phase2 追加（docs/delta-extract-design.md セクション9）:
--   - LogMiner STATUS/OPERATION_CODE/CSF/INFO/RS_ID/SSN を収集
--   - CSF=1 行の SQL_REDO を連結して sql_redo_assembled CLOB に格納
--   - テーブル分類(replay_category)・直接適用可否(replay_allowed)をアノテート
--   - LOBありテーブル → replay_category='C', replay_allowed='N'
--   - ホワイトリスト登録済みかつ replay_category='A' → replay_allowed='Y'
--   - ホワイトリスト: cdc_schema.redo_replay_whitelist (36_*.sql で管理)
--
-- ★LOB差分反映方式追加（docs/delta-extract-design.md セクション11.5）:
--   - classify_event: replay_category='C' かつ operation='DELETE' の場合は
--     replay_allowed='Y' として即時適用を許可（LOB本体不要・PK指定DELETEは安全）
--   - ただし operation_code 92/93/94（LOB操作）や status_code≠0 は従来どおり 'N'
--   - replay_category は 'C' のまま（分類は維持しつつ適用許可、という意味）
--   - fallback_reason は NULL に（DELETEには LOBフォールバック不要）
--
-- アーキテクチャ:
--   XEPDB1 読取  → cdc_schema.delta_extract_state (進捗)
--   CDB$ROOT     → START_LOGMNR / V$LOGMNR_CONTENTS 収集
--   XEPDB1 書込  → cdc_schema.delta_queue に INSERT
--
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
        commit_scn         NUMBER,
        xid                VARCHAR2(40),
        change_scn         NUMBER,
        seq_in_tx          NUMBER,
        table_name         VARCHAR2(100),
        operation          VARCHAR2(20),
        operation_code     NUMBER,         -- V$LOGMNR_CONTENTS.OPERATION_CODE
        status_code        NUMBER,         -- V$LOGMNR_CONTENTS.STATUS (0=正常)
        info_text          VARCHAR2(4000), -- V$LOGMNR_CONTENTS.INFO
        csf                NUMBER,         -- 0=SQL完結, 1=次行に継続
        rs_id              VARCHAR2(64),   -- V$LOGMNR_CONTENTS.RS_ID
        ssn                NUMBER,         -- V$LOGMNR_CONTENTS.SSN
        sql_redo           VARCHAR2(4000), -- 先頭4000文字（生の1ピース）
        sql_redo_assembled CLOB,           -- CSF連結済み完全SQL
        replay_category    VARCHAR2(1),    -- A/B/C/D/E
        replay_allowed     CHAR(1),        -- Y=直接適用可 / N=禁止
        fallback_required  CHAR(1),        -- Y=LOBフォールバック必要
        fallback_reason    VARCHAR2(4000)
    );
    TYPE t_change_tab IS TABLE OF t_change_rec INDEX BY PLS_INTEGER;

    -- テーブル属性マップ型
    TYPE t_pk_map  IS TABLE OF VARCHAR2(100) INDEX BY VARCHAR2(128);
    TYPE t_char_map IS TABLE OF CHAR(1)     INDEX BY VARCHAR2(128);
    TYPE t_cat_map  IS TABLE OF VARCHAR2(1)  INDEX BY VARCHAR2(128);

    v_changes        t_change_tab;
    v_pk_map         t_pk_map;         -- table_name → pk_column
    v_lob_map        t_char_map;       -- table_name → lob_present ('Y'/'N')
    v_cat_replay_map t_cat_map;        -- table_name → replay_category ('A'/'B'/'C'/'D')
    v_whitelist      t_char_map;       -- table_name → 'Y' (ホワイトリスト登録済み)

    v_tables         SYS.ODCIVARCHAR2LIST;
    v_pk_cols        SYS.ODCIVARCHAR2LIST;
    v_last_commit    NUMBER;
    v_mine_start     NUMBER;
    v_oldest_open    NUMBER;
    v_next_hw        NUMBER;
    v_next_lw        NUMBER;
    v_end_scn        NUMBER;
    v_current_scn    NUMBER;
    v_max_commit     NUMBER      := 0;
    v_extract_cnt    NUMBER      := 0;
    v_idx            PLS_INTEGER := 0;
    i                PLS_INTEGER;
    v_pk_val         VARCHAR2(100);
    v_pk_col         VARCHAR2(100);
    v_err_code       NUMBER;
    v_err_msg        VARCHAR2(4000);
    v_container      VARCHAR2(30) := 'CDB$ROOT';

    -- CSF連結の状態管理
    v_in_csf         BOOLEAN     := FALSE;  -- 現在CSF継続行を処理中か
    v_csf_target     PLS_INTEGER := 0;      -- 連結先の v_changes インデックス

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

    -- イベントごとの replay_category / replay_allowed を判定する
    -- 優先順位: STATUS異常(E) > LOB操作コード(C) > テーブルLOBあり(C) > ホワイトリストA(A) > その他(B/C/D)
    PROCEDURE classify_event(p_idx IN PLS_INTEGER) IS
        v_lob_pres CHAR(1)    := 'N';
        v_cat      VARCHAR2(1) := 'B';
        v_in_wl    CHAR(1)    := 'N';
    BEGIN
        IF v_lob_map.EXISTS(v_changes(p_idx).table_name) THEN
            v_lob_pres := v_lob_map(v_changes(p_idx).table_name);
        END IF;
        IF v_cat_replay_map.EXISTS(v_changes(p_idx).table_name) THEN
            v_cat := v_cat_replay_map(v_changes(p_idx).table_name);
        END IF;
        IF v_whitelist.EXISTS(v_changes(p_idx).table_name) THEN
            v_in_wl := v_whitelist(v_changes(p_idx).table_name);
        END IF;

        IF NVL(v_changes(p_idx).status_code, 0) != 0 THEN
            -- E: LogMiner STATUS 異常（UNSUPPORTED/MISSING_SCN 等）
            v_changes(p_idx).replay_category  := 'E';
            v_changes(p_idx).replay_allowed    := 'N';
            v_changes(p_idx).fallback_required := 'Y';
            v_changes(p_idx).fallback_reason   :=
                'STATUS_CODE=' || v_changes(p_idx).status_code
                || NVL(' INFO=' || v_changes(p_idx).info_text, '');

        ELSIF v_changes(p_idx).operation_code IN (92, 93, 94) THEN
            -- C: LOB操作コード (LOB_WRITE=92 / LOB_TRIM=93 / LOB_ERASE=94)
            -- OPERATION='UPDATE'等と組み合わせて出現し、SQL_REDO直接適用では復元不可
            v_changes(p_idx).replay_category  := 'C';
            v_changes(p_idx).replay_allowed    := 'N';
            v_changes(p_idx).fallback_required := 'Y';
            v_changes(p_idx).fallback_reason   :=
                'LOB_OPERATION_CODE=' || v_changes(p_idx).operation_code;

        ELSIF v_lob_pres = 'Y' THEN
            -- C: テーブルにLOB列あり → 原則 SQL_REDO直接適用禁止
            -- LOB本体はRedoとは別管理のため SQL_REDO で正確に再現できない
            -- ★例外（11.5）: operation='DELETE' は LOB本体不要のため即時適用可。
            --   replay_category は 'C' のまま（分類維持）・replay_allowedのみ 'Y' にする。
            --   ただし LOB操作コード(92/93/94) や STATUS異常は例外から除外済み（上位節で捕捉済み）。
            IF v_changes(p_idx).operation = 'DELETE' THEN
                v_changes(p_idx).replay_category  := 'C';
                v_changes(p_idx).replay_allowed    := 'Y';
                v_changes(p_idx).fallback_required := 'N';
                v_changes(p_idx).fallback_reason   := NULL;
            ELSE
                v_changes(p_idx).replay_category  := 'C';
                v_changes(p_idx).replay_allowed    := 'N';
                v_changes(p_idx).fallback_required := 'Y';
                v_changes(p_idx).fallback_reason   := 'TABLE_HAS_LOB';
            END IF;

        ELSIF v_cat = 'A' AND v_in_wl = 'Y' THEN
            -- A: 直接適用許可 (ホワイトリスト登録済み・LOBなし・STAGING同一構造)
            v_changes(p_idx).replay_category  := 'A';
            v_changes(p_idx).replay_allowed    := 'Y';
            v_changes(p_idx).fallback_required := 'N';
            v_changes(p_idx).fallback_reason   := NULL;

        ELSE
            -- B/C/D: ホワイトリスト未登録 or カタログ分類がA以外
            v_changes(p_idx).replay_category  := v_cat;
            v_changes(p_idx).replay_allowed    := 'N';
            v_changes(p_idx).fallback_required := 'N';
            v_changes(p_idx).fallback_reason   :=
                CASE WHEN v_in_wl != 'Y'
                     THEN 'NOT_IN_WHITELIST(category=' || v_cat || ')'
                     ELSE 'CATEGORY_' || v_cat END;
        END IF;
    END classify_event;

BEGIN
    -- ───────────────────────────────────────────
    -- フェーズ1: XEPDB1 で進捗（HW/LW）と追跡テーブル情報を取得
    -- ───────────────────────────────────────────
    go_to('XEPDB1');

    BEGIN
        EXECUTE IMMEDIATE
            'SELECT last_extracted_commit_scn, mine_start_scn ' ||
            'FROM cdc_schema.delta_extract_state WHERE run_name = :1'
        INTO v_last_commit, v_mine_start USING p_run_name;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        EXECUTE IMMEDIATE
            'INSERT INTO cdc_schema.delta_extract_state ' ||
            '(run_name, last_extracted_commit_scn, mine_start_scn, status) ' ||
            'VALUES (:1, 0, 0, ''IDLE'')'
            USING p_run_name;
        COMMIT;
        v_last_commit := 0;
        v_mine_start  := 0;
    END;

    SELECT CURRENT_SCN INTO v_current_scn FROM V$DATABASE;
    IF v_last_commit = 0 THEN
        v_last_commit := v_current_scn - 1;
        v_mine_start  := v_last_commit;
        EXECUTE IMMEDIATE
            'UPDATE cdc_schema.delta_extract_state ' ||
            'SET last_extracted_commit_scn = :1, mine_start_scn = :2, baseline_scn = :3 ' ||
            'WHERE run_name = :4'
            USING v_last_commit, v_mine_start, v_last_commit, p_run_name;
        COMMIT;
    END IF;

    v_end_scn := v_current_scn;

    -- 低位水準点の再算出: 未コミットの最古Txの START_SCN を取得
    BEGIN
        SELECT NVL(MIN(START_SCN), v_end_scn) INTO v_oldest_open FROM V$TRANSACTION;
    EXCEPTION WHEN OTHERS THEN
        v_oldest_open := v_end_scn;
    END;

    -- 追跡対象テーブル一覧と PK 列マップをカタログから読む
    EXECUTE IMMEDIATE
        'SELECT table_name, pk_column FROM cdc_schema.cdc_table_catalog WHERE is_active = ''Y'''
        BULK COLLECT INTO v_tables, v_pk_cols;
    FOR k IN 1 .. v_tables.COUNT LOOP
        v_pk_map(v_tables(k)) := v_pk_cols(k);
    END LOOP;

    -- ★Phase2: LOB有無 + replay_category をカタログから読む
    DECLARE
        v_tbl_list2 SYS.ODCIVARCHAR2LIST;
        v_lob_list  SYS.ODCIVARCHAR2LIST;
        v_cat_list  SYS.ODCIVARCHAR2LIST;
    BEGIN
        EXECUTE IMMEDIATE
            'SELECT table_name, lob_present, replay_category ' ||
            'FROM cdc_schema.cdc_table_catalog WHERE is_active = ''Y'''
            BULK COLLECT INTO v_tbl_list2, v_lob_list, v_cat_list;
        FOR k IN 1 .. v_tbl_list2.COUNT LOOP
            v_lob_map(v_tbl_list2(k))        := v_lob_list(k);
            v_cat_replay_map(v_tbl_list2(k)) := v_cat_list(k);
        END LOOP;
    END;

    -- ★Phase2: ホワイトリストを読む
    DECLARE
        v_wl_tables SYS.ODCIVARCHAR2LIST;
    BEGIN
        EXECUTE IMMEDIATE
            'SELECT table_name FROM cdc_schema.redo_replay_whitelist ' ||
            'WHERE owner_name = ''SRC_SCHEMA'' AND replay_allowed = ''Y'''
            BULK COLLECT INTO v_wl_tables;
        FOR k IN 1 .. v_wl_tables.COUNT LOOP
            v_whitelist(v_wl_tables(k)) := 'Y';
        END LOOP;
    END;

    IF v_last_commit >= v_end_scn THEN
        go_to('CDB$ROOT');
        RETURN;
    END IF;

    EXECUTE IMMEDIATE
        'UPDATE cdc_schema.delta_extract_state ' ||
        'SET status = ''RUNNING'', last_run_at = SYSTIMESTAMP WHERE run_name = :1'
        USING p_run_name;
    COMMIT;

    -- ───────────────────────────────────────────
    -- フェーズ2: CDB$ROOT で LogMiner 起動・収集
    -- ───────────────────────────────────────────
    go_to('CDB$ROOT');

    BEGIN
        add_logfiles(v_mine_start);

        DBMS_LOGMNR.START_LOGMNR(
            STARTSCN => v_mine_start,
            ENDSCN   => v_end_scn,
            OPTIONS  => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG
                      + DBMS_LOGMNR.NO_ROWID_IN_STMT
                      + DBMS_LOGMNR.COMMITTED_DATA_ONLY
        );

        -- ★Phase2: STATUS/OPERATION_CODE/CSF/INFO/RS_ID/SSN を追加取得
        -- 注意: DICT_FROM_ONLINE_CATALOG 使用時、PDBの変更は CON_ID=1 として
        --       報告されるため CON_ID フィルタは使わない（SEG_OWNER で一意）。
        FOR rec IN (
            SELECT COMMIT_SCN,
                   XID,
                   SCN                AS change_scn,
                   ROW_NUMBER() OVER (
                       PARTITION BY XID ORDER BY SCN, RS_ID, SSN
                   )                  AS seq_in_tx,
                   SEG_NAME           AS table_name,
                   OPERATION,
                   OPERATION_CODE,
                   STATUS             AS status_code,
                   INFO               AS info_text,
                   CSF,
                   RS_ID,
                   SSN,
                   DBMS_LOB.SUBSTR(SQL_REDO, 4000, 1) AS sql_redo_str
            FROM V$LOGMNR_CONTENTS
            WHERE SEG_OWNER  = 'SRC_SCHEMA'
              AND SEG_NAME   IN (SELECT column_value FROM TABLE(v_tables))
              AND OPERATION IN ('INSERT', 'UPDATE', 'DELETE')
              AND COMMIT_SCN > v_last_commit
              AND COMMIT_SCN <= v_end_scn
            ORDER BY COMMIT_SCN, XID, SCN, RS_ID, SSN
        ) LOOP
            IF v_in_csf THEN
                -- ★CSF継続行: 前のエントリ(v_csf_target)の sql_redo_assembled に連結
                v_changes(v_csf_target).sql_redo_assembled :=
                    v_changes(v_csf_target).sql_redo_assembled || TO_CLOB(rec.sql_redo_str);
                -- CSFフラグを最新行の値で更新（0=完結, 1=まだ続く）
                v_changes(v_csf_target).csf := rec.CSF;
                IF rec.CSF = 0 THEN
                    v_in_csf := FALSE;  -- SQL連結完了
                END IF;
                -- 最大 COMMIT_SCN 追跡（継続行も同一TxなのでHW前進対象）
                IF rec.COMMIT_SCN > v_max_commit THEN
                    v_max_commit := rec.COMMIT_SCN;
                END IF;
            ELSE
                -- 新しい論理的DML文の開始
                v_idx := v_idx + 1;
                v_changes(v_idx).commit_scn     := rec.COMMIT_SCN;
                v_changes(v_idx).xid            := rec.XID;
                v_changes(v_idx).change_scn     := rec.change_scn;
                v_changes(v_idx).seq_in_tx      := rec.seq_in_tx;
                v_changes(v_idx).table_name     := rec.table_name;
                v_changes(v_idx).operation      := rec.OPERATION;
                v_changes(v_idx).operation_code := rec.OPERATION_CODE;
                v_changes(v_idx).status_code    := rec.status_code;
                v_changes(v_idx).info_text      := rec.info_text;
                v_changes(v_idx).csf            := rec.CSF;
                v_changes(v_idx).rs_id          := rec.RS_ID;
                v_changes(v_idx).ssn            := rec.SSN;
                v_changes(v_idx).sql_redo       := rec.sql_redo_str;
                -- sql_redo_assembled は最終的に CSF連結済みの完全SQLになる
                v_changes(v_idx).sql_redo_assembled := TO_CLOB(rec.sql_redo_str);

                IF rec.CSF = 1 THEN
                    -- 次の行がこのSQL の継続
                    v_in_csf     := TRUE;
                    v_csf_target := v_idx;
                END IF;

                IF rec.COMMIT_SCN > v_max_commit THEN
                    v_max_commit := rec.COMMIT_SCN;
                END IF;
            END IF;
        END LOOP;

        DBMS_LOGMNR.END_LOGMNR;
    EXCEPTION WHEN OTHERS THEN
        BEGIN DBMS_LOGMNR.END_LOGMNR; EXCEPTION WHEN OTHERS THEN NULL; END;
        RAISE;
    END;

    -- ───────────────────────────────────────────
    -- フェーズ3: XEPDB1 に戻って分類 + delta_queue に INSERT
    -- ───────────────────────────────────────────
    go_to('XEPDB1');

    i := v_changes.FIRST;
    WHILE i IS NOT NULL LOOP
        -- ★Phase2: イベントを分類（replay_category / replay_allowed を決定）
        classify_event(i);

        -- PK 値を SQL_REDO から抽出（参照用ベストエフォート）
        -- UPDATE/DELETE の WHERE句形式 '"PK" = <値>' のみ対応
        v_pk_val := NULL;
        BEGIN
            IF v_pk_map.EXISTS(v_changes(i).table_name) THEN
                v_pk_col := v_pk_map(v_changes(i).table_name);
                IF v_pk_col IS NOT NULL THEN
                    v_pk_val := REGEXP_SUBSTR(
                        SUBSTR(v_changes(i).sql_redo, 1, 2000),
                        '"' || v_pk_col || '" = ''?(\d+)''?', 1, 1, NULL, 1);
                END IF;
            END IF;
        EXCEPTION WHEN OTHERS THEN v_pk_val := NULL; END;

        -- delta_queue へ INSERT（★Phase2: 新カラムを含む）
        -- バインド変数: :1〜:19（19個）+ NEXTVAL = 20要素
        EXECUTE IMMEDIATE
            'INSERT INTO cdc_schema.delta_queue ' ||
            '(delta_id, commit_scn, xid, change_scn, seq_in_tx, ' ||
            ' table_name, operation, operation_code, status_code, info_text, ' ||
            ' csf, rs_id, ssn, sql_redo, sql_redo_assembled, ' ||
            ' replay_category, replay_allowed, fallback_required, fallback_reason, ' ||
            ' pk_value) ' ||
            'VALUES (cdc_schema.seq_delta_queue.NEXTVAL,' ||
            ' :1,:2,:3,:4,:5, :6,:7,:8,:9,:10, :11,:12,:13,:14,:15,' ||
            ' :16,:17,:18,:19)'
            USING v_changes(i).commit_scn,    v_changes(i).xid,
                  v_changes(i).change_scn,    v_changes(i).seq_in_tx,
                  v_changes(i).table_name,    v_changes(i).operation,
                  v_changes(i).operation_code, v_changes(i).status_code,
                  v_changes(i).info_text,     v_changes(i).csf,
                  v_changes(i).rs_id,         v_changes(i).ssn,
                  v_changes(i).sql_redo,      v_changes(i).sql_redo_assembled,
                  v_changes(i).replay_category, v_changes(i).replay_allowed,
                  v_changes(i).fallback_required, v_changes(i).fallback_reason,
                  v_pk_val;

        v_extract_cnt := v_extract_cnt + 1;
        i := v_changes.NEXT(i);
    END LOOP;

    COMMIT;

    -- ★HW/LW 更新（Phase1 と同ロジック）
    v_next_hw := CASE WHEN v_extract_cnt > 0 THEN v_max_commit ELSE v_end_scn END;
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

PROMPT SYS.delta_extract (Phase2+LOB11: C-category DELETE immediate apply exception) created on oracle-src.
EXIT;
