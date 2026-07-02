-- LOBテーブル差分反映方式: ターゲット側テーブル + PL/SQL (oracle-tgt 用)
-- docs/delta-extract-design.md セクション11 の設計に基づく。
--
-- 作成対象:
--   staging_ctl.lob_resync_target      : 再同期対象PKの集約表（PENDING/IN_TRANSIT/DONE）
--   staging_ctl.lob_resync_stage_customers : 取り込み用シャドウ表（STAGING_SCHEMA.CUSTOMERS と同一構造）
--   staging_ctl.lob_resync_stage_orders    : 取り込み用シャドウ表（STAGING_SCHEMA.ORDERS と同一構造）
--   SYS.lob_resync_build_targets       : delta_manual_review_queue → lob_resync_target 集約
--   SYS.lob_resync_merge               : シャドウ表 → STAGING_SCHEMA.CUSTOMERS/ORDERS MERGE
--
-- 役割分離:
--   PL/SQL: 全ての判定・集約・MERGE・COMMIT・件数カウント
--   シェル : expdp/impdp起動・docker cp搬送のみ（scripts/43_lob_resync_cycle.sh）
--
-- 実行ユーザー: SYS AS SYSDBA / 実行対象: oracle-tgt XEPDB1 / Oracle 12c 互換 / 冪等

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

SET SERVEROUTPUT ON SIZE UNLIMITED

-- ============================================================
-- staging_ctl.lob_resync_target: 再同期対象PKの集約表
-- ============================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_tables
    WHERE owner = 'STAGING_CTL' AND table_name = 'LOB_RESYNC_TARGET';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE staging_ctl.lob_resync_target PURGE';
    END IF;
END;
/

CREATE TABLE staging_ctl.lob_resync_target (
    resync_id      NUMBER GENERATED ALWAYS AS IDENTITY,
    table_name     VARCHAR2(100)  NOT NULL,   -- 対象テーブル名（例: CUSTOMERS）
    pk_value       VARCHAR2(100)  NOT NULL,   -- 主キー値（文字列化）
    last_operation VARCHAR2(20)   NOT NULL,   -- INSERT/UPDATE（最新操作）
    requested_at   TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    resync_status  VARCHAR2(20)   DEFAULT 'PENDING' NOT NULL,
    resolved_at    TIMESTAMP,
    CONSTRAINT pk_lob_resync_target    PRIMARY KEY (resync_id),
    CONSTRAINT uq_lob_resync_target    UNIQUE (table_name, pk_value),
    CONSTRAINT chk_lob_resync_status   CHECK (resync_status IN ('PENDING','IN_TRANSIT','DONE'))
);

COMMENT ON TABLE staging_ctl.lob_resync_target IS 'LOBテーブル差分反映方式（11章）: 再同期対象PKの集約表。PENDING=未処理 / IN_TRANSIT=src送信済み・行取得待ち / DONE=STAGING反映済み。';

CREATE INDEX staging_ctl.ix_lob_resync_pending
    ON staging_ctl.lob_resync_target (resync_status, table_name, requested_at);

-- ============================================================
-- staging_ctl.lob_resync_stage_customers: シャドウ表（CUSTOMERS取り込み用）
-- STAGING_SCHEMA.CUSTOMERS と同一構造（LOB列を含む）
-- CREATE AS SELECT で一致させることで列定義変更に自動追従する
-- ============================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_tables
    WHERE owner = 'STAGING_CTL' AND table_name = 'LOB_RESYNC_STAGE_CUSTOMERS';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE staging_ctl.lob_resync_stage_customers PURGE';
    END IF;
    EXECUTE IMMEDIATE
        'CREATE TABLE staging_ctl.lob_resync_stage_customers '
        || 'AS SELECT * FROM staging_schema.customers WHERE 1=0';
END;
/

