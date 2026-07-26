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

-- 他スキーマ参照（cdc_schema.* や log_schema.* への JOIN）のために付与
GRANT SELECT ANY TABLE TO migration_ctl;

PROMPT migration_ctl user created on oracle-tgt XEPDB1.
EXIT;
