-- Phase 2: pkg_transform — STAGING→TARGET 変換の制御・実行・ログ（機構完成版）
-- 設計: docs/phase2-transform-design.md 5章/6章
--
-- 機能:
--   - カタログ駆動（transform_catalog）で 3分類すべてを処理:
--       PASS_THROUGH   → 汎用 transform_passthrough（動的SQLで1:1コピー/MERGE）
--       LIGHT/HEAVY    → proc_name の専用プロシージャ
--   - INITIAL: 子→親 DELETE 後、親→子 で全量変換。state を snapshot に進める。
--   - DELTA  : スナップショット窓 (last_transform_at, snap] を MERGE（冪等）。
--              さらに削除伝播（STAGING に無い PK を TARGET から子→親順で削除）。
--   - 差分窓: effective_ts = NVL(updated_at, created_at) を使用（全対象表が両列を持つ前提）。
--   - ログは AUTONOMOUS TRANSACTION。
-- 所有: LOG_SCHEMA / 実行: SYS AS SYSDBA / 対象: oracle-tgt XEPDB1 / Oracle 12c 互換

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

CREATE OR REPLACE PACKAGE log_schema.pkg_transform AS
    C_MODE_INITIAL CONSTANT VARCHAR2(10) := 'INITIAL';
    C_MODE_DELTA   CONSTANT VARCHAR2(10) := 'DELTA';

    PROCEDURE transform_all(
        p_run_name         IN VARCHAR2,
        p_mode             IN VARCHAR2 DEFAULT 'DELTA',
        p_batch_size       IN NUMBER   DEFAULT 10000,
        p_propagate_delete IN VARCHAR2 DEFAULT 'Y'   -- DELTA時に削除伝播するか
    );

    -- ※ per-table 変換(transform_<tgt>)は pkg_transform_gen に生成される（pkg_codegen）。
    --   transform_all は transform_catalog.proc_name を完全修飾名で動的呼び出しする。

    -- PASS_THROUGH 汎用（動的SQL）
    PROCEDURE transform_passthrough(p_run_id IN NUMBER, p_tgt_table IN VARCHAR2,
                                    p_pk_columns IN VARCHAR2, p_mode IN VARCHAR2,
                                    p_last IN TIMESTAMP, p_snap IN TIMESTAMP);

    -- ログ
    FUNCTION  log_run_start(p_run_name IN VARCHAR2, p_mode IN VARCHAR2) RETURN NUMBER;
    PROCEDURE log_run_end(p_run_id IN NUMBER, p_status IN VARCHAR2,
                          p_src_count IN NUMBER DEFAULT 0, p_tgt_count IN NUMBER DEFAULT 0,
                          p_error_msg IN VARCHAR2 DEFAULT NULL);
    PROCEDURE log_step(p_run_id IN NUMBER, p_step_name IN VARCHAR2, p_status IN VARCHAR2,
                       p_src_count IN NUMBER DEFAULT 0, p_tgt_count IN NUMBER DEFAULT 0,
                       p_batch_no IN NUMBER DEFAULT 0);
    PROCEDURE log_error(p_run_id IN NUMBER, p_step_name IN VARCHAR2,
                        p_error_code IN NUMBER, p_error_msg IN VARCHAR2, p_backtrace IN VARCHAR2,
                        p_target_table IN VARCHAR2 DEFAULT NULL, p_error_context IN VARCHAR2 DEFAULT NULL);
END pkg_transform;
/
SHOW ERRORS PACKAGE log_schema.pkg_transform;

