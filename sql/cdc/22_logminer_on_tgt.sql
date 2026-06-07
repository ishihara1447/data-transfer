-- ==============================================================
-- LogMiner on oracle-tgt: 搬送済み archive log を読んで
-- STAGING_SCHEMA に差分を適用する
-- ==============================================================
-- アーキテクチャ:
--   CDB$ROOT (プロシージャ格納) で ALTER SESSION SET CONTAINER を使い
--   CDB$ROOT / XEPDB1 を切り替えながら処理する
--
--   XEPDB1 読取  → sys.redo_sync_state  (進捗管理)
--   CDB$ROOT     → ADD_LOGFILE / START_LOGMNR / V$LOGMNR_CONTENTS
--   XEPDB1 書込  → STAGING_SCHEMA テーブルに EXECUTE IMMEDIATE で直接適用
--
-- 辞書: flat-file 辞書 (/opt/oracle/redo_from_src/dict.ora)
-- ログファイル取得: sys.arch_log_registry (XEPDB1 内)
-- 状態管理: sys.redo_sync_state (XEPDB1 内)
--
-- 前提:
--   - 20_staging_users_tgt.sql を先に実行し
--     staging_schema / sys.redo_sync_state を作成済みであること
--   - 04_sync_archivelogs.sh で archive log を
--     /opt/oracle/redo_from_src/ に配置済みかつ
--     sys.arch_log_registry に登録済みであること
--
-- 実行ユーザー: SYS AS SYSDBA (oracle-tgt, CDB$ROOT)
-- Oracle 12c 互換 (IDENTITY 列は 20_staging_users_tgt.sql 既存定義を尊重)
-- SQL*Plus 実行可能
-- ==============================================================

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

-- CDB$ROOT で接続（PDB 指定なし）
CONNECT / AS SYSDBA

-- ==============================================================
-- SYS.cdc_apply_delta
--   AUTHID CURRENT_USER + CDB$ROOT 格納により
--   ALTER SESSION SET CONTAINER が PL/SQL 内で動作する
--
-- 重要: CDB$ROOT に格納された手続きは、コンパイル時に
--       XEPDB1 のオブジェクトを解決できない。
--       XEPDB1 オブジェクトへのアクセスはすべて
--       EXECUTE IMMEDIATE (動的 SQL) で行うこと。
-- ==============================================================
CREATE OR REPLACE PROCEDURE SYS.cdc_apply_delta
    AUTHID CURRENT_USER
