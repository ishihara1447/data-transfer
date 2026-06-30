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
    lob_present       CHAR(1)       DEFAULT 'N' NOT NULL,  -- ★LOB列有無: BLOB/CLOB/NCLOB/LONG等
    replay_category   VARCHAR2(1)   DEFAULT 'B' NOT NULL,  -- ★差分適用分類: A/B/C/D
    remarks           VARCHAR2(4000),
    CONSTRAINT pk_cdc_table_catalog PRIMARY KEY (table_name),
    CONSTRAINT chk_cdc_catalog_active   CHECK (is_active IN ('Y','N')),
    CONSTRAINT chk_cdc_catalog_lob      CHECK (lob_present IN ('Y','N')),
    CONSTRAINT chk_cdc_catalog_category CHECK (replay_category IN ('A','B','C','D'))
);
-- replay_category:
--   A: SQL_REDO直接適用候補 (LOBなし・STAGING同一構造・PK安定・ホワイトリスト登録済み)
--   B: STG変換必要 (列追加/削除/変換あり) ※現行環境では実質未使用(STAGING=SRC構造)
--   C: LOB/複雑型あり (BLOB/CLOB/NCLOB等) → SQL_REDO直接適用禁止
--   D: DDLリスクあり (移行期間中DDL変更の可能性) → DDL凍結または個別再設計

-- 移行対象テーブル（STAGING/TARGET があり変換ルールが定義済みのもの）を登録。
-- ★追跡対象は STAGING_SCHEMA に実在するテーブルと一致させること。STAGING に無い表を
--   is_active='Y' にすると、その変更を delta_apply できず ORA-00942 で Tx 全体が失敗する。
-- SYSTEM_EVENTS は Phase1 貫通テスト専用で STAGING/TARGET に無いため is_active='N'（除外）。
--   Phase1 テスト(scripts/11 等)を回すときだけ一時的に 'Y' へ更新する。
--
-- LOB棚卸し結果（sql/cdc/11_cdc_src_schema.sql 参照）:
--   REGIONS        : LOBなし → lob_present='N', replay_category='A'（直接適用候補）
--   CUSTOMERS      : BLOB(avatar_image) + CLOB(remarks) → lob_present='Y', replay_category='C'
--   ORDERS         : CLOB(shipping_address) → lob_present='Y', replay_category='C'
--   SYSTEM_EVENTS  : CLOB(event_payload)   → lob_present='Y', replay_category='C'
INSERT INTO cdc_schema.cdc_table_catalog
    (table_name, pk_column, is_active, sort_order, lob_present, replay_category, remarks)
VALUES ('SYSTEM_EVENTS', 'EVENT_ID', 'N', 100, 'Y', 'C',
        'Phase1 貫通テスト専用（STAGING/TARGET無し・通常は除外）。CLOB(event_payload)あり。');
INSERT INTO cdc_schema.cdc_table_catalog
    (table_name, pk_column, sort_order, lob_present, replay_category, remarks)
VALUES ('REGIONS', 'REGION_ID', 10, 'N', 'A',
        'PASS_THROUGH対象。LOBなし・STAGING同一構造・PK安定 → SQL_REDO直接適用候補。redo_replay_whitelist登録済み。');
INSERT INTO cdc_schema.cdc_table_catalog
    (table_name, pk_column, sort_order, lob_present, replay_category, remarks)
VALUES ('CUSTOMERS', 'CUSTOMER_ID', 20, 'Y', 'C',
        'LIGHT_TRANSFORM対象。BLOB(avatar_image)+CLOB(remarks)あり → SQL_REDO直接適用禁止。LOBフォールバック必要。');
INSERT INTO cdc_schema.cdc_table_catalog
    (table_name, pk_column, sort_order, lob_present, replay_category, remarks)
VALUES ('ORDERS', 'ORDER_ID', 30, 'Y', 'C',
        'LIGHT_TRANSFORM対象。CLOB(shipping_address)あり → SQL_REDO直接適用禁止。LOBフォールバック必要。');
COMMIT;

PROMPT cdc_schema.cdc_table_catalog created and seeded on oracle-src.
EXIT;