CREATE OR REPLACE PACKAGE BODY log_schema.pkg_transform AS

    ------------------------------------------------------------------
    -- ログ（AUTONOMOUS TRANSACTION）
    ------------------------------------------------------------------
    FUNCTION log_run_start(p_run_name IN VARCHAR2, p_mode IN VARCHAR2) RETURN NUMBER IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_id NUMBER;
    BEGIN
        SELECT log_schema.seq_run_id.NEXTVAL INTO v_id FROM DUAL;
        INSERT INTO log_schema.migration_run_log(run_id, run_name, run_mode, status)
        VALUES (v_id, p_run_name, p_mode, 'RUNNING');
        COMMIT;
        RETURN v_id;
    END log_run_start;

    PROCEDURE log_run_end(p_run_id IN NUMBER, p_status IN VARCHAR2,
                          p_src_count IN NUMBER DEFAULT 0, p_tgt_count IN NUMBER DEFAULT 0,
                          p_error_msg IN VARCHAR2 DEFAULT NULL) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE log_schema.migration_run_log
        SET status = p_status, src_count = p_src_count, tgt_count = p_tgt_count,
            ended_at = SYSTIMESTAMP, error_message = p_error_msg
        WHERE run_id = p_run_id;
        COMMIT;
    END log_run_end;

    PROCEDURE log_step(p_run_id IN NUMBER, p_step_name IN VARCHAR2, p_status IN VARCHAR2,
                       p_src_count IN NUMBER DEFAULT 0, p_tgt_count IN NUMBER DEFAULT 0,
                       p_batch_no IN NUMBER DEFAULT 0) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO log_schema.migration_step_log(step_id, run_id, step_name, status,
                                                  src_count, tgt_count, batch_no)
        VALUES (log_schema.seq_step_id.NEXTVAL, p_run_id, p_step_name, p_status,
                p_src_count, p_tgt_count, p_batch_no);
        COMMIT;
    END log_step;

    PROCEDURE log_error(p_run_id IN NUMBER, p_step_name IN VARCHAR2,
                        p_error_code IN NUMBER, p_error_msg IN VARCHAR2, p_backtrace IN VARCHAR2,
                        p_target_table IN VARCHAR2 DEFAULT NULL, p_error_context IN VARCHAR2 DEFAULT NULL) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO log_schema.migration_error_log(error_id, run_id, step_name, target_table,
                                                   error_code, error_message, error_context, backtrace)
        VALUES (log_schema.seq_error_id.NEXTVAL, p_run_id, p_step_name, p_target_table,
                p_error_code, p_error_msg, p_error_context, p_backtrace);
        COMMIT;
    END log_error;

    ------------------------------------------------------------------
    -- 内部ユーティリティ: STAGING と TARGET の共通列（LOB除外）を返す
    ------------------------------------------------------------------
    FUNCTION common_columns(p_table IN VARCHAR2) RETURN VARCHAR2 IS
        v_list VARCHAR2(4000);
    BEGIN
        FOR c IN (
            SELECT s.column_name
            FROM dba_tab_columns s
            JOIN dba_tab_columns t
              ON t.owner = 'TARGET_SCHEMA' AND t.table_name = p_table
             AND t.column_name = s.column_name
            WHERE s.owner = 'STAGING_SCHEMA' AND s.table_name = p_table
              AND s.data_type NOT IN ('CLOB','BLOB','NCLOB')
            ORDER BY s.column_id
        ) LOOP
            v_list := v_list || CASE WHEN v_list IS NULL THEN '' ELSE ',' END || '"' || c.column_name || '"';
        END LOOP;
        RETURN v_list;
    END common_columns;

    -- 差分窓 WHERE（DELTA時のみ付与。effective_ts = NVL(updated_at, created_at)）
    FUNCTION delta_where(p_mode IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_mode = C_MODE_DELTA THEN
            RETURN ' WHERE NVL(s.updated_at, s.created_at) > :last ' ||
                   ' AND NVL(s.updated_at, s.created_at) <= :snap ';
        ELSE
            RETURN '';
        END IF;
    END delta_where;

    ------------------------------------------------------------------
    -- PASS_THROUGH 汎用（動的SQL）: 共通列を 1:1 でコピー/MERGE
    ------------------------------------------------------------------
    PROCEDURE transform_passthrough(p_run_id IN NUMBER, p_tgt_table IN VARCHAR2,
                                    p_pk_columns IN VARCHAR2, p_mode IN VARCHAR2,
                                    p_last IN TIMESTAMP, p_snap IN TIMESTAMP) IS
        v_cols     VARCHAR2(4000) := common_columns(p_tgt_table);
        v_pk       VARCHAR2(400)  := '"' || REPLACE(p_pk_columns, ',', '","') || '"';
        v_on       VARCHAR2(1000);
        v_set      VARCHAR2(4000);
        v_ins_cols VARCHAR2(4000);
        v_ins_vals VARCHAR2(4000);
        v_sql      VARCHAR2(8000);
        v_src      NUMBER; v_tgt NUMBER;
        v_pk_set   VARCHAR2(400) := ',' || UPPER(p_pk_columns) || ',';
        v_step     VARCHAR2(100) := 'PASSTHROUGH_' || p_tgt_table;
    BEGIN
        log_step(p_run_id, v_step, 'RUNNING');

        IF p_mode = C_MODE_INITIAL THEN
            -- INITIAL: 親テーブルの DELETE は transform_all が実施済み。ここは INSERT のみ。
            v_sql := 'INSERT INTO target_schema."' || p_tgt_table || '" (' || v_cols || ') ' ||
                     'SELECT ' || v_cols || ' FROM staging_schema."' || p_tgt_table || '" s';
            EXECUTE IMMEDIATE v_sql;
        ELSE
            -- DELTA: ON句・SET句・INSERT句を動的生成して MERGE
            FOR c IN (
                SELECT s.column_name
                FROM dba_tab_columns s
                JOIN dba_tab_columns t
                  ON t.owner='TARGET_SCHEMA' AND t.table_name=p_tgt_table AND t.column_name=s.column_name
                WHERE s.owner='STAGING_SCHEMA' AND s.table_name=p_tgt_table
                  AND s.data_type NOT IN ('CLOB','BLOB','NCLOB')
                ORDER BY s.column_id
            ) LOOP
                v_ins_cols := v_ins_cols || CASE WHEN v_ins_cols IS NULL THEN '' ELSE ',' END
                             || '"' || c.column_name || '"';
                v_ins_vals := v_ins_vals || CASE WHEN v_ins_vals IS NULL THEN '' ELSE ',' END
                             || 'src."' || c.column_name || '"';
                IF INSTR(v_pk_set, ',' || c.column_name || ',') > 0 THEN
                    v_on := v_on || CASE WHEN v_on IS NULL THEN '' ELSE ' AND ' END
                            || 't."' || c.column_name || '"=src."' || c.column_name || '"';
                ELSE
                    v_set := v_set || CASE WHEN v_set IS NULL THEN '' ELSE ',' END
                             || 't."' || c.column_name || '"=src."' || c.column_name || '"';
                END IF;
            END LOOP;

            v_sql := 'MERGE INTO target_schema."' || p_tgt_table || '" t USING (' ||
                     'SELECT ' || v_cols || ' FROM staging_schema."' || p_tgt_table || '" s' ||
                     delta_where(p_mode) || ') src ON (' || v_on || ') ' ||
                     'WHEN MATCHED THEN UPDATE SET ' || v_set || ' ' ||
                     'WHEN NOT MATCHED THEN INSERT (' || v_ins_cols || ') VALUES (' || v_ins_vals || ')';
            EXECUTE IMMEDIATE v_sql USING p_last, p_snap;
        END IF;

        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM staging_schema."' || p_tgt_table || '"' INTO v_src;
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM target_schema."'  || p_tgt_table || '"' INTO v_tgt;
        log_step(p_run_id, v_step, 'SUCCESS', v_src, v_tgt);
    END transform_passthrough;

    ------------------------------------------------------------------
    -- 削除伝播: STAGING に無い PK を TARGET から削除（DELTA時）
    ------------------------------------------------------------------
    PROCEDURE propagate_delete(p_run_id IN NUMBER, p_tgt_table IN VARCHAR2,
                               p_pk_columns IN VARCHAR2, p_src_table IN VARCHAR2) IS
        v_join VARCHAR2(1000);
        v_sql  VARCHAR2(4000);
        v_cnt  NUMBER;
        v_src  VARCHAR2(100) := NVL(p_src_table, p_tgt_table);  -- 検出元 STAGING 表
    BEGIN
        -- 単一/複合PK対応の相関条件を生成（PK列は TARGET と検出元 STAGING で同名前提）
        FOR c IN (
            SELECT TRIM(REGEXP_SUBSTR(p_pk_columns, '[^,]+', 1, LEVEL)) AS col
            FROM DUAL CONNECT BY LEVEL <= REGEXP_COUNT(p_pk_columns, ',') + 1
        ) LOOP
            v_join := v_join || CASE WHEN v_join IS NULL THEN '' ELSE ' AND ' END
                      || 's."' || c.col || '"=t."' || c.col || '"';
        END LOOP;

        -- 検出元 STAGING 表に存在しない PK を TARGET から削除
        --   通常表: 検出元=同名。派生表(order_enriched): 検出元=駆動表(orders)。
        v_sql := 'DELETE FROM target_schema."' || p_tgt_table || '" t ' ||
                 'WHERE NOT EXISTS (SELECT 1 FROM staging_schema."' || v_src || '" s ' ||
                 'WHERE ' || v_join || ')';
        EXECUTE IMMEDIATE v_sql;
        v_cnt := SQL%ROWCOUNT;
        log_step(p_run_id, 'DELETE_PROP_' || p_tgt_table, 'SUCCESS', 0, v_cnt);
    END propagate_delete;

    ------------------------------------------------------------------
    -- 全テーブル変換（カタログ駆動）
    ------------------------------------------------------------------
    PROCEDURE transform_all(p_run_name IN VARCHAR2, p_mode IN VARCHAR2 DEFAULT 'DELTA',
                            p_batch_size IN NUMBER DEFAULT 10000,
                            p_propagate_delete IN VARCHAR2 DEFAULT 'Y') IS
        v_run_id    NUMBER;
        v_running   NUMBER;
        v_snap      TIMESTAMP := SYSTIMESTAMP;   -- 差分窓の上限（このバッチのスナップショット）
        v_last      TIMESTAMP;
        v_tgt_total NUMBER := 0;
    BEGIN
        IF p_mode NOT IN (C_MODE_INITIAL, C_MODE_DELTA) THEN
            RAISE_APPLICATION_ERROR(-20001, 'invalid mode: ' || p_mode);
        END IF;

        SELECT COUNT(*) INTO v_running FROM log_schema.migration_run_log
        WHERE run_name = p_run_name AND status = 'RUNNING';
        IF v_running > 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'run already RUNNING: ' || p_run_name);
        END IF;

        v_run_id := log_run_start(p_run_name, p_mode);

        -- INITIAL: 子→親（sort_order DESC）で TARGET 全削除
        IF p_mode = C_MODE_INITIAL THEN
            FOR c IN (SELECT tgt_table_name FROM log_schema.transform_catalog
                      WHERE is_active='Y' ORDER BY sort_order DESC) LOOP
                EXECUTE IMMEDIATE 'DELETE FROM target_schema.' || c.tgt_table_name;
            END LOOP;
            COMMIT;
        END IF;

        -- 親→子（sort_order ASC）で upsert
        FOR c IN (SELECT tgt_table_name, transform_class, proc_name, pk_columns
                  FROM log_schema.transform_catalog
                  WHERE is_active='Y' ORDER BY sort_order ASC) LOOP

            SELECT last_transform_at INTO v_last FROM log_schema.transform_state
            WHERE tgt_table_name = c.tgt_table_name;

            IF c.transform_class = 'PASS_THROUGH' THEN
                transform_passthrough(v_run_id, c.tgt_table_name, c.pk_columns, p_mode, v_last, v_snap);
            ELSIF c.proc_name IS NOT NULL THEN
                -- proc_name は完全修飾名（例 LOG_SCHEMA.PKG_TRANSFORM_GEN.TRANSFORM_CUSTOMERS）
                -- = pkg_codegen が生成した per-table 変換プロシージャ
                EXECUTE IMMEDIATE
                    'BEGIN ' || c.proc_name || '(:1, :2, :3, :4); END;'
                    USING v_run_id, p_mode, v_last, v_snap;
            END IF;
            COMMIT;  -- 親→子のFK順を守ってテーブル単位で確定
        END LOOP;

        -- DELTA: 削除伝播（子→親順）
        IF p_mode = C_MODE_DELTA AND p_propagate_delete = 'Y' THEN
            FOR c IN (SELECT tgt_table_name, pk_columns, delete_src_table FROM log_schema.transform_catalog
                      WHERE is_active='Y' ORDER BY sort_order DESC) LOOP
                propagate_delete(v_run_id, c.tgt_table_name, c.pk_columns, c.delete_src_table);
            END LOOP;
            COMMIT;
        END IF;

        -- state を snapshot に進める（次回 DELTA の起点）
        UPDATE log_schema.transform_state
        SET last_transform_at = v_snap, last_run_id = v_run_id, updated_at = SYSTIMESTAMP
        WHERE tgt_table_name IN (SELECT tgt_table_name FROM log_schema.transform_catalog WHERE is_active='Y');
        COMMIT;

        SELECT COUNT(*) INTO v_tgt_total FROM target_schema.orders;
        log_run_end(v_run_id, 'SUCCESS', 0, v_tgt_total);

        DBMS_OUTPUT.PUT_LINE('transform_all: run_id=' || v_run_id ||
                             ' mode=' || p_mode || ' status=SUCCESS tgt_orders=' || v_tgt_total);

    EXCEPTION WHEN OTHERS THEN
        IF v_run_id IS NOT NULL THEN
            log_error(v_run_id, 'TRANSFORM_ALL', SQLCODE, SUBSTR(SQLERRM,1,4000),
                      SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,1,4000), NULL, 'mode='||p_mode);
            log_run_end(v_run_id, 'FAILED', 0, 0, SUBSTR(SQLERRM,1,4000));
        END IF;
        DBMS_OUTPUT.PUT_LINE('transform_all FAILED: ' || SQLERRM);
        RAISE;
    END transform_all;

END pkg_transform;
/
SHOW ERRORS PACKAGE BODY log_schema.pkg_transform;

PROMPT pkg_transform (mechanism-complete: passthrough/delta/delete) created.
EXIT;
