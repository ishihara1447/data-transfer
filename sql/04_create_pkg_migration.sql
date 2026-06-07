-- 移行パッケージ作成 (LOG_SCHEMA.PKG_MIGRATION)
-- Oracle 12c 互換: SEQUENCE+TRIGGER 採番、BULK COLLECT+FOR LOOP バッチ処理
-- REGEXP_LIKE による日付形式検証、safe_to_date_yyyymmdd による変換
-- ログ記録プロシージャはすべて PRAGMA AUTONOMOUS_TRANSACTION で独立コミット

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

CONNECT log_schema/&&LOG_SCHEMA_PASS@//&&ORACLE_HOST:&&ORACLE_PORT/&&ORACLE_SERVICE

-- ============================================================
-- Package Specification
-- ============================================================
CREATE OR REPLACE PACKAGE pkg_migration AS

    PROCEDURE migrate_all(
        p_run_name   IN VARCHAR2,
        p_batch_size IN NUMBER DEFAULT 10000
    );
    PROCEDURE migrate_customer(
        p_run_id     IN NUMBER,
        p_batch_size IN NUMBER DEFAULT 10000
    );
    PROCEDURE migrate_order(
        p_run_id     IN NUMBER,
        p_batch_size IN NUMBER DEFAULT 10000
    );

    FUNCTION  log_run_start(p_run_name IN VARCHAR2) RETURN NUMBER;
    PROCEDURE log_run_end(
        p_run_id    IN NUMBER,
        p_status    IN VARCHAR2,
        p_src_count IN NUMBER  DEFAULT 0,
        p_tgt_count IN NUMBER  DEFAULT 0,
        p_error_msg IN VARCHAR2 DEFAULT NULL
    );
    PROCEDURE log_step(
        p_run_id    IN NUMBER,
        p_step_name IN VARCHAR2,
        p_status    IN VARCHAR2,
        p_src_count IN NUMBER  DEFAULT 0,
        p_tgt_count IN NUMBER  DEFAULT 0,
        p_batch_no  IN NUMBER  DEFAULT 0
    );
    PROCEDURE log_error(
        p_run_id        IN NUMBER,
        p_step_name     IN VARCHAR2,
        p_error_code    IN NUMBER,
        p_error_msg     IN VARCHAR2,
        p_backtrace     IN VARCHAR2,
        p_record_id     IN VARCHAR2 DEFAULT NULL,
        p_target_table  IN VARCHAR2 DEFAULT NULL,
        p_batch_no      IN NUMBER   DEFAULT NULL,
        p_error_context IN VARCHAR2 DEFAULT NULL
    );

END pkg_migration;
/
SHOW ERRORS PACKAGE pkg_migration;

