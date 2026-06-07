-- CDC 検証フェーズ: TGT_SCHEMA DDL (oracle-tgt 用)
-- SRC_SCHEMA と同一構造。CDC で変更を受け取る対象スキーマ。
-- Supplemental Logging 設定は oracle-tgt 側には不要。
-- Oracle 12c 互換: IDENTITY 列不使用, SEQUENCE + TRIGGER で自動採番
-- 実行ユーザー: SYS AS SYSDBA
-- 実行対象: oracle-tgt (localhost:1522/XEPDB1)

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

-- ============================================================
-- シーケンス
-- ============================================================

CREATE SEQUENCE tgt_schema.seq_regions
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE SEQUENCE tgt_schema.seq_product_categories
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE SEQUENCE tgt_schema.seq_customers
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE SEQUENCE tgt_schema.seq_products
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE SEQUENCE tgt_schema.seq_orders
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE SEQUENCE tgt_schema.seq_order_items
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE SEQUENCE tgt_schema.seq_customer_contracts
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE SEQUENCE tgt_schema.seq_order_status_history
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE SEQUENCE tgt_schema.seq_price_history
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE SEQUENCE tgt_schema.seq_system_events
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- ============================================================
-- テーブル定義 (SRC_SCHEMA と同一構造)
-- ============================================================

CREATE TABLE tgt_schema.regions (
    region_id        NUMBER(6)     NOT NULL,
    region_code      VARCHAR2(10)  NOT NULL,
    region_name      VARCHAR2(100) NOT NULL,
    parent_region_id NUMBER(6),
    display_order    NUMBER(4)     DEFAULT 0,
    is_active        NUMBER(1)     DEFAULT 1 NOT NULL,
    created_at       TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at       TIMESTAMP,
    CONSTRAINT pk_tgt_regions        PRIMARY KEY (region_id),
    CONSTRAINT uq_tgt_regions_code   UNIQUE (region_code),
    CONSTRAINT fk_tgt_regions_parent FOREIGN KEY (parent_region_id)
                                     REFERENCES tgt_schema.regions(region_id),
    CONSTRAINT ck_tgt_regions_active CHECK (is_active IN (0, 1))
);

CREATE TABLE tgt_schema.product_categories (
    category_id        NUMBER(10)    NOT NULL,
    category_code      VARCHAR2(20)  NOT NULL,
    category_name      VARCHAR2(200) NOT NULL,
    parent_category_id NUMBER(10),
    depth_level        NUMBER(3)     DEFAULT 1 NOT NULL,
    display_order      NUMBER(4)     DEFAULT 0,
    is_active          NUMBER(1)     DEFAULT 1 NOT NULL,
    icon_image         BLOB,
    description        CLOB,
    created_at         TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at         TIMESTAMP,
    CONSTRAINT pk_tgt_product_categories      PRIMARY KEY (category_id),
    CONSTRAINT uq_tgt_product_categories_code UNIQUE (category_code),
    CONSTRAINT fk_tgt_product_categories_prnt FOREIGN KEY (parent_category_id)
                                              REFERENCES tgt_schema.product_categories(category_id),
    CONSTRAINT ck_tgt_prod_cat_active         CHECK (is_active IN (0, 1)),
    CONSTRAINT ck_tgt_prod_cat_depth          CHECK (depth_level BETWEEN 1 AND 10)
);

CREATE TABLE tgt_schema.customers (
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
    created_at     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at     TIMESTAMP,
    created_by     VARCHAR2(100),
    CONSTRAINT pk_tgt_customers        PRIMARY KEY (customer_id),
    CONSTRAINT uq_tgt_customers_code   UNIQUE (customer_code),
    CONSTRAINT uq_tgt_customers_email  UNIQUE (email),
    CONSTRAINT fk_tgt_customers_rgn    FOREIGN KEY (region_id)
                                       REFERENCES tgt_schema.regions(region_id),
    CONSTRAINT ck_tgt_customers_status CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
    CONSTRAINT ck_tgt_customers_credit CHECK (credit_limit >= 0)
);

