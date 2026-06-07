-- Phase 2 土台（冪等）: STAGING(着地・SRC完全ミラー) / TARGET(変換先) / LOG(制御・ログ)
-- 設計: docs/phase2-transform-design.md（フレームワークを実スキーマに再接地）
--
-- ★前提（2026-06-07 判明）:
--   migration-design.md の単純レガシー例は初期の単独演習用。delta アーキを流れる実データは
--   data-generator 生成の現実的スキーマ（ID数値・氏名分離済・日付DATE・status文字列・LOB付き）。
--   本フェーズは実スキーマを対象とする。
--
-- ★STAGING は SRC を完全ミラー（LOB含む・制約はPKのみの寛容な着地ゾーン）:
--   理由(1) delta_apply は SQL_REDO の "SRC_SCHEMA"→"STAGING_SCHEMA" 置換で適用するため
--           STAGING の列構造が SRC と一致している必要がある。
--   理由(2) G1 初期ロード(Data Pump content=DATA_ONLY)が SRC と同一構造を要求する。
--   LOB列(AVATAR_IMAGE/REMARKS/SHIPPING_ADDRESS)は構造として持つが、変換層はスカラのみ読む
--   （LOB変換は G13 として別途）。
--
-- 変換種別（3分類）:
--   regions  : PASS_THROUGH （1:1 コピー）            sort 5
--   customers: LIGHT_TRANSFORM（氏名連結等）          sort 10
--   orders   : LIGHT_TRANSFORM（status検証・派生列）  sort 20
--
-- 実行ユーザー: SYS AS SYSDBA / 対象: oracle-tgt XEPDB1 / Oracle 12c 互換 / 冪等(再実行可)

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

-- ============================================================
-- ユーザー作成（冪等）
-- ============================================================
DECLARE
    PROCEDURE ensure_user(p_user VARCHAR2, p_pass VARCHAR2) IS
        v_cnt NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_cnt FROM dba_users WHERE username = p_user;
        IF v_cnt = 0 THEN
            EXECUTE IMMEDIATE 'CREATE USER ' || p_user || ' IDENTIFIED BY ' || p_pass;
            EXECUTE IMMEDIATE 'GRANT CONNECT, RESOURCE TO ' || p_user;
            EXECUTE IMMEDIATE 'ALTER USER ' || p_user || ' QUOTA UNLIMITED ON USERS';
        END IF;
    END;
BEGIN
    ensure_user('TARGET_SCHEMA', 'targetschema1');
    ensure_user('LOG_SCHEMA',    'logschema1');
END;
/

-- ============================================================
-- 既存オブジェクトの DROP（冪等。子→親の順）
-- ============================================================
DECLARE
    PROCEDURE drop_tab(p_owner VARCHAR2, p_tab VARCHAR2) IS
        v_cnt NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_cnt FROM dba_tables WHERE owner = p_owner AND table_name = p_tab;
        IF v_cnt > 0 THEN
            EXECUTE IMMEDIATE 'DROP TABLE ' || p_owner || '.' || p_tab || ' CASCADE CONSTRAINTS PURGE';
        END IF;
    END;
    PROCEDURE drop_seq(p_owner VARCHAR2, p_seq VARCHAR2) IS
        v_cnt NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_cnt FROM dba_sequences WHERE sequence_owner = p_owner AND sequence_name = p_seq;
        IF v_cnt > 0 THEN
            EXECUTE IMMEDIATE 'DROP SEQUENCE ' || p_owner || '.' || p_seq;
        END IF;
    END;