COMMENT ON TABLE staging_ctl.lob_resync_stage_customers IS 'LOBテーブル差分反映: CUSTOMERS 行取り込み用シャドウ表。impdp で src から取得した行を一時格納。lob_resync_merge後TRUNCATEする。';

-- ============================================================
-- staging_ctl.lob_resync_stage_orders: シャドウ表（ORDERS取り込み用）
-- STAGING_SCHEMA.ORDERS と同一構造（LOB列を含む）
-- ============================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_tables
    WHERE owner = 'STAGING_CTL' AND table_name = 'LOB_RESYNC_STAGE_ORDERS';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE staging_ctl.lob_resync_stage_orders PURGE';
    END IF;
    EXECUTE IMMEDIATE
        'CREATE TABLE staging_ctl.lob_resync_stage_orders '
        || 'AS SELECT * FROM staging_schema.orders WHERE 1=0';
END;
/

COMMENT ON TABLE staging_ctl.lob_resync_stage_orders IS 'LOBテーブル差分反映: ORDERS 行取り込み用シャドウ表。impdp で src から取得した行を一時格納。lob_resync_merge後TRUNCATEする。';

-- ============================================================
-- SYS.lob_resync_build_targets: delta_manual_review_queue → lob_resync_target 集約
--
-- 処理内容:
--   1. fallback_reason='TABLE_HAS_LOB' AND review_status='PENDING' を commit_scn 順に走査
--   2. (table_name, pk_value) ごとに最新操作を採用（重複排除）
--   3. 最新操作が DELETE → 対象外（11.5 の即時反映で別途拾われる）
--   4. 最新操作が INSERT/UPDATE → lob_resync_target に MERGE (PENDING)
--   5. 処理済みの review_status → 'IN_REVIEW' に更新（二重集約防止）
-- ============================================================
CREATE OR REPLACE PROCEDURE SYS.lob_resync_build_targets
    AUTHID CURRENT_USER
AS
    v_build_cnt   NUMBER := 0;
    v_skip_cnt    NUMBER := 0;
    v_review_cnt  NUMBER := 0;

    -- (table_name, pk_value) ごとの最新操作を持つ集約型
    TYPE t_key_rec IS RECORD (
        table_name     VARCHAR2(100),
        pk_value       VARCHAR2(100),
        last_operation VARCHAR2(20),
        max_commit_scn NUMBER,
        review_id_list VARCHAR2(4000)  -- 集約対象の review_id を ',' 区切りで保持
    );
    TYPE t_key_tab IS TABLE OF t_key_rec INDEX BY VARCHAR2(200);  -- key='table|pk'
    v_map     t_key_tab;
    v_key     VARCHAR2(200);
    v_map_key VARCHAR2(200);
    i         PLS_INTEGER;
