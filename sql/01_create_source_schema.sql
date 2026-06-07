-- 旧スキーマ（SRC_SCHEMA）テーブル作成
-- レガシー設計を模倣: 日付をVARCHAR2で保持、住所未分割、コードを数値文字列で保持

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT src_schema/&&SRC_SCHEMA_PASS@//&&ORACLE_HOST:&&ORACLE_PORT/&&ORACLE_SERVICE

PROMPT Creating src_schema.customers...
CREATE TABLE customers (
    cust_id     VARCHAR2(10)   NOT NULL,
    cust_name   VARCHAR2(200)  NOT NULL,
    tel         VARCHAR2(20),
    address     VARCHAR2(400),
    create_date VARCHAR2(8),
    CONSTRAINT pk_src_customers PRIMARY KEY (cust_id)
);

PROMPT Creating src_schema.orders...
CREATE TABLE orders (
    order_id    NUMBER(10)    NOT NULL,
    cust_id     VARCHAR2(10)  NOT NULL,
    order_date  VARCHAR2(8),
    amount      NUMBER(12,2),
    status      VARCHAR2(2),
    CONSTRAINT pk_src_orders PRIMARY KEY (order_id),
    CONSTRAINT fk_src_orders_cust FOREIGN KEY (cust_id) REFERENCES customers(cust_id)
);

PROMPT SRC_SCHEMA tables created.
EXIT;
