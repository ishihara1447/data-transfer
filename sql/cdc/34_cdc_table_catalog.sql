-- 差分抽出の追跡対象テーブル・カタログ (oracle-src 用)
-- delta_extract が SEG_NAME を固定せず、本カタログの is_active='Y' のテーブルを抽出対象にする。
-- 設計: docs/phase1-commit-scn-redesign.md（全テーブル化はその拡張）
--   pk_column は delta_queue.pk_value 抽出のヒント（参照用・単一数値PK前提のベストエフォート。
--   delta_apply は SQL_REDO を直接 replay するため pk_value に依存しない）。
-- 実行ユーザー: SYS AS SYSDBA / 実行対象: oracle-src XEPDB1 / Oracle 12c 互換 / 冪等

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_tables
    WHERE owner = 'CDC_SCHEMA' AND table_name = 'CDC_TABLE_CATALOG';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE cdc_schema.cdc_table_catalog PURGE';
    END IF;
END;
/

CREATE TABLE cdc_schema.cdc_table_catalog (
    table_name        VARCHAR2(100) NOT NULL,   -- SRC_SCHEMA 内のテーブル名
    pk_column         VARCHAR2(100),            -- 単一数値PK列（pk_value抽出ヒント・任意）
    is_active         VARCHAR2(1)   DEFAULT 'Y' NOT NULL,
    sort_order        NUMBER(5)     DEFAULT 100 NOT NULL,
    baseline_ddl_time TIMESTAMP,               -- ★DDL凍結基準: snapshot 時の last_ddl_time
    remarks           VARCHAR2(4000),
    CONSTRAINT pk_cdc_table_catalog PRIMARY KEY (table_name),
    CONSTRAINT chk_cdc_catalog_active CHECK (is_active IN ('Y','N'))
);

-- Phase1 スコープの SYSTEM_EVENTS に加え、Phase2 で扱う実テーブルを登録
INSERT INTO cdc_schema.cdc_table_catalog(table_name, pk_column, sort_order, remarks)
VALUES ('SYSTEM_EVENTS', 'EVENT_ID', 100, 'Phase1 貫通テスト用');
INSERT INTO cdc_schema.cdc_table_catalog(table_name, pk_column, sort_order, remarks)
VALUES ('REGIONS', 'REGION_ID', 10, 'PASS_THROUGH 対象');
INSERT INTO cdc_schema.cdc_table_catalog(table_name, pk_column, sort_order, remarks)
VALUES ('CUSTOMERS', 'CUSTOMER_ID', 20, 'LIGHT_TRANSFORM 対象');
INSERT INTO cdc_schema.cdc_table_catalog(table_name, pk_column, sort_order, remarks)
VALUES ('ORDERS', 'ORDER_ID', 30, 'LIGHT_TRANSFORM 対象');
COMMIT;

PROMPT cdc_schema.cdc_table_catalog created and seeded on oracle-src.
EXIT;
