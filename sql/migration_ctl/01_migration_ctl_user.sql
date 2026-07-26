-- migration_ctl ユーザー作成スクリプト
-- 実行ユーザー: SYS AS SYSDBA
-- 実行対象: oracle-tgt (localhost:1522/XEPDB1)

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

-- migration_ctl: 統合移行管理スキーマ
CREATE USER migration_ctl IDENTIFIED BY &&MIGRATION_CTL_PASS;
GRANT CONNECT, RESOURCE TO migration_ctl;
ALTER USER migration_ctl QUOTA UNLIMITED ON USERS;

-- cdc_schema.cdc_table_catalog への参照権限（最小権限）
-- cdc_schema が oracle-tgt に構築された後、以下を手動で実行すること:
--   GRANT SELECT ON cdc_schema.cdc_table_catalog TO migration_ctl;
-- ※ cdc_schema が存在しない環境では不要（T05 は all_tables で存在確認後に分岐）

PROMPT migration_ctl user created on oracle-tgt XEPDB1.
EXIT;