-- ============================================================
-- Package Body
-- ============================================================
CREATE OR REPLACE PACKAGE BODY pkg_migration AS

    -- ----------------------------------------------------------
    -- safe_to_date_yyyymmdd: YYYYMMDD 文字列を DATE に変換する
    -- NULL / 非8桁数字 / 無効日付 (月=13 等) は NULL を返す
    -- ----------------------------------------------------------
    FUNCTION safe_to_date_yyyymmdd(p_str IN VARCHAR2) RETURN DATE IS
        v_date DATE;
    BEGIN
        IF p_str IS NULL OR NOT REGEXP_LIKE(p_str, '^[0-9]{8}$') THEN
            RETURN NULL;
        END IF;
        v_date := TO_DATE(p_str, 'YYYYMMDD');
        RETURN v_date;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
    END safe_to_date_yyyymmdd;

    -- ----------------------------------------------------------
    -- log_run_start: 実行開始レコードを登録し run_id を返す
    -- AUTONOMOUS TRANSACTION: メイン処理が ROLLBACK されてもログは残る
    -- ----------------------------------------------------------
    FUNCTION log_run_start(p_run_name IN VARCHAR2) RETURN NUMBER IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_run_id        NUMBER;
        v_running_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_running_count
        FROM log_schema.migration_run_log
        WHERE run_name = p_run_name AND status = 'RUNNING';

        IF v_running_count > 0 THEN
            RAISE_APPLICATION_ERROR(-20001,
                'Migration already running for run_name: ' || p_run_name);
        END IF;

        SELECT log_schema.seq_migration_run_log.NEXTVAL INTO v_run_id FROM DUAL;

        INSERT INTO log_schema.migration_run_log (
            run_id, run_name, status, started_at
        ) VALUES (
            v_run_id, p_run_name, 'RUNNING', SYSDATE
        );
        COMMIT;
        RETURN v_run_id;
    END log_run_start;

    -- ----------------------------------------------------------
    -- log_run_end: 実行終了ステータスを更新する
    -- ----------------------------------------------------------
    PROCEDURE log_run_end(
        p_run_id    IN NUMBER,
        p_status    IN VARCHAR2,
        p_src_count IN NUMBER  DEFAULT 0,
        p_tgt_count IN NUMBER  DEFAULT 0,
        p_error_msg IN VARCHAR2 DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE log_schema.migration_run_log
        SET
            status          = p_status,
            finished_at     = SYSDATE,
            total_src_count = p_src_count,
            total_tgt_count = p_tgt_count,
            error_message   = SUBSTR(p_error_msg, 1, 4000)
        WHERE run_id = p_run_id;
        COMMIT;
    END log_run_end;

    -- ----------------------------------------------------------
    -- log_step: ステップ進捗を記録する (INSERT or UPDATE)
    -- 初回呼び出し (RUNNING) で INSERT、以降 (SUCCESS/FAILED/RUNNING) で UPDATE
    -- batch_no: 現在処理中のバッチ番号 (0=バッチ未使用)
    -- ----------------------------------------------------------
    PROCEDURE log_step(
        p_run_id    IN NUMBER,
        p_step_name IN VARCHAR2,
        p_status    IN VARCHAR2,
        p_src_count IN NUMBER  DEFAULT 0,
        p_tgt_count IN NUMBER  DEFAULT 0,
        p_batch_no  IN NUMBER  DEFAULT 0
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_step_log_id NUMBER;
        v_count       NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count
        FROM log_schema.migration_step_log
        WHERE run_id = p_run_id AND step_name = p_step_name;

        IF v_count = 0 THEN
            SELECT log_schema.seq_migration_step_log.NEXTVAL INTO v_step_log_id FROM DUAL;
            INSERT INTO log_schema.migration_step_log (
                step_log_id, run_id, step_name, status,
                src_count, tgt_count, batch_no, started_at
            ) VALUES (
                v_step_log_id, p_run_id, p_step_name, p_status,
                p_src_count, p_tgt_count, p_batch_no, SYSDATE
            );
        ELSE
            UPDATE log_schema.migration_step_log
            SET
                status      = p_status,
                src_count   = p_src_count,
                tgt_count   = p_tgt_count,
                batch_no    = p_batch_no,
                finished_at = CASE
                                  WHEN p_status IN ('SUCCESS','FAILED','SKIPPED') THEN SYSDATE
                                  ELSE finished_at
                              END
            WHERE run_id = p_run_id AND step_name = p_step_name;
        END IF;
        COMMIT;
    END log_step;

    -- ----------------------------------------------------------
    -- log_error: エラー詳細 (SQLCODE/SQLERRM/BACKTRACE) を記録する
    -- ----------------------------------------------------------
    PROCEDURE log_error(
        p_run_id        IN NUMBER,
        p_step_name     IN VARCHAR2,
        p_error_code    IN NUMBER,
        p_error_msg     IN VARCHAR2,
        p_backtrace     IN VARCHAR2,
        p_record_id     IN VARCHAR2 DEFAULT NULL,
        p_target_table  IN VARCHAR2 DEFAULT NULL,
        p_batch_no      IN NUMBER   DEFAULT NULL,
        p_error_context IN VARCHAR2 DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_error_id NUMBER;
    BEGIN
        SELECT log_schema.seq_migration_error_log.NEXTVAL INTO v_error_id FROM DUAL;
        INSERT INTO log_schema.migration_error_log (
            error_id, run_id, step_name, error_code,
            error_message, error_backtrace, occurred_at,
            target_record_id, target_table, batch_no, error_context
        ) VALUES (
            v_error_id, p_run_id, p_step_name, p_error_code,
            SUBSTR(p_error_msg, 1, 4000),
            SUBSTR(p_backtrace, 1, 4000),
            SYSDATE, p_record_id, p_target_table, p_batch_no,
            SUBSTR(p_error_context, 1, 4000)
        );
        COMMIT;
    END log_error;

    -- ----------------------------------------------------------
    -- migrate_customer: 顧客マスタ移行
    -- BULK COLLECT + FOR LOOP バッチ処理 (p_batch_size 件ごとに COMMIT)
    -- 再実行対応: DELETE + INSERT (冪等設計)
    -- 変換: cust_id(VARCHAR2) → customer_id(NUMBER)
    --       create_date(YYYYMMDD) → created_at(DATE)  ← safe_to_date_yyyymmdd
    --       address → prefecture(先頭4文字の簡略版) + address_detail(全体)
    -- ----------------------------------------------------------
    PROCEDURE migrate_customer(p_run_id IN NUMBER, p_batch_size IN NUMBER DEFAULT 10000) IS
        CURSOR c_src IS
            SELECT cust_id, cust_name, tel, address, create_date
            FROM src_schema.customers;
        TYPE t_src IS TABLE OF c_src%ROWTYPE;
        v_rows       t_src;
        v_src_count  NUMBER := 0;
        v_tgt_count  NUMBER := 0;
        v_batch_no   NUMBER := 0;
        v_created_at DATE;
        v_error_code NUMBER;
        v_error_msg  VARCHAR2(4000);
        v_backtrace  VARCHAR2(4000);
    BEGIN
        log_step(p_run_id, 'MIGRATE_CUSTOMER', 'RUNNING');

        SELECT COUNT(*) INTO v_src_count FROM src_schema.customers;

        -- FK制約対応: 子テーブル(orders)を先に削除してから親テーブル(customers)を削除する
        DELETE FROM tgt_schema.orders;
        DELETE FROM tgt_schema.customers;
        COMMIT;

        OPEN c_src;
        LOOP
            FETCH c_src BULK COLLECT INTO v_rows LIMIT p_batch_size;
            EXIT WHEN v_rows.COUNT = 0;
            v_batch_no := v_batch_no + 1;

            FOR i IN 1 .. v_rows.COUNT LOOP
                v_created_at := safe_to_date_yyyymmdd(v_rows(i).create_date);
                INSERT INTO tgt_schema.customers (
                    customer_id, customer_name, phone,
                    prefecture, city, address_detail, created_at
                ) VALUES (
                    TO_NUMBER(v_rows(i).cust_id),
                    v_rows(i).cust_name,
                    v_rows(i).tel,
                    REGEXP_SUBSTR(v_rows(i).address, '^.{2,4}[都道府県]'),
                    NULL,
                    v_rows(i).address,
                    v_created_at
                );
            END LOOP;

            v_tgt_count := v_tgt_count + v_rows.COUNT;
            COMMIT;
            log_step(p_run_id, 'MIGRATE_CUSTOMER', 'RUNNING', v_src_count, v_tgt_count, v_batch_no);
        END LOOP;
        CLOSE c_src;

        log_step(p_run_id, 'MIGRATE_CUSTOMER', 'SUCCESS', v_src_count, v_tgt_count, v_batch_no);

    EXCEPTION
        WHEN OTHERS THEN
            IF c_src%ISOPEN THEN CLOSE c_src; END IF;
            v_error_code := SQLCODE;
            v_error_msg  := SUBSTR(SQLERRM, 1, 4000);
            v_backtrace  := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
            log_error(p_run_id, 'MIGRATE_CUSTOMER', v_error_code, v_error_msg, v_backtrace,
                      NULL, 'TGT_SCHEMA.CUSTOMERS', v_batch_no,
                      'tgt_count_committed=' || v_tgt_count);
            log_step(p_run_id, 'MIGRATE_CUSTOMER', 'FAILED', v_src_count, v_tgt_count, v_batch_no);
            RAISE;
    END migrate_customer;

    -- ----------------------------------------------------------
    -- migrate_order: 注文データ移行
    -- BULK COLLECT + FOR LOOP バッチ処理 (p_batch_size 件ごとに COMMIT)
    -- 再実行対応: DELETE + INSERT (冪等設計)
    -- 変換: cust_id(VARCHAR2) → customer_id(NUMBER)
    --       order_date(YYYYMMDD) → order_date(DATE)  ← safe_to_date_yyyymmdd
    --       status('10'/'20'/'30'/'99') → order_status(名称文字列)
    -- ----------------------------------------------------------
    PROCEDURE migrate_order(p_run_id IN NUMBER, p_batch_size IN NUMBER DEFAULT 10000) IS
        CURSOR c_src IS
            SELECT order_id, cust_id, order_date, amount, status
            FROM src_schema.orders;
        TYPE t_src IS TABLE OF c_src%ROWTYPE;
        v_rows       t_src;
        v_src_count  NUMBER := 0;
        v_tgt_count  NUMBER := 0;
        v_batch_no   NUMBER := 0;
        v_order_date DATE;
        v_error_code NUMBER;
        v_error_msg  VARCHAR2(4000);
        v_backtrace  VARCHAR2(4000);
    BEGIN
        log_step(p_run_id, 'MIGRATE_ORDER', 'RUNNING');

        SELECT COUNT(*) INTO v_src_count FROM src_schema.orders;

        DELETE FROM tgt_schema.orders;
        COMMIT;

        OPEN c_src;
        LOOP
            FETCH c_src BULK COLLECT INTO v_rows LIMIT p_batch_size;
            EXIT WHEN v_rows.COUNT = 0;
            v_batch_no := v_batch_no + 1;

            FOR i IN 1 .. v_rows.COUNT LOOP
                v_order_date := safe_to_date_yyyymmdd(v_rows(i).order_date);
                INSERT INTO tgt_schema.orders (
                    order_id, customer_id, order_date, total_amount, order_status
                ) VALUES (
                    v_rows(i).order_id,
                    TO_NUMBER(v_rows(i).cust_id),
                    v_order_date,
                    v_rows(i).amount,
                    CASE v_rows(i).status
                        WHEN '10' THEN 'ACCEPTED'
                        WHEN '20' THEN 'PROCESSING'
                        WHEN '30' THEN 'COMPLETED'
                        WHEN '99' THEN 'CANCELLED'
                        ELSE 'UNKNOWN'
                    END
                );
            END LOOP;

            v_tgt_count := v_tgt_count + v_rows.COUNT;
            COMMIT;
            log_step(p_run_id, 'MIGRATE_ORDER', 'RUNNING', v_src_count, v_tgt_count, v_batch_no);
        END LOOP;
        CLOSE c_src;

        log_step(p_run_id, 'MIGRATE_ORDER', 'SUCCESS', v_src_count, v_tgt_count, v_batch_no);

    EXCEPTION
        WHEN OTHERS THEN
            IF c_src%ISOPEN THEN CLOSE c_src; END IF;
            v_error_code := SQLCODE;
            v_error_msg  := SUBSTR(SQLERRM, 1, 4000);
            v_backtrace  := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
            log_error(p_run_id, 'MIGRATE_ORDER', v_error_code, v_error_msg, v_backtrace,
                      NULL, 'TGT_SCHEMA.ORDERS', v_batch_no,
                      'tgt_count_committed=' || v_tgt_count);
            log_step(p_run_id, 'MIGRATE_ORDER', 'FAILED', v_src_count, v_tgt_count, v_batch_no);
            RAISE;
    END migrate_order;

    -- ----------------------------------------------------------
    -- migrate_all: メインエントリポイント
    -- 正常終了: log_run_end('SUCCESS') → COMMIT
    -- 異常終了: ROLLBACK (未確定バッチ分) → log_error + log_run_end('FAILED') → RAISE
    -- ----------------------------------------------------------
    PROCEDURE migrate_all(p_run_name IN VARCHAR2, p_batch_size IN NUMBER DEFAULT 10000) IS
        v_run_id     NUMBER;
        v_src_count  NUMBER := 0;
        v_tgt_count  NUMBER := 0;
        v_error_code NUMBER;
        v_error_msg  VARCHAR2(4000);
        v_backtrace  VARCHAR2(4000);
    BEGIN
        v_run_id := log_run_start(p_run_name);

        migrate_customer(v_run_id, p_batch_size);
        migrate_order(v_run_id, p_batch_size);

        SELECT
            (SELECT COUNT(*) FROM src_schema.customers) +
            (SELECT COUNT(*) FROM src_schema.orders)
        INTO v_src_count
        FROM DUAL;

        SELECT
            (SELECT COUNT(*) FROM tgt_schema.customers) +
            (SELECT COUNT(*) FROM tgt_schema.orders)
        INTO v_tgt_count
        FROM DUAL;

        log_run_end(v_run_id, 'SUCCESS', v_src_count, v_tgt_count);

    EXCEPTION
        WHEN OTHERS THEN
            v_error_code := SQLCODE;
            v_error_msg  := SUBSTR(SQLERRM, 1, 4000);
            v_backtrace  := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
            ROLLBACK;
            BEGIN
                SELECT
                    (SELECT COUNT(*) FROM src_schema.customers) +
                    (SELECT COUNT(*) FROM src_schema.orders)
                INTO v_src_count
                FROM DUAL;
                SELECT
                    (SELECT COUNT(*) FROM tgt_schema.customers) +
                    (SELECT COUNT(*) FROM tgt_schema.orders)
                INTO v_tgt_count
                FROM DUAL;
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
            IF v_run_id IS NOT NULL THEN
                log_error(v_run_id, 'MIGRATE_ALL', v_error_code, v_error_msg, v_backtrace);
                log_run_end(v_run_id, 'FAILED', v_src_count, v_tgt_count, v_error_msg);
            END IF;
            RAISE;
    END migrate_all;

END pkg_migration;
/
SHOW ERRORS PACKAGE BODY pkg_migration;

PROMPT pkg_migration created.
EXIT;