CREATE TABLE tgt_schema.products (
    product_id      NUMBER(12)    NOT NULL,
    product_code    VARCHAR2(50)  NOT NULL,
    product_name    VARCHAR2(500) NOT NULL,
    category_id     NUMBER(10),
    unit_price      NUMBER(12,2)  NOT NULL,
    stock_quantity  NUMBER(10)    DEFAULT 0 NOT NULL,
    weight_kg       NUMBER(8,3),
    is_discontinued NUMBER(1)     DEFAULT 0 NOT NULL,
    thumbnail       BLOB,
    description     CLOB,
    spec_json       CLOB,
    created_at      TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at      TIMESTAMP,
    CONSTRAINT pk_tgt_products        PRIMARY KEY (product_id),
    CONSTRAINT uq_tgt_products_code   UNIQUE (product_code),
    CONSTRAINT fk_tgt_products_cat    FOREIGN KEY (category_id)
                                      REFERENCES tgt_schema.product_categories(category_id),
    CONSTRAINT ck_tgt_products_price  CHECK (unit_price > 0),
    CONSTRAINT ck_tgt_products_stock  CHECK (stock_quantity >= 0),
    CONSTRAINT ck_tgt_products_discon CHECK (is_discontinued IN (0, 1))
);

CREATE TABLE tgt_schema.orders (
    order_id           NUMBER(15)    NOT NULL,
    order_no           VARCHAR2(30)  NOT NULL,
    customer_id        NUMBER(12)    NOT NULL,
    shipping_region_id NUMBER(6),
    status             VARCHAR2(30)  DEFAULT 'DRAFT' NOT NULL,
    order_date         DATE          NOT NULL,
    ship_date          DATE,
    delivery_date      DATE,
    total_amount       NUMBER(15,2)  DEFAULT 0 NOT NULL,
    tax_amount         NUMBER(15,2)  DEFAULT 0 NOT NULL,
    shipping_address   CLOB,
    notes              VARCHAR2(2000),
    created_at         TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at         TIMESTAMP,
    CONSTRAINT pk_tgt_orders        PRIMARY KEY (order_id),
    CONSTRAINT uq_tgt_orders_no     UNIQUE (order_no),
    CONSTRAINT fk_tgt_orders_cust   FOREIGN KEY (customer_id)
                                    REFERENCES tgt_schema.customers(customer_id),
    CONSTRAINT fk_tgt_orders_rgn    FOREIGN KEY (shipping_region_id)
                                    REFERENCES tgt_schema.regions(region_id),
    CONSTRAINT ck_tgt_orders_status CHECK (status IN
                                    ('DRAFT','CONFIRMED','SHIPPED','DELIVERED','CANCELLED')),
    CONSTRAINT ck_tgt_orders_amounts CHECK (total_amount >= 0 AND tax_amount >= 0)
);

CREATE TABLE tgt_schema.order_items (
    item_id       NUMBER(15)   NOT NULL,
    order_id      NUMBER(15)   NOT NULL,
    product_id    NUMBER(12)   NOT NULL,
    line_no       NUMBER(4)    NOT NULL,
    quantity      NUMBER(10)   NOT NULL,
    unit_price    NUMBER(12,2) NOT NULL,
    discount_rate NUMBER(5,4)  DEFAULT 0 NOT NULL,
    line_amount   NUMBER(15,2) NOT NULL,
    notes         VARCHAR2(1000),
    created_at    TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_tgt_order_items      PRIMARY KEY (item_id),
    CONSTRAINT uq_tgt_order_items_line UNIQUE (order_id, line_no),
    CONSTRAINT fk_tgt_order_items_ord  FOREIGN KEY (order_id)
                                       REFERENCES tgt_schema.orders(order_id),
    CONSTRAINT fk_tgt_order_items_prd  FOREIGN KEY (product_id)
                                       REFERENCES tgt_schema.products(product_id),
    CONSTRAINT ck_tgt_order_items_qty  CHECK (quantity > 0),
    CONSTRAINT ck_tgt_order_items_disc CHECK (discount_rate BETWEEN 0 AND 1)
);

CREATE TABLE tgt_schema.customer_contracts (
    contract_id    NUMBER(15)   NOT NULL,
    customer_id    NUMBER(12)   NOT NULL,
    contract_type  VARCHAR2(50) NOT NULL,
    contract_no    VARCHAR2(50) NOT NULL,
    start_date     DATE         NOT NULL,
    end_date       DATE,
    status         VARCHAR2(20) DEFAULT 'ACTIVE' NOT NULL,
    contract_text  CLOB,
    contract_pdf   BLOB,
    signed_image   BLOB,
    created_at     TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at     TIMESTAMP,
    created_by     VARCHAR2(100),
    CONSTRAINT pk_tgt_customer_contracts      PRIMARY KEY (contract_id),
    CONSTRAINT uq_tgt_customer_contracts_no   UNIQUE (contract_no),
    CONSTRAINT fk_tgt_customer_contracts_cust FOREIGN KEY (customer_id)
                                              REFERENCES tgt_schema.customers(customer_id),
    CONSTRAINT ck_tgt_contracts_status        CHECK (status IN ('ACTIVE','EXPIRED','TERMINATED')),
    CONSTRAINT ck_tgt_contracts_dates         CHECK (end_date IS NULL OR end_date > start_date)
);