BEGIN
    drop_tab('TARGET_SCHEMA',  'ORDER_ENRICHED');
    drop_tab('TARGET_SCHEMA',  'ORDERS');
    drop_tab('TARGET_SCHEMA',  'CUSTOMERS');
    drop_tab('TARGET_SCHEMA',  'REGIONS');
    drop_tab('STAGING_SCHEMA', 'ORDERS');
    drop_tab('STAGING_SCHEMA', 'CUSTOMERS');
    drop_tab('STAGING_SCHEMA', 'REGIONS');
    drop_tab('LOG_SCHEMA',     'CODE_MAPPING');
    drop_tab('LOG_SCHEMA',     'TRANSFORM_CATALOG');
    drop_tab('LOG_SCHEMA',     'MIGRATION_ERROR_LOG');
    drop_tab('LOG_SCHEMA',     'MIGRATION_STEP_LOG');
    drop_tab('LOG_SCHEMA',     'MIGRATION_RUN_LOG');
    drop_tab('LOG_SCHEMA',     'TRANSFORM_STATE');
    drop_seq('LOG_SCHEMA',     'SEQ_RUN_ID');
    drop_seq('LOG_SCHEMA',     'SEQ_STEP_ID');
    drop_seq('LOG_SCHEMA',     'SEQ_ERROR_ID');
    drop_seq('LOG_SCHEMA',     'SEQ_CATALOG_ID');
END;
/

-- ============================================================
-- STAGING_SCHEMA: SRC 完全ミラー（LOB含む・PKのみ）
-- ============================================================
CREATE TABLE staging_schema.regions (
    region_id         NUMBER(6)     NOT NULL,
    region_code       VARCHAR2(10)  NOT NULL,
    region_name       VARCHAR2(100) NOT NULL,
    parent_region_id  NUMBER(6),
    display_order     NUMBER(4),
    is_active         NUMBER(1)     NOT NULL,
    created_at        TIMESTAMP(6)  NOT NULL,
    updated_at        TIMESTAMP(6),
    CONSTRAINT pk_stg_regions PRIMARY KEY (region_id)
);

CREATE TABLE staging_schema.customers (
    customer_id    NUMBER(12)    NOT NULL,
    customer_code  VARCHAR2(20)  NOT NULL,
    company_name   VARCHAR2(300),
    last_name      VARCHAR2(100) NOT NULL,
    first_name     VARCHAR2(100) NOT NULL,
    email          VARCHAR2(255) NOT NULL,
    phone          VARCHAR2(20),
    region_id      NUMBER(6),
    credit_limit   NUMBER(15,2)  DEFAULT 0 NOT NULL,
    status         VARCHAR2(20)  DEFAULT 'ACTIVE' NOT NULL,
    avatar_image   BLOB,
    remarks        CLOB,
    created_at     TIMESTAMP(6)  DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at     TIMESTAMP(6),
    created_by     VARCHAR2(100),
    CONSTRAINT pk_stg_customers PRIMARY KEY (customer_id)
);

CREATE TABLE staging_schema.orders (
    order_id            NUMBER(15)    NOT NULL,
    order_no            VARCHAR2(30)  NOT NULL,
    customer_id         NUMBER(12)    NOT NULL,
    shipping_region_id  NUMBER(6),
    status              VARCHAR2(30)  NOT NULL,
    order_date          DATE          NOT NULL,
    ship_date           DATE,
    delivery_date       DATE,
    total_amount        NUMBER(15,2)  NOT NULL,
    tax_amount          NUMBER(15,2)  NOT NULL,
    shipping_address    CLOB,
    notes               VARCHAR2(2000),
    created_at          TIMESTAMP(6)  DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at          TIMESTAMP(6),
    CONSTRAINT pk_stg_orders PRIMARY KEY (order_id)
);
-- DELTA 増分変換の対象絞り込み用（updated_at 基準）
CREATE INDEX staging_schema.ix_stg_cust_upd ON staging_schema.customers (updated_at);
CREATE INDEX staging_schema.ix_stg_ord_upd  ON staging_schema.orders (updated_at);
CREATE INDEX staging_schema.ix_stg_reg_upd  ON staging_schema.regions (updated_at);

