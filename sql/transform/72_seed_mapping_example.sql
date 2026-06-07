-- サンプルマッピング: 既存の手書き変換(regions/customers/orders/order_enriched)を
-- マッピング設定として再現。pkg_codegen の受け入れ試験フィクスチャ。
-- 実運用ではこのファイルを差し替え、利用者が自テーブルの対応関係を投入する。
-- 所有: LOG_SCHEMA / 実行: SYS AS SYSDBA / 対象: oracle-tgt XEPDB1 / 冪等

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

DELETE FROM log_schema.codegen_column_map;
DELETE FROM log_schema.codegen_table_map;

-- ===== テーブル対応 =====
INSERT INTO log_schema.codegen_table_map (tgt_table, src_table, pk_columns, transform_class, join_clause, delete_src_table, sort_order, remarks)
VALUES ('REGIONS','REGIONS','REGION_ID','PASS_THROUGH',NULL,'REGIONS',5,'1:1コピー');
INSERT INTO log_schema.codegen_table_map (tgt_table, src_table, pk_columns, transform_class, join_clause, delete_src_table, sort_order, remarks)
VALUES ('CUSTOMERS','CUSTOMERS','CUSTOMER_ID','LIGHT_TRANSFORM',NULL,'CUSTOMERS',10,'氏名連結・正規化・フラグ・TS→DATE');
INSERT INTO log_schema.codegen_table_map (tgt_table, src_table, pk_columns, transform_class, join_clause, delete_src_table, sort_order, remarks)
VALUES ('ORDERS','ORDERS','ORDER_ID','LIGHT_TRANSFORM',NULL,'ORDERS',20,'status検証・派生列');
INSERT INTO log_schema.codegen_table_map (tgt_table, src_table, pk_columns, transform_class, join_clause, delete_src_table, sort_order, remarks)
VALUES ('ORDER_ENRICHED','ORDERS','ORDER_ID','HEAVY_TRANSFORM',
        'LEFT JOIN STAGING_SCHEMA.customers l_cust ON l_cust.customer_id=s.customer_id LEFT JOIN STAGING_SCHEMA.regions l_reg ON l_reg.region_id=s.shipping_region_id',
        'ORDERS',40,'非正規化JOIN+JSON分解+コードマッピング');

-- ===== 列対応: CUSTOMERS (LIGHT) =====
INSERT INTO log_schema.codegen_column_map VALUES ('CUSTOMERS','CUSTOMER_ID',1,'DIRECT','CUSTOMER_ID','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('CUSTOMERS','CUSTOMER_CODE',2,'DIRECT','CUSTOMER_CODE','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('CUSTOMERS','FULL_NAME',3,'CONCAT','LAST_NAME,FIRST_NAME',' ');
INSERT INTO log_schema.codegen_column_map VALUES ('CUSTOMERS','DISPLAY_NAME',4,'EXPRESSION',NULL,'COALESCE(s.company_name, s.last_name||'' ''||s.first_name)');
INSERT INTO log_schema.codegen_column_map VALUES ('CUSTOMERS','EMAIL',5,'DIRECT','EMAIL','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('CUSTOMERS','PHONE_NORMALIZED',6,'EXPRESSION',NULL,'log_schema.pkg_transform_util.normalize_phone(s.phone)');
INSERT INTO log_schema.codegen_column_map VALUES ('CUSTOMERS','REGION_ID',7,'DIRECT','REGION_ID','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('CUSTOMERS','CREDIT_LIMIT',8,'DIRECT','CREDIT_LIMIT','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('CUSTOMERS','STATUS',9,'DIRECT','STATUS','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('CUSTOMERS','IS_ACTIVE',10,'EXPRESSION',NULL,'log_schema.pkg_transform_util.status_to_active_flag(s.status)');
INSERT INTO log_schema.codegen_column_map VALUES ('CUSTOMERS','CREATED_DATE',11,'DIRECT','CREATED_AT','DATE_FROM_TS');

-- ===== 列対応: ORDERS (LIGHT) =====
INSERT INTO log_schema.codegen_column_map VALUES ('ORDERS','ORDER_ID',1,'DIRECT','ORDER_ID','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDERS','ORDER_NO',2,'DIRECT','ORDER_NO','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDERS','CUSTOMER_ID',3,'DIRECT','CUSTOMER_ID','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDERS','SHIPPING_REGION_ID',4,'DIRECT','SHIPPING_REGION_ID','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDERS','ORDER_STATUS',5,'EXPRESSION',NULL,'log_schema.pkg_transform_util.validate_order_status(s.status)');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDERS','ORDER_DATE',6,'DIRECT','ORDER_DATE','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDERS','SHIP_DATE',7,'DIRECT','SHIP_DATE','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDERS','DELIVERY_DATE',8,'DIRECT','DELIVERY_DATE','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDERS','LEAD_TIME_DAYS',9,'EXPRESSION',NULL,'CASE WHEN s.delivery_date IS NOT NULL THEN TRUNC(s.delivery_date)-TRUNC(s.order_date) END');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDERS','TOTAL_AMOUNT',10,'DIRECT','TOTAL_AMOUNT','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDERS','TAX_AMOUNT',11,'DIRECT','TAX_AMOUNT','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDERS','NET_AMOUNT',12,'EXPRESSION',NULL,'s.total_amount - s.tax_amount');

-- ===== 列対応: ORDER_ENRICHED (HEAVY) =====
INSERT INTO log_schema.codegen_column_map VALUES ('ORDER_ENRICHED','ORDER_ID',1,'DIRECT','ORDER_ID','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDER_ENRICHED','ORDER_NO',2,'DIRECT','ORDER_NO','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDER_ENRICHED','CUSTOMER_ID',3,'DIRECT','CUSTOMER_ID','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDER_ENRICHED','CUSTOMER_NAME',4,'EXPRESSION',NULL,'l_cust.last_name||'' ''||l_cust.first_name');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDER_ENRICHED','SHIPPING_REGION_ID',5,'DIRECT','SHIPPING_REGION_ID','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDER_ENRICHED','REGION_NAME',6,'EXPRESSION',NULL,'l_reg.region_name');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDER_ENRICHED','ORDER_STATUS',7,'DIRECT','STATUS','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDER_ENRICHED','STATUS_LABEL',8,'CODE_MAP','STATUS','ORDER_STATUS');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDER_ENRICHED','POSTAL_CODE',9,'JSON_EXTRACT','SHIPPING_ADDRESS','postal_code');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDER_ENRICHED','PREFECTURE',10,'JSON_EXTRACT','SHIPPING_ADDRESS','prefecture');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDER_ENRICHED','CITY',11,'JSON_EXTRACT','SHIPPING_ADDRESS','city');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDER_ENRICHED','TOTAL_AMOUNT',12,'DIRECT','TOTAL_AMOUNT','NONE');
INSERT INTO log_schema.codegen_column_map VALUES ('ORDER_ENRICHED','NET_AMOUNT',13,'EXPRESSION',NULL,'s.total_amount - s.tax_amount');

COMMIT;
PROMPT サンプルマッピング投入完了（regions/customers/orders/order_enriched）。
EXIT;
