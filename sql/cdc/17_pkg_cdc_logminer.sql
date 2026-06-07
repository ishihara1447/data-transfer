-- CDC 検証フェーズ: PKG_CDC_LOGMINER パッケージ (oracle-src 用)
-- Phase B: redo log CDC（LogMiner で変更を読み取り oracle-tgt に DBリンク経由で適用）
-- Oracle 21c XE CDB/PDB 対応:
--   - CONTINUOUS_MINE は Oracle 21c で廃止 → 使用しない
--   - ADD_LOGFILE / LogMiner は PDB 実行不可 (ORA-65040) → AUTHID CURRENT_USER + コンテナ切替
--   - process_batch: CDB$ROOT で変更を収集 → XEPDB1 に戻って適用
--   - 呼び出し元は SYS 前提 (DBMS_SCHEDULER ジョブ所有者 = SYS)
-- 実行ユーザー: SYS AS SYSDBA
-- 実行対象: oracle-src XEPDB1 (localhost:1521/XEPDB1)

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

-- ============================================================
-- Package Specification
-- ============================================================
CREATE OR REPLACE PACKAGE cdc_schema.pkg_cdc_logminer AUTHID CURRENT_USER AS

    PROCEDURE start_cdc(
        p_run_name     IN VARCHAR2,
        p_interval_sec IN NUMBER DEFAULT 10
    );

    PROCEDURE stop_cdc(p_run_name IN VARCHAR2);

    PROCEDURE process_batch(
        p_run_name IN VARCHAR2,
        p_max_scn  IN NUMBER DEFAULT NULL
    );

    FUNCTION get_cdc_lag(p_run_name IN VARCHAR2) RETURN NUMBER;

END pkg_cdc_logminer;
/
SHOW ERRORS PACKAGE cdc_schema.pkg_cdc_logminer;