BEGIN
    -- Step1: PENDING な LOB行を commit_scn 順に走査し、(table_name,pk_value) ごとに最新操作を集約
    FOR rec IN (
        SELECT review_id, commit_scn, seg_name AS table_name,
               operation, pk_value
        FROM staging_ctl.delta_manual_review_queue
        WHERE fallback_reason = 'TABLE_HAS_LOB'
          AND review_status   = 'PENDING'
          AND pk_value IS NOT NULL
        ORDER BY commit_scn
    ) LOOP
        IF rec.pk_value IS NULL THEN
            CONTINUE;  -- pk_value が取れていない行はスキップ
        END IF;
        v_key := rec.table_name || '|' || rec.pk_value;
        IF v_map.EXISTS(v_key) THEN
            -- 既存エントリより新しい commit_scn なら上書き
            IF rec.commit_scn > v_map(v_key).max_commit_scn THEN
                v_map(v_key).last_operation := rec.operation;
                v_map(v_key).max_commit_scn := rec.commit_scn;
            END IF;
            -- review_id は末尾に追記（IN_REVIEW 更新対象）
            v_map(v_key).review_id_list :=
                v_map(v_key).review_id_list || ',' || rec.review_id;
        ELSE
            v_map(v_key).table_name     := rec.table_name;
            v_map(v_key).pk_value       := rec.pk_value;
            v_map(v_key).last_operation := rec.operation;
            v_map(v_key).max_commit_scn := rec.commit_scn;
            v_map(v_key).review_id_list := TO_CHAR(rec.review_id);
        END IF;
    END LOOP;

    -- Step2: 集約結果を処理
    v_map_key := v_map.FIRST;
    WHILE v_map_key IS NOT NULL LOOP
        -- 最新操作が DELETE → lob_resync_target に積まない（11.5 即時反映で拾われる）
        IF v_map(v_map_key).last_operation = 'DELETE' THEN
            v_skip_cnt := v_skip_cnt + 1;
        ELSE
            -- INSERT/UPDATE → lob_resync_target に MERGE（PENDING として登録）
            MERGE INTO staging_ctl.lob_resync_target t
            USING (SELECT v_map(v_map_key).table_name     AS tbl,
                          v_map(v_map_key).pk_value       AS pk,
                          v_map(v_map_key).last_operation AS op
                   FROM DUAL) s
            ON (t.table_name = s.tbl AND t.pk_value = s.pk)
            WHEN MATCHED THEN
                UPDATE SET last_operation = s.op,
                           resync_status  = 'PENDING',
                           requested_at   = SYSTIMESTAMP,
                           resolved_at    = NULL
            WHEN NOT MATCHED THEN
                INSERT (table_name, pk_value, last_operation, resync_status)
                VALUES (s.tbl, s.pk, s.op, 'PENDING');
            v_build_cnt := v_build_cnt + 1;
        END IF;

        -- Step3: 処理済みの review 行を IN_REVIEW に更新（二重集約防止）
        -- review_id_list をカンマ区切りで分解して UPDATE（12c 互換: REGEXP_SUBSTR ループ）
        DECLARE
            v_id_list VARCHAR2(4000) := v_map(v_map_key).review_id_list;
            v_pos     PLS_INTEGER    := 1;
            v_piece   VARCHAR2(20);
            v_rid     NUMBER;
        BEGIN
            LOOP
                v_piece := REGEXP_SUBSTR(v_id_list, '[^,]+', 1, v_pos);
                EXIT WHEN v_piece IS NULL;
                v_rid := TO_NUMBER(TRIM(v_piece));
                UPDATE staging_ctl.delta_manual_review_queue
                SET review_status = 'IN_REVIEW', reviewed_at = SYSTIMESTAMP
                WHERE review_id = v_rid AND review_status = 'PENDING';
                v_review_cnt := v_review_cnt + 1;
                v_pos := v_pos + 1;
            END LOOP;
        END;

        v_map_key := v_map.NEXT(v_map_key);
    END LOOP;

    COMMIT;

    DBMS_OUTPUT.PUT_LINE(
        'lob_resync_build_targets: registered=' || v_build_cnt
        || ' skip_delete=' || v_skip_cnt
        || ' review_updated=' || v_review_cnt);

EXCEPTION WHEN OTHERS THEN
    BEGIN ROLLBACK; EXCEPTION WHEN OTHERS THEN NULL; END;
    DBMS_OUTPUT.PUT_LINE('lob_resync_build_targets FATAL: ' || SUBSTR(SQLERRM, 1, 4000));
    RAISE;
END lob_resync_build_targets;
/
SHOW ERRORS PROCEDURE SYS.lob_resync_build_targets;

-- ============================================================
-- SYS.lob_resync_merge: シャドウ表 → STAGING_SCHEMA へ MERGE
--
-- 処理内容:
--   1. lob_resync_stage_customers → STAGING_SCHEMA.CUSTOMERS MERGE
--   2. lob_resync_stage_orders    → STAGING_SCHEMA.ORDERS    MERGE
--   3. 対応する lob_resync_target を DONE に更新
--   4. 対応する delta_manual_review_queue を RESOLVED に更新
--   5. シャドウ表を TRUNCATE（次サイクルに備える）
-- ============================================================
CREATE OR REPLACE PROCEDURE SYS.lob_resync_merge
    AUTHID CURRENT_USER