-- ============================================================
-- TARGET_SCHEMA: 変換後スキーマ
--   regions  : PASS_THROUGH（STAGING と同一構造の 1:1 コピー）
--   customers: LIGHT（氏名連結・display_name・電話正規化・is_active・created_date）
--   orders   : LIGHT（status検証・net_amount・lead_time_days）
-- ============================================================
CREATE TABLE target_schema.regions (
    region_id         NUMBER(6)     NOT NULL,
    region_code       VARCHAR2(10)  NOT NULL,
    region_name       VARCHAR2(100) NOT NULL,
    parent_region_id  NUMBER(6),
    display_order     NUMBER(4),
    is_active         NUMBER(1)     NOT NULL,
    created_at        TIMESTAMP(6),
    updated_at        TIMESTAMP(6),
    CONSTRAINT pk_tgt_regions PRIMARY KEY (region_id)
);

CREATE TABLE target_schema.customers (
    customer_id       NUMBER(12)    NOT NULL,
    customer_code     VARCHAR2(20)  NOT NULL,
    full_name         VARCHAR2(201) NOT NULL,
    display_name      VARCHAR2(300) NOT NULL,
    email             VARCHAR2(255) NOT NULL,
    phone_normalized  VARCHAR2(20),
    region_id         NUMBER(6),
    credit_limit      NUMBER(15,2)  NOT NULL,
    status            VARCHAR2(20)  NOT NULL,
    is_active         CHAR(1)       NOT NULL,
    created_date      DATE,
    CONSTRAINT pk_tgt_customers PRIMARY KEY (customer_id),
    CONSTRAINT ck_tgt_cust_active CHECK (is_active IN ('Y','N'))
);

CREATE TABLE target_schema.orders (
    order_id            NUMBER(15)    NOT NULL,
    order_no            VARCHAR2(30)  NOT NULL,
    customer_id         NUMBER(12)    NOT NULL,
    shipping_region_id  NUMBER(6),
    order_status        VARCHAR2(30)  NOT NULL,
    order_date          DATE          NOT NULL,
    ship_date           DATE,
    delivery_date       DATE,
    lead_time_days      NUMBER(6),
    total_amount        NUMBER(15,2)  NOT NULL,
    tax_amount          NUMBER(15,2)  NOT NULL,
    net_amount          NUMBER(15,2)  NOT NULL,
    CONSTRAINT pk_tgt_orders PRIMARY KEY (order_id),
    CONSTRAINT fk_tgt_orders_cust FOREIGN KEY (customer_id)
        REFERENCES target_schema.customers (customer_id)
);

-- ★HEAVY 変換の出力（非正規化レポート表。FKは張らない＝派生レポート用途）
CREATE TABLE target_schema.order_enriched (
    order_id            NUMBER(15)    NOT NULL,
    order_no            VARCHAR2(30),
    customer_id         NUMBER(12),
    customer_name       VARCHAR2(201),   -- customers から非正規化
    shipping_region_id  NUMBER(6),
    region_name         VARCHAR2(100),   -- regions から非正規化
    order_status        VARCHAR2(30),
    status_label        VARCHAR2(200),   -- code_mapping から
    postal_code         VARCHAR2(20),    -- shipping_address(JSON) から
    prefecture          VARCHAR2(200),   -- shipping_address(JSON) から
    city                VARCHAR2(200),   -- shipping_address(JSON) から
    total_amount        NUMBER(15,2),
    net_amount          NUMBER(15,2),
    CONSTRAINT pk_tgt_order_enriched PRIMARY KEY (order_id)
);