-- ============================================================
-- Package Body
-- ============================================================
CREATE OR REPLACE PACKAGE BODY cdc_schema.pkg_cdc_logminer AS

    FUNCTION fk_order(p_table_name IN VARCHAR2) RETURN NUMBER IS
    BEGIN
        RETURN CASE UPPER(p_table_name)
            WHEN 'REGIONS'               THEN 1
            WHEN 'PRODUCT_CATEGORIES'    THEN 2
            WHEN 'CUSTOMERS'             THEN 3
            WHEN 'PRODUCTS'              THEN 4
            WHEN 'ORDERS'                THEN 5
            WHEN 'ORDER_ITEMS'           THEN 6
            WHEN 'CUSTOMER_CONTRACTS'    THEN 7
            WHEN 'ORDER_STATUS_HISTORY'  THEN 8
            WHEN 'PRICE_HISTORY'         THEN 9
            WHEN 'SYSTEM_EVENTS'         THEN 10
            ELSE 99
        END;
    END fk_order;

    -- ----------------------------------------------------------
    -- log_cdc_error: CDC エラーを cdc_error_log に記録する
    -- AUTONOMOUS TRANSACTION: メイン処理の ROLLBACK に左右されない
    -- XEPDB1 コンテキストで呼び出すこと
    -- ----------------------------------------------------------
    PROCEDURE log_cdc_error(
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
    BEGIN
        INSERT INTO cdc_schema.cdc_error_log (
            state_id, scn, table_name, operation, sql_redo,
            error_code, error_message, backtrace, lob_fallback, occurred_at
        ) VALUES (
            p_state_id, p_scn, p_table_name, p_operation, p_sql_redo,
            p_err_code, SUBSTR(p_err_msg, 1, 4000),
            SUBSTR(p_backtrace, 1, 4000), p_lob_fb, SYSTIMESTAMP
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END log_cdc_error;

    -- ----------------------------------------------------------
    -- start_logminer: LogMiner を起動する
    -- CDB$ROOT コンテキストで呼び出すこと（ADD_LOGFILE は PDB 不可）
    -- ----------------------------------------------------------
    PROCEDURE start_logminer(p_start_scn IN NUMBER, p_end_scn IN NUMBER) IS
    BEGIN
        -- アーカイブログ: p_start_scn 以降を含む範囲を追加
        FOR rec IN (
            SELECT NAME AS MEMBER
            FROM V$ARCHIVED_LOG
            WHERE NEXT_CHANGE# > p_start_scn
              AND STANDBY_DEST  = 'NO'
              AND DELETED       = 'NO'
            ORDER BY FIRST_CHANGE#
        ) LOOP
            BEGIN
                DBMS_LOGMNR.ADD_LOGFILE(
                    LOGFILENAME => rec.MEMBER,
                    OPTIONS     => DBMS_LOGMNR.ADDFILE
                );
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
        END LOOP;

        -- オンライン redo log (CURRENT / ACTIVE または p_start_scn 以降を含むもの)
        FOR rec IN (
            SELECT DISTINCT l.MEMBER
            FROM V$LOGFILE l
            JOIN V$LOG     g ON l.GROUP# = g.GROUP#
            WHERE g.STATUS IN ('CURRENT', 'ACTIVE')
               OR g.NEXT_CHANGE# > p_start_scn
        ) LOOP
            BEGIN
                DBMS_LOGMNR.ADD_LOGFILE(
                    LOGFILENAME => rec.MEMBER,
                    OPTIONS     => DBMS_LOGMNR.ADDFILE
                );
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
        END LOOP;

        DBMS_LOGMNR.START_LOGMNR(
            STARTSCN => p_start_scn,
            ENDSCN   => p_end_scn,
            OPTIONS  => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG
                      + DBMS_LOGMNR.NO_ROWID_IN_STMT
        );
    END start_logminer;

    -- ----------------------------------------------------------
    -- handle_lob_fallback: EMPTY_BLOB()/EMPTY_CLOB() 検出時の処理
    -- FLASHBACK QUERY で SCN 時点の LOB 値を取得して tgt に適用する
    -- XEPDB1 コンテキストで呼び出すこと
    -- ----------------------------------------------------------
    PROCEDURE handle_lob_fallback(
        p_state_id   IN NUMBER,
        p_scn        IN NUMBER,
        p_table_name IN VARCHAR2,
        p_pk_col     IN VARCHAR2,
        p_pk_val     IN VARCHAR2,
        p_sql_redo   IN VARCHAR2
    ) IS
        TYPE t_lob_map IS TABLE OF VARCHAR2(500) INDEX BY VARCHAR2(100);
        v_lob_map  t_lob_map;
        v_col_name VARCHAR2(100);
        v_lob_type VARCHAR2(10);
        v_pos      NUMBER;
        v_entry    VARCHAR2(200);
        v_rem      VARCHAR2(500);
        v_clob_val CLOB;
        v_blob_val BLOB;
        v_lob_len  NUMBER;
    BEGIN
        v_lob_map('PRODUCT_CATEGORIES') := 'ICON_IMAGE:BLOB,DESCRIPTION:CLOB';
        v_lob_map('CUSTOMERS')          := 'AVATAR_IMAGE:BLOB,REMARKS:CLOB';
        v_lob_map('PRODUCTS')           := 'THUMBNAIL:BLOB,DESCRIPTION:CLOB,SPEC_JSON:CLOB';
        v_lob_map('ORDERS')             := 'SHIPPING_ADDRESS:CLOB';
        v_lob_map('CUSTOMER_CONTRACTS') := 'CONTRACT_TEXT:CLOB,CONTRACT_PDF:BLOB,SIGNED_IMAGE:BLOB';
        v_lob_map('SYSTEM_EVENTS')      := 'EVENT_PAYLOAD:CLOB';

        IF NOT v_lob_map.EXISTS(UPPER(p_table_name)) THEN
            RETURN;
        END IF;

        v_rem := v_lob_map(UPPER(p_table_name));

        WHILE LENGTH(v_rem) > 0 LOOP
            v_pos := INSTR(v_rem, ',');
            IF v_pos = 0 THEN
                v_entry := v_rem;
                v_rem   := '';
            ELSE
                v_entry := SUBSTR(v_rem, 1, v_pos - 1);
                v_rem   := SUBSTR(v_rem, v_pos + 1);
            END IF;

            v_col_name := SUBSTR(v_entry, 1, INSTR(v_entry, ':') - 1);
            v_lob_type := SUBSTR(v_entry, INSTR(v_entry, ':') + 1);

            IF v_lob_type = 'CLOB' AND
               INSTR(UPPER(p_sql_redo), 'EMPTY_CLOB()') > 0
            THEN
                BEGIN
                    EXECUTE IMMEDIATE
                        'SELECT ' || v_col_name ||
                        ' FROM src_schema.' || p_table_name ||
                        ' AS OF SCN ' || p_scn ||
                        ' WHERE ' || p_pk_col || ' = :1'
                    INTO v_clob_val USING TO_NUMBER(p_pk_val);

                    IF v_clob_val IS NOT NULL AND DBMS_LOB.GETLENGTH(v_clob_val) > 0 THEN
                        v_lob_len := DBMS_LOB.GETLENGTH(v_clob_val);
                        IF v_lob_len <= 32767 THEN
                            tgt_schema.update_clob_col@tgt_db(
                                p_table_name, p_pk_col, TO_NUMBER(p_pk_val),
                                v_col_name, DBMS_LOB.SUBSTR(v_clob_val, 32767, 1)
                            );
                            log_cdc_error(p_state_id, p_scn, p_table_name, 'LOB_FALLBACK',
                                p_sql_redo, 0,
                                'CLOB fallback applied: ' || v_col_name || ' pk=' || p_pk_val,
                                NULL, 1);
                        ELSE
                            log_cdc_error(p_state_id, p_scn, p_table_name, 'LARGE_CLOB_SKIPPED',
                                p_sql_redo, -20012,
                                'CLOB size ' || v_lob_len ||
                                ' chars exceeds 32KB limit. col=' || v_col_name ||
                                ' pk=' || p_pk_val, NULL, 1);
                        END IF;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        log_cdc_error(p_state_id, p_scn, p_table_name, 'LOB_FALLBACK_ERR',
                            p_sql_redo, SQLCODE, SQLERRM,
                            DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1);
                END;

            ELSIF v_lob_type = 'BLOB' AND
                  INSTR(UPPER(p_sql_redo), 'EMPTY_BLOB()') > 0
            THEN
                BEGIN
                    EXECUTE IMMEDIATE
                        'SELECT ' || v_col_name ||
                        ' FROM src_schema.' || p_table_name ||
                        ' AS OF SCN ' || p_scn ||
                        ' WHERE ' || p_pk_col || ' = :1'
                    INTO v_blob_val USING TO_NUMBER(p_pk_val);

                    IF v_blob_val IS NOT NULL THEN
                        v_lob_len := DBMS_LOB.GETLENGTH(v_blob_val);
                        IF v_lob_len <= 32767 THEN
                            tgt_schema.update_blob_col@tgt_db(
                                p_table_name, p_pk_col, TO_NUMBER(p_pk_val),
                                v_col_name, DBMS_LOB.SUBSTR(v_blob_val, 32767, 1)
                            );
                            log_cdc_error(p_state_id, p_scn, p_table_name, 'LOB_FALLBACK',
                                p_sql_redo, 0,
                                'BLOB fallback applied: ' || v_col_name ||
                                ' size=' || v_lob_len || ' pk=' || p_pk_val, NULL, 1);
                        ELSE
                            log_cdc_error(p_state_id, p_scn, p_table_name, 'LARGE_BLOB_SKIPPED',
                                p_sql_redo, -20011,
                                'BLOB size ' || v_lob_len ||
                                ' bytes exceeds 32KB RAW limit. col=' || v_col_name ||
                                ' pk=' || p_pk_val, NULL, 1);
                        END IF;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        log_cdc_error(p_state_id, p_scn, p_table_name, 'LOB_FALLBACK_ERR',
                            p_sql_redo, SQLCODE, SQLERRM,
                            DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1);
                END;
            END IF;
        END LOOP;
    END handle_lob_fallback;

    -- ----------------------------------------------------------
    -- apply_change: 1件の変更を oracle-tgt に適用する
    -- XEPDB1 コンテキストで呼び出すこと
    -- ----------------------------------------------------------
    PROCEDURE apply_change(
        p_state_id   IN NUMBER,
        p_scn        IN NUMBER,
        p_table_name IN VARCHAR2,
        p_pk_col     IN VARCHAR2,
        p_pk_val     IN VARCHAR2,
        p_operation  IN VARCHAR2,
        p_sql_redo   IN VARCHAR2
    ) IS
        v_sql       VARCHAR2(32767);
        v_has_lob   BOOLEAN;
        v_err_code  NUMBER;
        v_err_msg   VARCHAR2(4000);
        v_backtrace VARCHAR2(4000);
    BEGIN
        IF p_sql_redo IS NULL OR LENGTH(p_sql_redo) = 0 THEN
            RETURN;
        END IF;

        v_sql := p_sql_redo;
        v_sql := REPLACE(v_sql, '"SRC_SCHEMA"', '"TGT_SCHEMA"');
        v_sql := REPLACE(v_sql, 'SRC_SCHEMA.',  'TGT_SCHEMA.');

        v_has_lob := (INSTR(UPPER(v_sql), 'EMPTY_BLOB()') > 0 OR
                      INSTR(UPPER(v_sql), 'EMPTY_CLOB()') > 0);

        BEGIN
            tgt_schema.exec_dml@tgt_db(v_sql);
        EXCEPTION
            WHEN OTHERS THEN
                v_err_code  := SQLCODE;
                v_err_msg   := SUBSTR(SQLERRM, 1, 4000);
                v_backtrace := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
                log_cdc_error(p_state_id, p_scn, p_table_name, p_operation,
                    p_sql_redo, v_err_code, v_err_msg, v_backtrace, 0);
                RETURN;
        END;

        IF v_has_lob AND p_operation IN ('INSERT', 'UPDATE') THEN
            handle_lob_fallback(p_state_id, p_scn, p_table_name,
                p_pk_col, p_pk_val, p_sql_redo);
        END IF;
    END apply_change;

    -- ----------------------------------------------------------
    -- process_batch: LogMiner で変更を読み取り oracle-tgt に適用するコアロジック
    -- Oracle 21c 対応: CDB$ROOT で収集 → XEPDB1 で適用の 2 フェーズ構成
    -- AUTHID CURRENT_USER のため SYS 所有ジョブから呼ばれる前提
    -- ----------------------------------------------------------
    PROCEDURE process_batch(
        p_run_name IN VARCHAR2,
        p_max_scn  IN NUMBER DEFAULT NULL
    ) IS
        -- CDB$ROOT から収集した変更を XEPDB1 に持ち越すためのコレクション型
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
        v_change_cnt   NUMBER    := 0;
        v_idx          PLS_INTEGER := 0;
        i              PLS_INTEGER;
        v_in_cdb       BOOLEAN   := FALSE;

    BEGIN
        -- フェーズ 1: XEPDB1 コンテキストで cdc_state を読み取る
        SELECT state_id, snapshot_scn, NVL(last_applied_scn, snapshot_scn)
        INTO   v_state_id, v_snapshot_scn, v_last_scn
        FROM   cdc_schema.cdc_state
        WHERE  run_name = p_run_name
          AND  status IN ('IDLE', 'RUNNING');

        SELECT CURRENT_SCN INTO v_current_scn FROM V$DATABASE;
        v_end_scn := NVL(p_max_scn, v_current_scn);

        IF v_last_scn >= v_end_scn THEN
            RETURN;
        END IF;

        -- XEPDB1 の CON_ID を保存（CDB$ROOT での V$LOGMNR_CONTENTS フィルタ用）
        v_pdb_con_id := TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID'));

        UPDATE cdc_schema.cdc_state
        SET status = 'RUNNING', last_run_at = SYSTIMESTAMP
        WHERE state_id = v_state_id;
        COMMIT;

        -- フェーズ 2: CDB$ROOT に切り替えて LogMiner を実行し変更を収集
        -- ADD_LOGFILE / START_LOGMNR は CDB$ROOT からのみ実行可能（ORA-65040 回避）
        EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = CDB$ROOT';
        v_in_cdb := TRUE;

        BEGIN
            start_logminer(v_last_scn + 1, v_end_scn);

            -- V$LOGMNR_CONTENTS を PL/SQL コレクションに収集
            -- SQL_REDO は VARCHAR2(32767) に変換してクロスコンテナ CLOB 問題を回避
            FOR rec IN (
                SELECT
                    SCN,
                    SEG_NAME    AS table_name,
                    OPERATION,
                    DBMS_LOB.SUBSTR(SQL_REDO, 32767, 1) AS sql_redo_str,
                    RS_ID,
                    SSN
                FROM V$LOGMNR_CONTENTS
                WHERE SEG_OWNER  = 'SRC_SCHEMA'
                  AND OPERATION IN ('INSERT', 'UPDATE', 'DELETE')
                  AND CON_ID     = v_pdb_con_id
                  AND SCN        > v_last_scn
                  AND SCN        <= v_end_scn
                ORDER BY
                    SCN,
                    RS_ID,
                    SSN,
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
        EXCEPTION
            WHEN OTHERS THEN
                BEGIN DBMS_LOGMNR.END_LOGMNR; EXCEPTION WHEN OTHERS THEN NULL; END;
                RAISE;
        END;

        -- フェーズ 3: XEPDB1 に戻って収集した変更を oracle-tgt に適用
        EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = XEPDB1';
        v_in_cdb := FALSE;

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
                    '"' || v_pk_col || '" = (\d+)',
                    1, 1, NULL, 1
                );
            EXCEPTION
                WHEN OTHERS THEN v_pk_val := NULL;
            END;

            apply_change(
                v_state_id,
                v_changes(i).scn,
                v_changes(i).table_name,
                v_pk_col,
                v_pk_val,
                v_changes(i).operation,
                v_changes(i).sql_redo
            );

            v_change_cnt := v_change_cnt + 1;
            i := v_changes.NEXT(i);
        END LOOP;

        COMMIT;
        UPDATE cdc_schema.cdc_state
        SET
            last_applied_scn = v_end_scn,
            status           = 'IDLE',
            last_run_at      = SYSTIMESTAMP
        WHERE state_id = v_state_id;
        COMMIT;

        DBMS_OUTPUT.PUT_LINE('process_batch: applied=' || v_change_cnt ||
                             ' changes, scn_range=[' || (v_last_scn + 1) ||
                             ', ' || v_end_scn || ']');

    EXCEPTION
        WHEN OTHERS THEN
            v_err_code  := SQLCODE;
            v_err_msg   := SUBSTR(SQLERRM, 1, 4000);
            v_backtrace := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
            -- CDB$ROOT にいる場合は先に XEPDB1 に戻る（cdc_state / cdc_error_log は XEPDB1）
            IF v_in_cdb THEN
                BEGIN
                    EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = XEPDB1';
                EXCEPTION WHEN OTHERS THEN NULL; END;
            END IF;
            BEGIN
                UPDATE cdc_schema.cdc_state
                SET
                    status        = 'ERROR',
                    error_message = v_err_msg,
                    last_run_at   = SYSTIMESTAMP
                WHERE state_id = v_state_id;
                COMMIT;
            EXCEPTION WHEN OTHERS THEN NULL; END;
            log_cdc_error(v_state_id, NULL, 'PROCESS_BATCH', NULL, NULL,
                v_err_code, v_err_msg, v_backtrace, 0);
            RAISE;
    END process_batch;

    -- ----------------------------------------------------------
    -- start_cdc: DBMS_SCHEDULER ジョブを作成して CDC を開始する
    -- SYS として呼び出すこと（ジョブ所有者 = SYS になり process_batch が CDB 切替可能）
    -- ----------------------------------------------------------
    PROCEDURE start_cdc(
        p_run_name     IN VARCHAR2,
        p_interval_sec IN NUMBER DEFAULT 10
    ) IS
        v_job_name   VARCHAR2(100) := 'CDC_JOB_' || UPPER(p_run_name);
        v_job_action VARCHAR2(4000);
    BEGIN
        BEGIN
            DBMS_SCHEDULER.STOP_JOB(job_name => v_job_name, force => TRUE);
            DBMS_SCHEDULER.DROP_JOB(job_name => v_job_name, force => TRUE);
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        v_job_action :=
            'BEGIN cdc_schema.pkg_cdc_logminer.process_batch(''' ||
            p_run_name || '''); END;';

        DBMS_SCHEDULER.CREATE_JOB(
            job_name        => v_job_name,
            job_type        => 'PLSQL_BLOCK',
            job_action      => v_job_action,
            repeat_interval => 'FREQ=SECONDLY;INTERVAL=' || p_interval_sec,
            enabled         => TRUE,
            auto_drop       => FALSE,
            comments        => 'CDC batch job for run_name=' || p_run_name
        );

        DBMS_OUTPUT.PUT_LINE('CDC job started: ' || v_job_name ||
                             ' (interval=' || p_interval_sec || 's)');
    END start_cdc;

    -- ----------------------------------------------------------
    -- stop_cdc: CDC ジョブを停止する
    -- ----------------------------------------------------------
    PROCEDURE stop_cdc(p_run_name IN VARCHAR2) IS
        v_job_name VARCHAR2(100) := 'CDC_JOB_' || UPPER(p_run_name);
    BEGIN
        BEGIN
            DBMS_SCHEDULER.STOP_JOB(job_name => v_job_name, force => TRUE);
            DBMS_SCHEDULER.DROP_JOB(job_name => v_job_name, force => TRUE);
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        UPDATE cdc_schema.cdc_state
        SET status = 'STOPPED', finished_at = SYSTIMESTAMP
        WHERE run_name = p_run_name;
        COMMIT;

        DBMS_OUTPUT.PUT_LINE('CDC job stopped: ' || v_job_name);
    END stop_cdc;

    -- ----------------------------------------------------------
    -- get_cdc_lag: 現在の CDC 遅延 (oracle-src の最新 SCN - last_applied_scn)
    -- ----------------------------------------------------------
    FUNCTION get_cdc_lag(p_run_name IN VARCHAR2) RETURN NUMBER IS
        v_current_scn  NUMBER;
        v_last_applied NUMBER;
    BEGIN
        SELECT CURRENT_SCN INTO v_current_scn FROM V$DATABASE;

        SELECT NVL(last_applied_scn, snapshot_scn)
        INTO   v_last_applied
        FROM   cdc_schema.cdc_state
        WHERE  run_name = p_run_name;

        RETURN v_current_scn - v_last_applied;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END get_cdc_lag;

END pkg_cdc_logminer;
/
SHOW ERRORS PACKAGE BODY cdc_schema.pkg_cdc_logminer;

PROMPT pkg_cdc_logminer created.
EXIT;