AS
    v_cust_merge  NUMBER := 0;
    v_ord_merge   NUMBER := 0;
    v_done_cnt    NUMBER := 0;
    v_resolved_cnt NUMBER := 0;

    -- カーソル: シャドウ表の行に対応する lob_resync_target の resync_id を取得
    CURSOR c_merged_customers IS
        SELECT t.resync_id, t.pk_value
        FROM staging_ctl.lob_resync_target t
        WHERE t.table_name = 'CUSTOMERS'
          AND t.resync_status = 'IN_TRANSIT'
          AND EXISTS (SELECT 1 FROM staging_ctl.lob_resync_stage_customers s
                      WHERE TO_CHAR(s.customer_id) = t.pk_value);

    CURSOR c_merged_orders IS
        SELECT t.resync_id, t.pk_value
        FROM staging_ctl.lob_resync_target t
        WHERE t.table_name = 'ORDERS'
          AND t.resync_status = 'IN_TRANSIT'
          AND EXISTS (SELECT 1 FROM staging_ctl.lob_resync_stage_orders s
                      WHERE TO_CHAR(s.order_id) = t.pk_value);
BEGIN
    -- ---- CUSTOMERS MERGE ----
    -- シャドウ表はSTAGING_SCHEMA.CUSTOMERSと同一構造（CREATE AS SELECT）
    -- STAGING の列: customer_id, customer_code, company_name, last_name, first_name,
    --               email, phone, region_id, credit_limit, status,
    --               avatar_image, remarks, created_at, updated_at, created_by, synced_at
    MERGE INTO staging_schema.customers tgt
    USING staging_ctl.lob_resync_stage_customers src
    ON (tgt.customer_id = src.customer_id)
    WHEN MATCHED THEN
        UPDATE SET
            tgt.customer_code  = src.customer_code,
            tgt.company_name   = src.company_name,
            tgt.last_name      = src.last_name,
            tgt.first_name     = src.first_name,
            tgt.email          = src.email,
            tgt.phone          = src.phone,
            tgt.region_id      = src.region_id,
            tgt.credit_limit   = src.credit_limit,
            tgt.status         = src.status,
            tgt.avatar_image   = src.avatar_image,
            tgt.remarks        = src.remarks,
            tgt.created_at     = src.created_at,
            tgt.updated_at     = src.updated_at,
            tgt.created_by     = src.created_by
    WHEN NOT MATCHED THEN
        INSERT (customer_id, customer_code, company_name, last_name, first_name,
                email, phone, region_id, credit_limit, status,
                avatar_image, remarks, created_at, updated_at, created_by)
        VALUES (src.customer_id, src.customer_code, src.company_name, src.last_name, src.first_name,
                src.email, src.phone, src.region_id, src.credit_limit, src.status,
                src.avatar_image, src.remarks, src.created_at, src.updated_at, src.created_by);
    v_cust_merge := SQL%ROWCOUNT;

    -- ---- ORDERS MERGE ----
    -- STAGING の列: order_id, order_no, customer_id, shipping_region_id, status,
    --               order_date, ship_date, delivery_date, total_amount, tax_amount,
    --               shipping_address, notes, created_at, updated_at, synced_at
    MERGE INTO staging_schema.orders tgt
    USING staging_ctl.lob_resync_stage_orders src
    ON (tgt.order_id = src.order_id)
    WHEN MATCHED THEN
        UPDATE SET
            tgt.order_no           = src.order_no,
            tgt.customer_id        = src.customer_id,
            tgt.shipping_region_id = src.shipping_region_id,
            tgt.status             = src.status,
            tgt.order_date         = src.order_date,
            tgt.ship_date          = src.ship_date,
            tgt.delivery_date      = src.delivery_date,
            tgt.total_amount       = src.total_amount,
            tgt.tax_amount         = src.tax_amount,
            tgt.shipping_address   = src.shipping_address,
            tgt.notes              = src.notes,
            tgt.created_at         = src.created_at,
            tgt.updated_at         = src.updated_at
    WHEN NOT MATCHED THEN
        INSERT (order_id, order_no, customer_id, shipping_region_id, status,
                order_date, ship_date, delivery_date, total_amount, tax_amount,
                shipping_address, notes, created_at, updated_at)
        VALUES (src.order_id, src.order_no, src.customer_id, src.shipping_region_id, src.status,
                src.order_date, src.ship_date, src.delivery_date, src.total_amount, src.tax_amount,
                src.shipping_address, src.notes, src.created_at, src.updated_at);
    v_ord_merge := SQL%ROWCOUNT;

    -- ---- lob_resync_target を DONE に更新（シャドウ表にデータがあった行のみ）----
    FOR r IN c_merged_customers LOOP
        UPDATE staging_ctl.lob_resync_target
        SET resync_status = 'DONE', resolved_at = SYSTIMESTAMP
        WHERE resync_id = r.resync_id;
        v_done_cnt := v_done_cnt + 1;

        -- 対応する delta_manual_review_queue を RESOLVED に更新
        UPDATE staging_ctl.delta_manual_review_queue
        SET review_status = 'RESOLVED', reviewed_at = SYSTIMESTAMP,
            review_note   = 'LOB再同期完了(lob_resync_merge)'
        WHERE seg_name    = 'CUSTOMERS'
          AND pk_value    = r.pk_value
          AND review_status = 'IN_REVIEW';
        v_resolved_cnt := v_resolved_cnt + SQL%ROWCOUNT;
    END LOOP;

    FOR r IN c_merged_orders LOOP
        UPDATE staging_ctl.lob_resync_target
        SET resync_status = 'DONE', resolved_at = SYSTIMESTAMP
        WHERE resync_id = r.resync_id;
        v_done_cnt := v_done_cnt + 1;

        UPDATE staging_ctl.delta_manual_review_queue
        SET review_status = 'RESOLVED', reviewed_at = SYSTIMESTAMP,
            review_note   = 'LOB再同期完了(lob_resync_merge)'
        WHERE seg_name    = 'ORDERS'
          AND pk_value    = r.pk_value
          AND review_status = 'IN_REVIEW';
        v_resolved_cnt := v_resolved_cnt + SQL%ROWCOUNT;
    END LOOP;

    -- ---- シャドウ表 TRUNCATE（次サイクルに備える）----
    EXECUTE IMMEDIATE 'TRUNCATE TABLE staging_ctl.lob_resync_stage_customers';
    EXECUTE IMMEDIATE 'TRUNCATE TABLE staging_ctl.lob_resync_stage_orders';

    COMMIT;

    DBMS_OUTPUT.PUT_LINE(
        'lob_resync_merge: customers_merged=' || v_cust_merge
        || ' orders_merged=' || v_ord_merge
        || ' targets_done=' || v_done_cnt
        || ' reviews_resolved=' || v_resolved_cnt);

EXCEPTION WHEN OTHERS THEN
    BEGIN ROLLBACK; EXCEPTION WHEN OTHERS THEN NULL; END;
    DBMS_OUTPUT.PUT_LINE('lob_resync_merge FATAL: ' || SUBSTR(SQLERRM, 1, 4000));
    RAISE;
END lob_resync_merge;
/
SHOW ERRORS PROCEDURE SYS.lob_resync_merge;

PROMPT staging_ctl.lob_resync_target / lob_resync_stage_customers / lob_resync_stage_orders created.
PROMPT SYS.lob_resync_build_targets / SYS.lob_resync_merge created on oracle-tgt.
EXIT;
