-- Phase 1: expdp 監視
-- 実行場所: oracle-src コンテナ内
-- 接続: SYS as SYSDBA @ XEPDB1
-- 用途: expdp 実行中にリアルタイムで進捗を確認する

SET PAGESIZE 100
SET LINESIZE 250
SET FEEDBACK ON
SET HEADING ON

PROMPT ============================================================
PROMPT Phase 1 expdp 実行監視
PROMPT 接続: SYS as SYSDBA @ XEPDB1
PROMPT ============================================================

-- 実行中ジョブ一覧
PROMPT
PROMPT --- [1] 実行中 Data Pump ジョブ一覧 ---
SELECT JOB_NAME, OPERATION, JOB_MODE, STATE, DEGREE, ATTACHED_SESSIONS
FROM DBA_DATAPUMP_JOBS
WHERE STATE != 'NOT RUNNING'
ORDER BY JOB_NAME;

-- ジョブ詳細（進捗）
PROMPT
PROMPT --- [2] ジョブ進捗詳細 ---
SELECT
    j.JOB_NAME,
    s.OPNAME,
    s.SOFAR,
    s.TOTALWORK,
    ROUND(s.SOFAR/NULLIF(s.TOTALWORK,0)*100, 1) AS PCT_COMPLETE,
    s.TIME_REMAINING,
    s.ELAPSED_SECONDS
FROM DBA_DATAPUMP_JOBS j
JOIN V$SESSION_LONGOPS s ON s.OPNAME LIKE '%' || j.JOB_NAME || '%'
WHERE j.STATE != 'NOT RUNNING';

-- エラーログの確認
PROMPT
PROMPT --- [3] Data Pump エラーログ確認 ---
SELECT JOB_NAME, ERROR_CODE, ERROR_DESCRIPTION, TIMESTAMP
FROM DBA_DATAPUMP_ERRORS
ORDER BY TIMESTAMP DESC;

PROMPT
PROMPT ============================================================
PROMPT 監視完了。STATE='NOT RUNNING' のジョブは完了または未実行です。
PROMPT ============================================================
