-- CDC 検証フェーズ: SYS 所有 CDC ランナー (CDB$ROOT に格納)
-- 重要: AUTHID CURRENT_USER 手続きが ALTER SESSION SET CONTAINER を PL/SQL 内で
--       使用するには、手続き自体が CDB$ROOT に格納されていること。
--       PDB に格納された手続きは PDB → CDB$ROOT 切替ができない (ORA-01031)。
-- アーキテクチャ:
--   CDB$ROOT 起動 → XEPDB1 (cdc_state 読取) → CDB$ROOT (LogMiner 収集)
--   → XEPDB1 (tgt_db 経由で変更適用) → CDB$ROOT (終了)
-- 実行ユーザー: SYS AS SYSDBA (CDB$ROOT コンテキスト)
-- 注意: CDB$ROOT に格納する手続きは、コンパイル時に XEPDB1 のオブジェクトを
--       解決できないため、XEPDB1 オブジェクトへのアクセスはすべて
--       EXECUTE IMMEDIATE (動的 SQL) で行う。

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

-- CDB$ROOT で接続 (ALTER SESSION SET CONTAINER = XEPDB1 は不要)
CONNECT / AS SYSDBA

-- ============================================================
-- SYS.CDC_PROCESS_BATCH  (AUTHID CURRENT_USER, CDB$ROOT に格納)
-- ============================================================
CREATE OR REPLACE PROCEDURE SYS.cdc_process_batch(p_run_name IN VARCHAR2)
    AUTHID CURRENT_USER
AS
    TYPE t_change_rec IS RECORD (
        scn        NUMBER,
        table_name VARCHAR2(100),
        operation  VARCHAR2(20),
        sql_redo   VARCHAR2(32767),
        rs_id      VARCHAR2(32),
        ssn        NUMBER
    );
    TYPE t_change_tab IS TABLE OF t_change_rec INDEX BY PLS_INTEGER;
    TYPE t_pk_map     IS TABLE OF VARCHAR2(100) INDEX BY VARCHAR2(100);

    v_changes      t_change_tab;
    v_state_id     NUMBER;
    v_snapshot_scn NUMBER;
    v_last_scn     NUMBER;
    v_end_scn      NUMBER;
    v_current_scn  NUMBER;
    v_pdb_con_id   NUMBER;
    v_err_code     NUMBER;
    v_err_msg      VARCHAR2(4000);
    v_backtrace    VARCHAR2(4000);
    v_pk_cols      t_pk_map;
    v_pk_col       VARCHAR2(100);
    v_pk_val       VARCHAR2(4000);
    v_change_cnt   NUMBER      := 0;
    v_idx          PLS_INTEGER := 0;
    i              PLS_INTEGER;
    v_container    VARCHAR2(30) := 'CDB$ROOT';

    PROCEDURE go_to(p_container IN VARCHAR2) IS
    BEGIN
        IF v_container != p_container THEN
            EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = ' || p_container;
            v_container := p_container;
        END IF;
    END go_to;

    -- XEPDB1 オブジェクトへのアクセスはすべて EXECUTE IMMEDIATE で行う
    -- (CDB$ROOT に格納された手続きはコンパイル時に XEPDB1 オブジェクトを解決できない)
    PROCEDURE log_err(
        p_state_id   IN NUMBER,
        p_scn        IN NUMBER,
        p_table_name IN VARCHAR2,
        p_operation  IN VARCHAR2,
        p_sql_redo   IN VARCHAR2,
        p_err_code   IN NUMBER,
        p_err_msg    IN VARCHAR2,
        p_backtrace  IN VARCHAR2,
        p_lob_fb     IN NUMBER DEFAULT 0
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_was_in VARCHAR2(30) := v_container;
    BEGIN
        IF v_container != 'XEPDB1' THEN
            EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = XEPDB1';
        END IF;
        EXECUTE IMMEDIATE
            'INSERT INTO cdc_schema.cdc_error_log ' ||
            '(state_id, scn, table_name, operation, sql_redo, ' ||
            ' error_code, error_message, backtrace, lob_fallback, occurred_at) ' ||
            'VALUES (:1,:2,:3,:4,:5,:6,:7,:8,:9,SYSTIMESTAMP)'
        USING p_state_id, p_scn,
              SUBSTR(p_table_name, 1, 100),
              SUBSTR(p_operation, 1, 20),
              SUBSTR(p_sql_redo, 1, 32767),
              p_err_code,
              SUBSTR(p_err_msg, 1, 4000),
              SUBSTR(p_backtrace, 1, 4000),
              p_lob_fb;
        COMMIT;
        IF v_was_in != 'XEPDB1' THEN
            EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = ' || v_was_in;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        BEGIN ROLLBACK; EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN
            IF v_was_in != 'XEPDB1' THEN
                EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = ' || v_was_in;
            END IF;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END log_err;

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
            SELECT DISTINCT l.MEMBER FROM V$LOGFILE l JOIN V$LOG g ON l.GROUP# = g.GROUP#
            WHERE g.STATUS IN ('CURRENT', 'ACTIVE') OR g.NEXT_CHANGE# > p_start_scn
        ) LOOP
            BEGIN DBMS_LOGMNR.ADD_LOGFILE(rec.MEMBER, DBMS_LOGMNR.ADDFILE);
            EXCEPTION WHEN OTHERS THEN NULL; END;
        END LOOP;
    END add_logfiles;

    PROCEDURE apply_one(
        p_state_id   IN NUMBER,
        p_scn        IN NUMBER,
        p_table_name IN VARCHAR2,
        p_pk_col     IN VARCHAR2,
        p_pk_val     IN VARCHAR2,
        p_operation  IN VARCHAR2,
        p_sql_redo   IN VARCHAR2
    ) IS
        v_s  VARCHAR2(32767);
        v_ec NUMBER;
        v_em VARCHAR2(4000);
        v_bt VARCHAR2(4000);
    BEGIN
        IF p_sql_redo IS NULL OR LENGTH(p_sql_redo) = 0 THEN RETURN; END IF;
        v_s := REPLACE(REPLACE(p_sql_redo, '"SRC_SCHEMA"', '"TGT_SCHEMA"'),
                       'SRC_SCHEMA.', 'TGT_SCHEMA.');
        BEGIN
            -- tgt_schema.exec_dml@tgt_db は XEPDB1 ローカルオブジェクト → 動的 SQL
            EXECUTE IMMEDIATE 'BEGIN tgt_schema.exec_dml@tgt_db(:1); END;' USING v_s;
        EXCEPTION WHEN OTHERS THEN
            v_ec := SQLCODE; v_em := SUBSTR(SQLERRM, 1, 4000);
            v_bt := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
            log_err(p_state_id, p_scn, p_table_name, p_operation,
                p_sql_redo, v_ec, v_em, v_bt, 0);
        END;
    END apply_one;