-- RANGE PARTITION (月次) - ORDER_STATUS_HISTORY
CREATE TABLE tgt_schema.order_status_history (
    history_id    NUMBER(15)   NOT NULL,
    order_id      NUMBER(15)   NOT NULL,
    from_status   VARCHAR2(30),
    to_status     VARCHAR2(30) NOT NULL,
    changed_by    VARCHAR2(100),
    change_reason VARCHAR2(2000),
    created_at    TIMESTAMP    NOT NULL,
    CONSTRAINT pk_tgt_order_status_history     PRIMARY KEY (history_id, created_at),
    CONSTRAINT fk_tgt_order_status_history_ord FOREIGN KEY (order_id)
                                               REFERENCES tgt_schema.orders(order_id)
)
PARTITION BY RANGE (created_at)
INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
(
    PARTITION p_initial VALUES LESS THAN (TIMESTAMP '2026-01-01 00:00:00')
);

CREATE TABLE tgt_schema.price_history (
    history_id     NUMBER(15)   NOT NULL,
    product_id     NUMBER(12)   NOT NULL,
    old_price      NUMBER(12,2),
    new_price      NUMBER(12,2) NOT NULL,
    changed_by     VARCHAR2(100),
    effective_date DATE         NOT NULL,
    reason         VARCHAR2(500),
    created_at     TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_tgt_price_history     PRIMARY KEY (history_id),
    CONSTRAINT fk_tgt_price_history_prd FOREIGN KEY (product_id)
                                        REFERENCES tgt_schema.products(product_id),
    CONSTRAINT ck_tgt_price_history_new CHECK (new_price > 0)
);

CREATE TABLE tgt_schema.system_events (
    event_id       NUMBER(18)    NOT NULL,
    event_type     VARCHAR2(100) NOT NULL,
    source_system  VARCHAR2(100),
    severity       VARCHAR2(10)  DEFAULT 'INFO' NOT NULL,
    message        VARCHAR2(4000),
    event_payload  CLOB,
    created_at     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_tgt_system_events     PRIMARY KEY (event_id),
    CONSTRAINT ck_tgt_system_events_sev CHECK (severity IN ('DEBUG','INFO','WARN','ERROR','FATAL'))
);

-- ============================================================
-- BEFORE INSERT トリガー (SEQUENCE を使った自動採番)
-- CDCプロセスが明示的にIDを指定してINSERTするため、
-- NULL の場合のみシーケンスを使用する
-- ============================================================

CREATE OR REPLACE TRIGGER tgt_schema.trg_regions_bi
BEFORE INSERT ON tgt_schema.regions
FOR EACH ROW
BEGIN
    IF :NEW.region_id IS NULL THEN
        SELECT tgt_schema.seq_regions.NEXTVAL INTO :NEW.region_id FROM DUAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER tgt_schema.trg_product_categories_bi
BEFORE INSERT ON tgt_schema.product_categories
FOR EACH ROW
BEGIN
    IF :NEW.category_id IS NULL THEN
        SELECT tgt_schema.seq_product_categories.NEXTVAL INTO :NEW.category_id FROM DUAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER tgt_schema.trg_customers_bi
BEFORE INSERT ON tgt_schema.customers
FOR EACH ROW
BEGIN
    IF :NEW.customer_id IS NULL THEN
        SELECT tgt_schema.seq_customers.NEXTVAL INTO :NEW.customer_id FROM DUAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER tgt_schema.trg_products_bi
BEFORE INSERT ON tgt_schema.products
FOR EACH ROW
BEGIN
    IF :NEW.product_id IS NULL THEN
        SELECT tgt_schema.seq_products.NEXTVAL INTO :NEW.product_id FROM DUAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER tgt_schema.trg_orders_bi
BEFORE INSERT ON tgt_schema.orders
FOR EACH ROW
BEGIN
    IF :NEW.order_id IS NULL THEN
        SELECT tgt_schema.seq_orders.NEXTVAL INTO :NEW.order_id FROM DUAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER tgt_schema.trg_order_items_bi
