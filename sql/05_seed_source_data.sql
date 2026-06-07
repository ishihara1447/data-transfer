-- サンプルデータ投入 (SRC_SCHEMA)
-- レガシーデータの特性を模倣: 不整合な日付フォーマット、住所未分割、コード値混在

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT src_schema/&&SRC_SCHEMA_PASS@//&&ORACLE_HOST:&&ORACLE_PORT/&&ORACLE_SERVICE

PROMPT Seeding src_schema.customers...
INSERT INTO customers (cust_id, cust_name, tel, address, create_date)
VALUES ('1001', '山田 太郎', '03-1234-5678', '東京都新宿区西新宿1-1-1', '20200101');

INSERT INTO customers (cust_id, cust_name, tel, address, create_date)
VALUES ('1002', '佐藤 花子', '06-9876-5432', '大阪府大阪市中央区難波1-2-3', '20210315');

INSERT INTO customers (cust_id, cust_name, tel, address, create_date)
VALUES ('1003', '鈴木 一郎', '052-111-2222', '愛知県名古屋市中区錦2-3-4', '20190601');

INSERT INTO customers (cust_id, cust_name, tel, address, create_date)
VALUES ('1004', '高橋 美子', NULL, '神奈川県横浜市中区山下町5-6', '20220801');

INSERT INTO customers (cust_id, cust_name, tel, address, create_date)
VALUES ('1005', '田中 健二', '011-333-4444', '北海道札幌市中央区大通西7-8', NULL);

INSERT INTO customers (cust_id, cust_name, tel, address, create_date)
VALUES ('1006', '伊藤 裕子', '092-555-6666', '福岡県福岡市博多区博多駅前1-1', '20230101');

PROMPT Seeding src_schema.orders...
INSERT INTO orders (order_id, cust_id, order_date, amount, status)
VALUES (10001, '1001', '20230401', 15000.00, '30');

INSERT INTO orders (order_id, cust_id, order_date, amount, status)
VALUES (10002, '1001', '20230615', 8500.50, '30');

INSERT INTO orders (order_id, cust_id, order_date, amount, status)
VALUES (10003, '1002', '20230701', 32000.00, '20');

INSERT INTO orders (order_id, cust_id, order_date, amount, status)
VALUES (10004, '1003', '20230801', 5000.00, '10');

INSERT INTO orders (order_id, cust_id, order_date, amount, status)
VALUES (10005, '1004', '20230901', 12500.00, '99');

INSERT INTO orders (order_id, cust_id, order_date, amount, status)
VALUES (10006, '1005', '20231001', 7800.00, '20');

INSERT INTO orders (order_id, cust_id, order_date, amount, status)
VALUES (10007, '1006', '20231101', 25000.00, '10');

COMMIT;

PROMPT Seed data committed. Customers: 6, Orders: 7
EXIT;
