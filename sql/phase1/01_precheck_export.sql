-- Phase 1: Export 事前確認
-- 実行場所: oracle-src コンテナ内
-- 接続: SYS as SYSDBA @ XEPDB1
-- 実行前提: MIG_FS_DIR DIRECTORY が作成済みであること
-- 本番では別途確認が必要な項目:
--   - UNDO 表領域容量と UNDO_RETENTION
--   - RAC 全 Thread の確認
--   - 5TB/500テーブル 規模での所要時間見積り

SET PAGESIZE 100
SET LINESIZE 200
SET FEEDBACK ON
SET HEADING ON

PROMPT ============================================================
PROMPT Phase 1 Export 事前確認
PROMPT 接続: SYS as SYSDBA @ XEPDB1
PROMPT ============================================================

-- Step 1: /migfs ディレクトリのアクセス確認（DIRECTORY オブジェクト）
PROMPT
PROMPT --- [1] MIG_FS_DIR DIRECTORY 確認 ---
SELECT DIRECTORY_NAME, DIRECTORY_PATH FROM DBA_DIRECTORIES WHERE DIRECTORY_NAME = 'MIG_FS_DIR';

-- Step 2: 対象テーブルの存在確認
PROMPT
PROMPT --- [2] 対象テーブル存在確認 (DBA_TABLES) ---
SELECT TABLE_NAME, NUM_ROWS, LAST_ANALYZED
FROM DBA_TABLES
WHERE OWNER = 'SRC_SCHEMA' AND TABLE_NAME IN ('REGIONS','CUSTOMERS','ORDERS')
ORDER BY TABLE_NAME;

-- Step 3: 対象テーブルの実際の件数
PROMPT
PROMPT --- [3] 対象テーブル実件数 ---
SELECT 'REGIONS' AS TABLE_NAME, COUNT(*) AS CNT FROM SRC_SCHEMA.REGIONS
UNION ALL
SELECT 'CUSTOMERS', COUNT(*) FROM SRC_SCHEMA.CUSTOMERS
UNION ALL
SELECT 'ORDERS', COUNT(*) FROM SRC_SCHEMA.ORDERS;

-- Step 4: SRC_SCHEMA ユーザーの権限確認（ロール）
PROMPT
PROMPT --- [4a] SRC_SCHEMA 付与ロール ---
SELECT GRANTED_ROLE FROM DBA_ROLE_PRIVS WHERE GRANTEE = 'SRC_SCHEMA';

-- Step 4: SRC_SCHEMA ユーザーの権限確認（システム権限）
PROMPT
PROMPT --- [4b] SRC_SCHEMA システム権限 ---
SELECT PRIVILEGE FROM DBA_SYS_PRIVS WHERE GRANTEE = 'SRC_SCHEMA';

-- Step 5: DIRECTORY への権限確認
PROMPT
PROMPT --- [5] MIG_FS_DIR DIRECTORY 権限確認 ---
SELECT TABLE_NAME, PRIVILEGE, GRANTOR FROM ALL_TAB_PRIVS
WHERE GRANTEE = 'SRC_SCHEMA' AND TABLE_NAME = 'MIG_FS_DIR';

PROMPT
PROMPT ============================================================
PROMPT 確認完了
PROMPT 全項目が期待通りの場合は 02_get_baseline_scn.sql を実行してください。
PROMPT ============================================================