AS
    -- ----------------------------------------------------------------
    -- 型定義
    -- ----------------------------------------------------------------
    TYPE t_change_rec IS RECORD (
        scn        NUMBER,
        table_name VARCHAR2(100),
        operation  VARCHAR2(20),
        sql_redo   VARCHAR2(32767),
        rs_id      VARCHAR2(32),
        ssn        NUMBER
    );
    TYPE t_change_tab IS TABLE OF t_change_rec INDEX BY PLS_INTEGER;

    -- ----------------------------------------------------------------
    -- 変数
    -- ----------------------------------------------------------------
    v_changes       t_change_tab;
    v_state_id      NUMBER;
    v_last_scn      NUMBER;
    v_end_scn       NUMBER;
    v_dict_file     VARCHAR2(500);
    v_change_cnt    NUMBER      := 0;
    v_apply_err_cnt NUMBER      := 0;
    v_idx           PLS_INTEGER := 0;
    i               PLS_INTEGER;
    v_sql           VARCHAR2(32767);
    v_err_code      NUMBER;
    v_err_msg       VARCHAR2(4000);
    v_backtrace     VARCHAR2(4000);
    v_container     VARCHAR2(30) := 'CDB$ROOT';

    -- ----------------------------------------------------------------
    -- go_to: CDB$ROOT / XEPDB1 の切替管理
    --   同じコンテナへの切替は無駄な ALTER SESSION を省略する
    -- ----------------------------------------------------------------
    PROCEDURE go_to(p_container IN VARCHAR2) IS
    BEGIN
        IF v_container != p_container THEN
            EXECUTE IMMEDIATE
                'ALTER SESSION SET CONTAINER = ' || p_container;
            v_container := p_container;
        END IF;
    END go_to;

    -- ----------------------------------------------------------------
    -- add_arch_logs: arch_log_registry から未適用の archive log を追加
    --   XEPDB1 内の sys.arch_log_registry を動的 SQL で参照する
    --   LogMiner の ADD_LOGFILE は CDB$ROOT で実行する必要がある
    -- ----------------------------------------------------------------
    PROCEDURE add_arch_logs(p_start_scn IN NUMBER) IS
        v_member VARCHAR2(600);
        -- XEPDB1 の arch_log_registry から対象ファイル一覧を取得する
        -- 動的カーソルを使わず EXECUTE IMMEDIATE + 行単位ループで実装
        -- (CDB$ROOT からは XEPDB1 のカーソルを静的に定義できないため)
        TYPE t_str_tab IS TABLE OF VARCHAR2(600) INDEX BY PLS_INTEGER;
        v_files  t_str_tab;
        v_cnt    PLS_INTEGER := 0;
    BEGIN
        -- XEPDB1 に切り替えてファイル一覧を取得
        go_to('XEPDB1');
        EXECUTE IMMEDIATE
            'SELECT ''/opt/oracle/redo_from_src/'' || file_name ' ||
            'FROM sys.arch_log_registry ' ||
            'WHERE "NEXT_CHANGE#" > :1 ' ||
            'ORDER BY "SEQUENCE#"'
        BULK COLLECT INTO v_files
        USING p_start_scn;

        -- CDB$ROOT に戻って ADD_LOGFILE を実行
        go_to('CDB$ROOT');
        FOR j IN 1 .. v_files.COUNT LOOP
            BEGIN
                DBMS_LOGMNR.ADD_LOGFILE(
                    LOGFILENAME => v_files(j),
                    OPTIONS     => DBMS_LOGMNR.ADDFILE
                );
            EXCEPTION
                WHEN OTHERS THEN
                    -- ファイルが既に追加済みまたは存在しない場合は無視して継続
                    DBMS_OUTPUT.PUT_LINE(
                        'WARN add_logfile skip: ' || v_files(j) ||
                        ' err=' || SQLCODE || ':' || SUBSTR(SQLERRM, 1, 200)
                    );
            END;
        END LOOP;
    END add_arch_logs;

    -- ----------------------------------------------------------------
    -- log_apply_err: 個別行の適用エラーをコンソールと
    --   sys.redo_sync_state の error_message に記録する
    --   (AUTONOMOUS TRANSACTION で独立 COMMIT)
    -- ----------------------------------------------------------------
    PROCEDURE log_apply_err(
        p_state_id   IN NUMBER,
        p_scn        IN NUMBER,
        p_table_name IN VARCHAR2,
        p_operation  IN VARCHAR2,
        p_err_code   IN NUMBER,
        p_err_msg    IN VARCHAR2
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_was_in VARCHAR2(30) := v_container;
    BEGIN
        DBMS_OUTPUT.PUT_LINE(
            'WARN apply_err scn=' || p_scn ||
            ' tbl='  || p_table_name ||
            ' op='   || p_operation  ||
            ' err='  || p_err_code || ':' || p_err_msg
        );
        -- XEPDB1 の redo_sync_state に最新エラーを記録（上書き）
        IF v_container != 'XEPDB1' THEN
            EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = XEPDB1';
        END IF;
        EXECUTE IMMEDIATE
            'UPDATE sys.redo_sync_state ' ||
            'SET error_message = SUBSTR(:1, 1, 4000) ' ||
            'WHERE state_id = :2'
        USING
            'scn=' || p_scn || ' tbl=' || p_table_name ||
            ' op=' || p_operation || ' ' || p_err_msg,
            p_state_id;
        COMMIT;
        -- 元のコンテナに戻す
        IF v_was_in != 'XEPDB1' THEN
            EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = ' || v_was_in;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN ROLLBACK; EXCEPTION WHEN OTHERS THEN NULL; END;
            BEGIN
                IF v_was_in != 'XEPDB1' THEN
                    EXECUTE IMMEDIATE
                        'ALTER SESSION SET CONTAINER = ' || v_was_in;
                END IF;
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
    END log_apply_err;

-- ================================================================
-- メイン処理
-- ================================================================
BEGIN
    -- ----------------------------------------------------------
    -- フェーズ 1: XEPDB1 に切り替えて redo_sync_state を読む
    -- ----------------------------------------------------------
    go_to('XEPDB1');

    -- sys.redo_sync_state は XEPDB1 ローカルオブジェクト → 動的 SQL
    -- ROWNUM フィルタはサブクエリで ORDER BY と組み合わせる
    EXECUTE IMMEDIATE
        'SELECT state_id, NVL(last_applied_scn, 0), ' ||
        '       NVL(dict_file, ''/opt/oracle/redo_from_src/dict.ora'') ' ||
        'FROM ( ' ||
        '    SELECT state_id, last_applied_scn, dict_file ' ||
        '    FROM sys.redo_sync_state ' ||
        '    ORDER BY state_id ' ||
        ') WHERE ROWNUM = 1'
    INTO v_state_id, v_last_scn, v_dict_file;

    -- arch_log_registry から適用可能な最大 SCN を取得
    EXECUTE IMMEDIATE
        'SELECT NVL(MAX("NEXT_CHANGE#"), 0) - 1 ' ||
        'FROM sys.arch_log_registry'
    INTO v_end_scn;

    IF v_end_scn IS NULL OR v_last_scn >= v_end_scn THEN
        DBMS_OUTPUT.PUT_LINE(
            'cdc_apply_delta: no new redo to apply ' ||
            '(last_applied_scn=' || v_last_scn ||
            ', max_end_scn=' || NVL(TO_CHAR(v_end_scn), 'NULL') || ')'
        );
        -- ステータスを IDLE に維持して終了
        EXECUTE IMMEDIATE
            'UPDATE sys.redo_sync_state ' ||
            'SET status=''IDLE'', last_run_at=SYSTIMESTAMP ' ||
            'WHERE state_id=:1'
        USING v_state_id;
        COMMIT;
        go_to('CDB$ROOT');
        RETURN;
    END IF;

    -- RUNNING に更新
    EXECUTE IMMEDIATE
        'UPDATE sys.redo_sync_state ' ||
        'SET status=''RUNNING'', last_run_at=SYSTIMESTAMP, error_message=NULL ' ||
        'WHERE state_id=:1'
    USING v_state_id;
    COMMIT;

    -- ----------------------------------------------------------
    -- フェーズ 2: CDB$ROOT に切り替えて LogMiner を実行
    --   ADD_LOGFILE / START_LOGMNR は CDB$ROOT からのみ実行可能
    --   (PDB からは ORA-65040 が発生する)
    -- ----------------------------------------------------------
    go_to('CDB$ROOT');

    BEGIN
        -- arch_log_registry から対象ファイルを ADD_LOGFILE
        -- (add_arch_logs 内で XEPDB1 ↔ CDB$ROOT を切り替える)
        add_arch_logs(v_last_scn);

        -- flat-file 辞書で LogMiner 起動
        -- DictFileName を指定する場合は DICT_FROM_ONLINE_CATALOG は不要
        DBMS_LOGMNR.START_LOGMNR(
            STARTSCN     => v_last_scn + 1,
            ENDSCN       => v_end_scn,
            DictFileName => v_dict_file,
            OPTIONS      => DBMS_LOGMNR.NO_ROWID_IN_STMT
        );

        -- V$LOGMNR_CONTENTS を PL/SQL コレクションに収集する
        -- FK 依存順でソート: INSERT は親→子、DELETE は子→親
        -- CON_ID フィルタは不要（flat-file 辞書は CON_ID を持たない）
        FOR rec IN (
            SELECT SCN,
                   SEG_NAME  AS table_name,
                   OPERATION,
                   DBMS_LOB.SUBSTR(SQL_REDO, 32767, 1) AS sql_redo_str,
                   RS_ID,
                   SSN
            FROM   V$LOGMNR_CONTENTS
            WHERE  SEG_OWNER  = 'SRC_SCHEMA'
              AND  OPERATION IN ('INSERT', 'UPDATE', 'DELETE')
              AND  SCN        >  v_last_scn
              AND  SCN        <= v_end_scn
            ORDER BY
                SCN, RS_ID, SSN,
                -- FK 依存順: DELETE は子→親（逆順）、INSERT/UPDATE は親→子
                CASE OPERATION
                    WHEN 'DELETE' THEN
                        10 - CASE UPPER(SEG_NAME)
                            WHEN 'REGIONS'              THEN 1
                            WHEN 'PRODUCT_CATEGORIES'   THEN 2
                            WHEN 'CUSTOMERS'            THEN 3
                            WHEN 'PRODUCTS'             THEN 4
                            WHEN 'ORDERS'               THEN 5
                            WHEN 'ORDER_ITEMS'          THEN 6
                            WHEN 'CUSTOMER_CONTRACTS'   THEN 7
                            WHEN 'ORDER_STATUS_HISTORY' THEN 8
                            WHEN 'PRICE_HISTORY'        THEN 9
                            WHEN 'SYSTEM_EVENTS'        THEN 10
                            ELSE 0
                        END
                    ELSE
                        CASE UPPER(SEG_NAME)
                            WHEN 'REGIONS'              THEN 1
                            WHEN 'PRODUCT_CATEGORIES'   THEN 2
                            WHEN 'CUSTOMERS'            THEN 3
                            WHEN 'PRODUCTS'             THEN 4
                            WHEN 'ORDERS'               THEN 5
                            WHEN 'ORDER_ITEMS'          THEN 6
                            WHEN 'CUSTOMER_CONTRACTS'   THEN 7
                            WHEN 'ORDER_STATUS_HISTORY' THEN 8
                            WHEN 'PRICE_HISTORY'        THEN 9
                            WHEN 'SYSTEM_EVENTS'        THEN 10
                            ELSE 99
                        END
                END
        ) LOOP
            v_idx := v_idx + 1;
            v_changes(v_idx).scn        := rec.SCN;
            v_changes(v_idx).table_name := rec.table_name;
            v_changes(v_idx).operation  := rec.OPERATION;
            v_changes(v_idx).sql_redo   := rec.sql_redo_str;
            v_changes(v_idx).rs_id      := rec.RS_ID;
            v_changes(v_idx).ssn        := rec.SSN;
        END LOOP;

        DBMS_LOGMNR.END_LOGMNR;
    EXCEPTION
        WHEN OTHERS THEN
            -- LogMiner を確実にクローズしてから例外を再送出
            BEGIN
                DBMS_LOGMNR.END_LOGMNR;
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
            RAISE;
    END;

    -- ----------------------------------------------------------
    -- フェーズ 3: XEPDB1 に切り替えて STAGING_SCHEMA に差分を適用
    --   DB リンク不要: ローカル EXECUTE IMMEDIATE で直接実行
    --   SRC_SCHEMA → STAGING_SCHEMA に置換してから実行する
    -- ----------------------------------------------------------
    go_to('XEPDB1');

    i := v_changes.FIRST;
    WHILE i IS NOT NULL LOOP
        -- スキーマ名を SRC_SCHEMA から STAGING_SCHEMA に置換
        v_sql := v_changes(i).sql_redo;
        v_sql := REPLACE(v_sql, '"SRC_SCHEMA"', '"STAGING_SCHEMA"');
        v_sql := REPLACE(v_sql, 'SRC_SCHEMA.',  'STAGING_SCHEMA.');

        IF v_sql IS NOT NULL AND LENGTH(TRIM(v_sql)) > 0 THEN
            BEGIN
                EXECUTE IMMEDIATE v_sql;
            EXCEPTION
                WHEN OTHERS THEN
                    v_err_code := SQLCODE;
                    v_err_msg  := SUBSTR(SQLERRM, 1, 4000);
                    -- 個別行エラーはログに記録して適用を継続する
                    log_apply_err(
                        v_state_id,
                        v_changes(i).scn,
                        v_changes(i).table_name,
                        v_changes(i).operation,
                        v_err_code,
                        v_err_msg
                    );
                    v_apply_err_cnt := v_apply_err_cnt + 1;
            END;
        END IF;

        v_change_cnt := v_change_cnt + 1;
        i := v_changes.NEXT(i);
    END LOOP;

    COMMIT;

    -- ----------------------------------------------------------
    -- フェーズ 4: redo_sync_state を更新して完了を記録
    -- ----------------------------------------------------------
    -- go_to('XEPDB1') は既に XEPDB1 にいるため不要だが明示的に呼ぶ
    go_to('XEPDB1');

    EXECUTE IMMEDIATE
        'UPDATE sys.redo_sync_state ' ||
        'SET last_applied_scn = :1, ' ||
        '    status           = ''IDLE'', ' ||
        '    last_run_at      = SYSTIMESTAMP, ' ||
        '    error_message    = CASE WHEN :2 > 0 ' ||
        '                       THEN ''last_run: '' || :2 || '' apply errors'' ' ||
        '                       ELSE NULL END ' ||
        'WHERE state_id = :3'
    USING v_end_scn, v_apply_err_cnt, v_apply_err_cnt, v_state_id;
    COMMIT;

    go_to('CDB$ROOT');

    DBMS_OUTPUT.PUT_LINE(
        'cdc_apply_delta: applied=' || v_change_cnt ||
        ' changes (errors=' || v_apply_err_cnt || ')' ||
        ' scn=[' || (v_last_scn + 1) || ',' || v_end_scn || ']'
    );

-- ================================================================
-- 全体エラーハンドリング: 致命的エラーは status='ERROR' に記録して再送出
-- ================================================================
EXCEPTION
    WHEN OTHERS THEN
        v_err_code  := SQLCODE;
        v_err_msg   := SUBSTR(SQLERRM, 1, 4000);
        v_backtrace := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
        -- XEPDB1 に切り替えて redo_sync_state を ERROR に更新
        IF v_container != 'XEPDB1' THEN
            BEGIN
                go_to('XEPDB1');
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
        END IF;
        BEGIN
            EXECUTE IMMEDIATE
                'UPDATE sys.redo_sync_state ' ||
                'SET status=''ERROR'', ' ||
                '    error_message=SUBSTR(:1, 1, 4000), ' ||
                '    last_run_at=SYSTIMESTAMP ' ||
                'WHERE state_id=:2'
            USING
                SUBSTR(v_err_msg || ' | ' || v_backtrace, 1, 4000),
                v_state_id;
            COMMIT;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        BEGIN go_to('CDB$ROOT'); EXCEPTION WHEN OTHERS THEN NULL; END;
        RAISE;
END cdc_apply_delta;
/
SHOW ERRORS PROCEDURE SYS.cdc_apply_delta;

-- ==============================================================
-- arch_log_registry: 搬送済み archive log の記録テーブル
--   04_sync_archivelogs.sh から INSERT される
--   カラム名: file_name, sequence_no, first_change_no, next_change_no
--   (Oracle では # をカラム名に使えないため _no サフィックスを使用)
-- ==============================================================
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt
    FROM   dba_tables
    WHERE  owner = 'SYS'
      AND  table_name = 'ARCH_LOG_REGISTRY';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE '
            CREATE TABLE sys.arch_log_registry (
                registry_id     NUMBER        NOT NULL,
                file_name       VARCHAR2(500) NOT NULL,
                sequence_no     NUMBER        NOT NULL,
                first_change_no NUMBER        NOT NULL,
                next_change_no  NUMBER        NOT NULL,
                registered_at   TIMESTAMP     DEFAULT SYSTIMESTAMP,
                CONSTRAINT pk_arch_log_registry PRIMARY KEY (registry_id)
            )';
        EXECUTE IMMEDIATE '
            CREATE SEQUENCE sys.seq_arch_log_registry
            START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE';
        EXECUTE IMMEDIATE '
            CREATE OR REPLACE TRIGGER sys.trg_arch_log_registry_bi
            BEFORE INSERT ON sys.arch_log_registry
            FOR EACH ROW
            BEGIN
                IF :NEW.registry_id IS NULL THEN
                    SELECT sys.seq_arch_log_registry.NEXTVAL
                    INTO :NEW.registry_id FROM DUAL;
                END IF;
            END';
        DBMS_OUTPUT.PUT_LINE('arch_log_registry created.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('arch_log_registry already exists.');
    END IF;
END;
/

PROMPT cdc_apply_delta deployed and arch_log_registry ensured on oracle-tgt.
EXIT;
