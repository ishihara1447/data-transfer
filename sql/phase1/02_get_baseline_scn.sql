-- Phase 1: 基準SCN取得
-- 実行場所: oracle-src コンテナ内
-- 接続: SYS as SYSDBA @ XEPDB1
-- 本番では別途確認が必要な項目:
--   - 長時間未コミットトランザクションの個別調査
--   - MINING_START_SCN の決定（基準SCN以前の適切な値）

SET PAGESIZE 100
SET LINESIZE 250
SET FEEDBACK ON
SET HEADING ON

PROMPT ============================================================
PROMPT Phase 1 基準SCN取得
PROMPT 接続: SYS as SYSDBA @ XEPDB1
PROMPT ============================================================

-- Step 1: 長時間・未コミットトランザクションの確認
-- （基準SCNを跨ぐ可能性があるトランザクションを把握する）
PROMPT
PROMPT --- [Step 1] 長時間・未コミットトランザクション確認 (10分以上) ---
SELECT
    t.ADDR,
    t.XIDUSN, t.XIDSLOT, t.XIDSQN,
    s.SID, s.SERIAL#, s.USERNAME, s.STATUS,
    s.LOGON_TIME,
    ROUND((SYSDATE - s.LOGON_TIME) * 24 * 60, 1) AS LOGON_MINUTES,
    t.START_SCN,
    t.USED_UBLK * 8192 AS UNDO_BYTES_USED
FROM V$TRANSACTION t
JOIN V$SESSION s ON t.SES_ADDR = s.SADDR
WHERE ROUND((SYSDATE - s.LOGON_TIME) * 24 * 60, 1) > 10
ORDER BY t.START_SCN;

-- Step 2: 現在の SCN を取得
-- （このSQLの実行後の値を BASELINE_SCN として使用する）
PROMPT
PROMPT --- [Step 2] 現在の SCN 取得 ---
SELECT
    CURRENT_SCN,
    TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS') AS CAPTURED_AT,
    DBID,
    RESETLOGS_ID
FROM V$DATABASE;

-- Step 3: このSCNを外部記録票へ記録すること（二重記録）
PROMPT
PROMPT --- [Step 3] 外部記録（手順）---
PROMPT 記録先: out/scn_record_YYYYMMDD.txt
PROMPT 記録項目: CURRENT_SCN, CAPTURED_AT, DBID, RESETLOGS_ID, 取得者
PROMPT 63_run_expdp.sh が自動で out/scn_record_*.txt を生成します。

PROMPT
PROMPT ============================================================
PROMPT 確認完了
PROMPT 上記 CURRENT_SCN を BASELINE_SCN として使用します。
PROMPT 次のステップ: PKG_MIG_ADMIN.FIX_BASELINE_SCN を実行してください。
PROMPT ============================================================