-- ============================================================
-- LOG_SCHEMA: 制御・ログ・カタログ・変換進捗
-- ============================================================
CREATE TABLE log_schema.migration_run_log (
    run_id        NUMBER(12)     NOT NULL,
    run_name      VARCHAR2(100)  NOT NULL,
    run_mode      VARCHAR2(10),
    status        VARCHAR2(20)   NOT NULL,
    src_count     NUMBER         DEFAULT 0,
    tgt_count     NUMBER         DEFAULT 0,
    started_at    TIMESTAMP(6)   DEFAULT SYSTIMESTAMP,
    ended_at      TIMESTAMP(6),
    error_message VARCHAR2(4000),
    CONSTRAINT pk_mig_run_log PRIMARY KEY (run_id)
);
CREATE SEQUENCE log_schema.seq_run_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE log_schema.migration_step_log (
    step_id     NUMBER(12)    NOT NULL,
    run_id      NUMBER(12)    NOT NULL,
    step_name   VARCHAR2(100) NOT NULL,
    status      VARCHAR2(20)  NOT NULL,
    src_count   NUMBER        DEFAULT 0,
    tgt_count   NUMBER        DEFAULT 0,
    batch_no    NUMBER        DEFAULT 0,
    logged_at   TIMESTAMP(6)  DEFAULT SYSTIMESTAMP,
    CONSTRAINT pk_mig_step_log PRIMARY KEY (step_id)
);
CREATE SEQUENCE log_schema.seq_step_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE log_schema.migration_error_log (
    error_id      NUMBER(12)    NOT NULL,
    run_id        NUMBER(12),
    step_name     VARCHAR2(100),
    target_table  VARCHAR2(100),
    record_id     VARCHAR2(100),
    batch_no      NUMBER,
    error_code    NUMBER,
    error_message VARCHAR2(4000),
    error_context VARCHAR2(4000),
    backtrace     VARCHAR2(4000),
    logged_at     TIMESTAMP(6)  DEFAULT SYSTIMESTAMP,
    CONSTRAINT pk_mig_error_log PRIMARY KEY (error_id)
);
CREATE SEQUENCE log_schema.seq_error_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- transform_catalog: テーブル3分類メタデータ
CREATE TABLE log_schema.transform_catalog (
    catalog_id       NUMBER(10)     NOT NULL,
    src_table_name   VARCHAR2(100)  NOT NULL,
    tgt_table_name   VARCHAR2(100)  NOT NULL,
    transform_class  VARCHAR2(20)   NOT NULL,
    proc_name        VARCHAR2(200),
    pk_columns       VARCHAR2(400),
    delete_src_table VARCHAR2(100),   -- 削除伝播の検出元 STAGING 表（NULL時は tgt_table_name と同名）
    sort_order       NUMBER(5)      NOT NULL,
    is_active        VARCHAR2(1)    DEFAULT 'Y',
    remarks          VARCHAR2(4000),
    CONSTRAINT pk_transform_catalog PRIMARY KEY (catalog_id),
    -- 1ソース→複数ターゲット（例 ORDERS→orders/order_enriched）を許すため tgt 側で一意
    CONSTRAINT uq_transform_catalog_tgt UNIQUE (tgt_table_name),
    CONSTRAINT chk_transform_class CHECK (transform_class IN ('PASS_THROUGH','LIGHT_TRANSFORM','HEAVY_TRANSFORM')),
    CONSTRAINT chk_transform_active CHECK (is_active IN ('Y','N'))
);
CREATE SEQUENCE log_schema.seq_catalog_id START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- transform_state: DELTA増分変換の再開点（テーブル単位の last_transform_at）
CREATE TABLE log_schema.transform_state (
    tgt_table_name     VARCHAR2(100) NOT NULL,
    last_transform_at  TIMESTAMP(6)  DEFAULT TIMESTAMP '1970-01-01 00:00:00' NOT NULL,
    last_run_id        NUMBER(12),
    updated_at         TIMESTAMP(6)  DEFAULT SYSTIMESTAMP,
    CONSTRAINT pk_transform_state PRIMARY KEY (tgt_table_name)
);

INSERT INTO log_schema.transform_catalog
 (catalog_id, src_table_name, tgt_table_name, transform_class, proc_name, pk_columns, delete_src_table, sort_order, remarks)
VALUES (log_schema.seq_catalog_id.NEXTVAL, 'REGIONS', 'REGIONS', 'PASS_THROUGH',
        NULL, 'REGION_ID', 'REGIONS', 5, '1:1 コピー（汎用 PASS_THROUGH 経路）');
INSERT INTO log_schema.transform_catalog
 (catalog_id, src_table_name, tgt_table_name, transform_class, proc_name, pk_columns, delete_src_table, sort_order, remarks)
VALUES (log_schema.seq_catalog_id.NEXTVAL, 'CUSTOMERS', 'CUSTOMERS', 'LIGHT_TRANSFORM',
        'TRANSFORM_CUSTOMERS', 'CUSTOMER_ID', 'CUSTOMERS', 10, '氏名連結・電話正規化・status→フラグ・TS→DATE');