BEGIN
    -- フェーズ 1: XEPDB1 に切り替えて cdc_state を読む
    go_to('XEPDB1');

    -- cdc_schema.cdc_state は XEPDB1 ローカル → 動的 SQL で SELECT
    EXECUTE IMMEDIATE
        'SELECT state_id, snapshot_scn, NVL(last_applied_scn, snapshot_scn) ' ||
        'FROM cdc_schema.cdc_state ' ||
        'WHERE run_name = :1 AND status IN (''IDLE'', ''RUNNING'')'
    INTO v_state_id, v_snapshot_scn, v_last_scn
    USING p_run_name;

    -- V$DATABASE は CDB 共通ビューのため XEPDB1 からも参照可
    SELECT CURRENT_SCN INTO v_current_scn FROM V$DATABASE;
    v_end_scn := v_current_scn;

    IF v_last_scn >= v_end_scn THEN
        go_to('CDB$ROOT');
        RETURN;
    END IF;

    -- CON_ID を XEPDB1 コンテキストで取得 (LogMiner フィルタ用)
    v_pdb_con_id := TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID'));

    -- cdc_schema.cdc_state UPDATE → 動的 SQL
    EXECUTE IMMEDIATE
        'UPDATE cdc_schema.cdc_state ' ||
        'SET status = ''RUNNING'', last_run_at = SYSTIMESTAMP ' ||
        'WHERE state_id = :1'
    USING v_state_id;
    COMMIT;

    -- フェーズ 2: CDB$ROOT に切り替えて LogMiner を実行
    go_to('CDB$ROOT');

    BEGIN
        add_logfiles(v_last_scn + 1);

        DBMS_LOGMNR.START_LOGMNR(
            STARTSCN => v_last_scn + 1,
            ENDSCN   => v_end_scn,
            OPTIONS  => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG
                      + DBMS_LOGMNR.NO_ROWID_IN_STMT
        );

        FOR rec IN (
            SELECT SCN,
                   SEG_NAME    AS table_name,
                   OPERATION,
                   DBMS_LOB.SUBSTR(SQL_REDO, 32767, 1) AS sql_redo_str,
                   RS_ID, SSN
            FROM V$LOGMNR_CONTENTS
            WHERE SEG_OWNER  = 'SRC_SCHEMA'
              AND OPERATION IN ('INSERT', 'UPDATE', 'DELETE')
              AND CON_ID     = v_pdb_con_id
              AND SCN        > v_last_scn
              AND SCN        <= v_end_scn
            ORDER BY SCN, RS_ID, SSN,
                CASE OPERATION
                    WHEN 'DELETE' THEN 10 - CASE UPPER(SEG_NAME)
                        WHEN 'SYSTEM_EVENTS'        THEN 1
                        WHEN 'PRICE_HISTORY'        THEN 2
                        WHEN 'ORDER_STATUS_HISTORY' THEN 3
                        WHEN 'CUSTOMER_CONTRACTS'   THEN 4
                        WHEN 'ORDER_ITEMS'          THEN 5
                        WHEN 'ORDERS'               THEN 6
                        WHEN 'PRODUCTS'             THEN 7
                        WHEN 'CUSTOMERS'            THEN 8
                        WHEN 'PRODUCT_CATEGORIES'   THEN 9
                        WHEN 'REGIONS'              THEN 10
                        ELSE 0 END
                    ELSE CASE UPPER(SEG_NAME)
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
                        ELSE 99 END
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
    EXCEPTION WHEN OTHERS THEN
        BEGIN DBMS_LOGMNR.END_LOGMNR; EXCEPTION WHEN OTHERS THEN NULL; END;
        RAISE;
    END;

    -- フェーズ 3: XEPDB1 に戻って変更を適用
    go_to('XEPDB1');

    v_pk_cols('REGIONS')              := 'REGION_ID';
    v_pk_cols('PRODUCT_CATEGORIES')   := 'CATEGORY_ID';
    v_pk_cols('CUSTOMERS')            := 'CUSTOMER_ID';
    v_pk_cols('PRODUCTS')             := 'PRODUCT_ID';
    v_pk_cols('ORDERS')               := 'ORDER_ID';
    v_pk_cols('ORDER_ITEMS')          := 'ITEM_ID';
    v_pk_cols('CUSTOMER_CONTRACTS')   := 'CONTRACT_ID';
    v_pk_cols('ORDER_STATUS_HISTORY') := 'HISTORY_ID';
    v_pk_cols('PRICE_HISTORY')        := 'HISTORY_ID';
    v_pk_cols('SYSTEM_EVENTS')        := 'EVENT_ID';

    i := v_changes.FIRST;
    WHILE i IS NOT NULL LOOP
        v_pk_col := NVL(v_pk_cols(UPPER(v_changes(i).table_name)), 'ID');
        BEGIN
            v_pk_val := REGEXP_SUBSTR(
                SUBSTR(v_changes(i).sql_redo, 1, 2000),
                '"' || v_pk_col || '" = (\d+)', 1, 1, NULL, 1);
        EXCEPTION WHEN OTHERS THEN v_pk_val := NULL; END;

        apply_one(v_state_id, v_changes(i).scn, v_changes(i).table_name,
            v_pk_col, v_pk_val, v_changes(i).operation, v_changes(i).sql_redo);

        v_change_cnt := v_change_cnt + 1;
        i := v_changes.NEXT(i);
    END LOOP;

    COMMIT;

    -- cdc_schema.cdc_state 最終更新 → 動的 SQL
    EXECUTE IMMEDIATE
        'UPDATE cdc_schema.cdc_state ' ||
        'SET last_applied_scn = :1, status = ''IDLE'', last_run_at = SYSTIMESTAMP ' ||
        'WHERE state_id = :2'
    USING v_end_scn, v_state_id;
    COMMIT;

    go_to('CDB$ROOT');

    DBMS_OUTPUT.PUT_LINE('cdc_process_batch: applied=' || v_change_cnt ||
                         ' scn=[' || (v_last_scn+1) || ',' || v_end_scn || ']');

EXCEPTION WHEN OTHERS THEN
    v_err_code  := SQLCODE;
    v_err_msg   := SUBSTR(SQLERRM, 1, 4000);
    v_backtrace := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
    IF v_container != 'XEPDB1' THEN
        BEGIN go_to('XEPDB1'); EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;
    BEGIN
        EXECUTE IMMEDIATE
            'UPDATE cdc_schema.cdc_state ' ||
            'SET status = ''ERROR'', error_message = :1, last_run_at = SYSTIMESTAMP ' ||
            'WHERE state_id = :2'
        USING SUBSTR(v_err_msg, 1, 4000), v_state_id;
        COMMIT;
    EXCEPTION WHEN OTHERS THEN NULL; END;
    log_err(v_state_id, NULL, 'PROCESS_BATCH', NULL, NULL,
        v_err_code, v_err_msg, v_backtrace, 0);
    BEGIN go_to('CDB$ROOT'); EXCEPTION WHEN OTHERS THEN NULL; END;
    RAISE;
END cdc_process_batch;
/
SHOW ERRORS PROCEDURE SYS.cdc_process_batch;

-- DBMS_SCHEDULER ジョブも CDB$ROOT で作成
BEGIN
  DBMS_SCHEDULER.DROP_JOB('CDC_JOB_CDC_RUN_01', force => TRUE);
  EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'CDC_JOB_CDC_RUN_01',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN sys.cdc_process_batch(''cdc_run_01''); END;',
    repeat_interval => 'FREQ=SECONDLY;INTERVAL=15',
    enabled         => TRUE,
    auto_drop       => FALSE,
    comments        => 'CDC batch job for run_name=cdc_run_01 (CDB$ROOT job)'
  );
END;
/

SELECT owner, job_name, enabled, state FROM dba_scheduler_jobs WHERE job_name = 'CDC_JOB_CDC_RUN_01';
PROMPT SYS.cdc_process_batch (CDB ROOT) deployed and job created.
EXIT;
