-- 新スキーマ（TGT_SCHEMA）テーブル作成
-- 型正規化済み: 日付はDATE型、住所は都道府県/市区町村/番地に分割、ステータスは名称文字列

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT tgt_schema/&&TGT_SCHEMA_PASS@//&&ORACLE_HOST:&&ORACLE_PORT/&&ORACLE_SERVICE

PROMPT Creating tgt_schema.customers...
CREATE TABLE customers (
    customer_id    NUMBER(10)    NOT NULL,
    customer_name  VARCHAR2(200) NOT NULL,
    phone          VARCHAR2(20),
    prefecture     VARCHAR2(20),
    city           VARCHAR2(100),
    address_detail VARCHAR2(300),
    created_at     DATE,
    CONSTRAINT pk_tgt_customers PRIMARY KEY (customer_id)
);

PROMPT Creating tgt_schema.orders...
CREATE TABLE orders (
    order_id      NUMBER(10)    NOT NULL,
    customer_id   NUMBER(10)    NOT NULL,
    order_date    DATE,
    total_amount  NUMBER(12,2),
    order_status  VARCHAR2(20),
    CONSTRAINT pk_tgt_orders PRIMARY KEY (order_id),
    CONSTRAINT fk_tgt_orders_cust FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

PROMPT TGT_SCHEMA tables created.
EXIT;