BEFORE INSERT ON tgt_schema.order_items
FOR EACH ROW
BEGIN
    IF :NEW.item_id IS NULL THEN
        SELECT tgt_schema.seq_order_items.NEXTVAL INTO :NEW.item_id FROM DUAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER tgt_schema.trg_customer_contracts_bi
BEFORE INSERT ON tgt_schema.customer_contracts
FOR EACH ROW
BEGIN
    IF :NEW.contract_id IS NULL THEN
        SELECT tgt_schema.seq_customer_contracts.NEXTVAL INTO :NEW.contract_id FROM DUAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER tgt_schema.trg_order_status_history_bi
BEFORE INSERT ON tgt_schema.order_status_history
FOR EACH ROW
BEGIN
    IF :NEW.history_id IS NULL THEN
        SELECT tgt_schema.seq_order_status_history.NEXTVAL INTO :NEW.history_id FROM DUAL;
    END IF;
    IF :NEW.created_at IS NULL THEN
        :NEW.created_at := SYSTIMESTAMP;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER tgt_schema.trg_price_history_bi
BEFORE INSERT ON tgt_schema.price_history
FOR EACH ROW
BEGIN
    IF :NEW.history_id IS NULL THEN
        SELECT tgt_schema.seq_price_history.NEXTVAL INTO :NEW.history_id FROM DUAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER tgt_schema.trg_system_events_bi
BEFORE INSERT ON tgt_schema.system_events
FOR EACH ROW
BEGIN
    IF :NEW.event_id IS NULL THEN
        SELECT tgt_schema.seq_system_events.NEXTVAL INTO :NEW.event_id FROM DUAL;
    END IF;
END;
/

-- ============================================================
-- exec_dml: CDC プロセスが DB リンク越しに呼び出す汎用 DML ヘルパー
-- p_sql: tgt_schema に対して実行する DML 文（SRC_SCHEMA → TGT_SCHEMA 置換済み）
-- 注意: 検証環境専用。本番環境では任意 SQL 実行可能なプロシージャは使用しないこと
-- ============================================================
CREATE OR REPLACE PROCEDURE tgt_schema.exec_dml(p_sql IN VARCHAR2) AS
BEGIN
    EXECUTE IMMEDIATE p_sql;
END exec_dml;
/

-- ============================================================
-- update_clob_col: CLOB カラムの LOB フォールバック更新ヘルパー
-- oracle-src の handle_lob_fallback から DB リンク経由で呼び出す
-- Oracle DB リンクでは LOB パラメータ渡し不可のため VARCHAR2 (最大 32767 文字) で受け取る
-- ============================================================
CREATE OR REPLACE PROCEDURE tgt_schema.update_clob_col(
    p_table_name IN VARCHAR2,
    p_pk_col     IN VARCHAR2,
    p_pk_val     IN NUMBER,
    p_col_name   IN VARCHAR2,
    p_data       IN VARCHAR2
) AS
BEGIN
    EXECUTE IMMEDIATE
        'UPDATE tgt_schema.' || p_table_name ||
        ' SET '  || p_col_name || ' = :1' ||
        ' WHERE ' || p_pk_col  || ' = :2'
    USING p_data, p_pk_val;
END update_clob_col;
/

-- ============================================================
-- update_blob_col: BLOB カラムの LOB フォールバック更新ヘルパー
-- p_data: RAW で渡す（最大 32767 バイト。超過分は oracle-src 側でログのみ）
-- ============================================================
CREATE OR REPLACE PROCEDURE tgt_schema.update_blob_col(
    p_table_name IN VARCHAR2,
    p_pk_col     IN VARCHAR2,
    p_pk_val     IN NUMBER,
    p_col_name   IN VARCHAR2,
    p_data       IN RAW
) AS
BEGIN
    EXECUTE IMMEDIATE
        'UPDATE tgt_schema.' || p_table_name ||
        ' SET '  || p_col_name || ' = :1' ||
        ' WHERE ' || p_pk_col  || ' = :2'
    USING p_data, p_pk_val;
END update_blob_col;
/

SHOW ERRORS PROCEDURE tgt_schema.exec_dml;
SHOW ERRORS PROCEDURE tgt_schema.update_clob_col;
SHOW ERRORS PROCEDURE tgt_schema.update_blob_col;

PROMPT TGT_SCHEMA DDL completed: 10 tables, 10 sequences, 10 triggers, 3 helper procedures.
EXIT;
