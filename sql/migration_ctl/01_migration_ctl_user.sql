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
-- CREATE VIEW は RESOURCE ロールに含まれないため個別に付与する。
-- これがないと 08_views_phase3.sql の V_ARCHIVE_LOG_GAP 作成が
-- ORA-01031 (insufficient privileges) で失敗する（フレッシュ構築時に必ず発生）。
GRANT CREATE VIEW TO migration_ctl;
ALTER USER migration_ctl QUOTA UNLIMITED ON USERS;

-- 新設計では移行元(DB1.0)側に管理スキーマを持たない。DB1.0 は Data Pump ダンプと
-- Archived Redo を Migration ファイルサーバへ出力するのみで、移行元側 cdc_schema に
-- 相当する構成品は存在しない（設計メモ「概要説明文書」§4・§6）。
-- 1.0スキーマ・2.0スキーマ・移行管理スキーマはいずれも DB2.0 の同一 PDB 内に置くため、
-- DB Link は使用せず通常の SQL で相互参照する（同メモ §9）。
-- したがって migration_ctl に移行元スキーマへの参照権限は付与しない。

PROMPT migration_ctl user created on oracle-tgt XEPDB1.
EXIT;