INSERT INTO log_schema.transform_catalog
 (catalog_id, src_table_name, tgt_table_name, transform_class, proc_name, pk_columns, delete_src_table, sort_order, remarks)
VALUES (log_schema.seq_catalog_id.NEXTVAL, 'ORDERS', 'ORDERS', 'LIGHT_TRANSFORM',
        'TRANSFORM_ORDERS', 'ORDER_ID', 'ORDERS', 20, 'status検証・派生 net_amount / lead_time_days');
-- ★HEAVY: orders+customers+regions の非正規化JOIN + shipping_address(JSON)分解 + status マッピング表
INSERT INTO log_schema.transform_catalog
 (catalog_id, src_table_name, tgt_table_name, transform_class, proc_name, pk_columns, delete_src_table, sort_order, remarks)
VALUES (log_schema.seq_catalog_id.NEXTVAL, 'ORDERS', 'ORDER_ENRICHED', 'HEAVY_TRANSFORM',
        'TRANSFORM_ORDER_ENRICHED', 'ORDER_ID', 'ORDERS', 40,
        'HEAVY: 非正規化JOIN(N→1) + JSON分解(REGEXP) + コードマッピング表');

INSERT INTO log_schema.transform_state(tgt_table_name) VALUES ('REGIONS');
INSERT INTO log_schema.transform_state(tgt_table_name) VALUES ('CUSTOMERS');
INSERT INTO log_schema.transform_state(tgt_table_name) VALUES ('ORDERS');
INSERT INTO log_schema.transform_state(tgt_table_name) VALUES ('ORDER_ENRICHED');

-- ============================================================
-- code_mapping: データ駆動のコード値マッピング（HEAVY パターン例）
-- ============================================================
CREATE TABLE log_schema.code_mapping (
    code_type  VARCHAR2(50)  NOT NULL,
    src_code   VARCHAR2(100) NOT NULL,
    tgt_value  VARCHAR2(200) NOT NULL,
    CONSTRAINT pk_code_mapping PRIMARY KEY (code_type, src_code)
);
INSERT INTO log_schema.code_mapping VALUES ('ORDER_STATUS','DRAFT','Draft');
INSERT INTO log_schema.code_mapping VALUES ('ORDER_STATUS','CONFIRMED','Confirmed');
INSERT INTO log_schema.code_mapping VALUES ('ORDER_STATUS','SHIPPED','Shipped');
INSERT INTO log_schema.code_mapping VALUES ('ORDER_STATUS','DELIVERED','Delivered');
INSERT INTO log_schema.code_mapping VALUES ('ORDER_STATUS','PENDING','Pending');
INSERT INTO log_schema.code_mapping VALUES ('ORDER_STATUS','CANCELLED','Cancelled');
INSERT INTO log_schema.code_mapping VALUES ('ORDER_STATUS','RETURNED','Returned');
COMMIT;

-- ============================================================
-- 権限付与: LOG_SCHEMA が STAGING を読み TARGET を書く
-- ============================================================
GRANT SELECT ON staging_schema.regions   TO log_schema;
GRANT SELECT ON staging_schema.customers TO log_schema;
GRANT SELECT ON staging_schema.orders    TO log_schema;
GRANT SELECT, INSERT, UPDATE, DELETE ON target_schema.regions        TO log_schema;
GRANT SELECT, INSERT, UPDATE, DELETE ON target_schema.customers      TO log_schema;
GRANT SELECT, INSERT, UPDATE, DELETE ON target_schema.orders         TO log_schema;
GRANT SELECT, INSERT, UPDATE, DELETE ON target_schema.order_enriched TO log_schema;
-- 汎用 PASS_THROUGH が列名をメタデータ参照するため
GRANT SELECT ON dba_tab_columns TO log_schema;

PROMPT Phase2 setup (idempotent: STAGING mirror + regions, TARGET + regions, LOG, catalog) created.
EXIT;
