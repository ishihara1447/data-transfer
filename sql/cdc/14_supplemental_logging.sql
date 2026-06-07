-- CDC 検証フェーズ: ARCHIVELOG モード有効化 + Supplemental Logging 設定 (oracle-src 用)
-- CDB$ROOT レベルで設定する必要がある (SYS AS SYSDBA 権限必要)
-- Phase A (スナップショット) 実行前に必ず実行すること
-- 実行方法: docker exec oracle-src 経由で OS 認証 (/ AS SYSDBA) で実行
--
-- 注意: ARCHIVELOG 有効化は DB の SHUTDOWN → MOUNT → OPEN を伴う。
--       OS 認証 (CONNECT / AS SYSDBA) を使用することで SHUTDOWN 後も
--       同一 SQL*Plus セッションから STARTUP MOUNT が可能。

WHENEVER OSERROR EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

-- OS 認証で SYS 接続 (BEQUEATH プロトコル: TCP 不要, SHUTDOWN 後も継続可能)
CONNECT / AS SYSDBA

-- ============================================================
-- Step 1: 現在の LOG_MODE 確認
-- ============================================================
SELECT LOG_MODE,
       SUPPLEMENTAL_LOG_DATA_MIN AS S_MIN,
       SUPPLEMENTAL_LOG_DATA_ALL AS S_ALL
FROM V$DATABASE;

-- ============================================================
-- Step 2: ARCHIVELOG モード有効化
-- 既に ARCHIVELOG の場合は SHUTDOWN/STARTUP を行わない
-- NOARCHIVELOG の場合のみ実施
-- ============================================================

DECLARE
    v_mode VARCHAR2(12);
BEGIN
    SELECT LOG_MODE INTO v_mode FROM V$DATABASE;
    IF v_mode = 'NOARCHIVELOG' THEN
        DBMS_OUTPUT.PUT_LINE('LOG_MODE is NOARCHIVELOG. Will switch via SHUTDOWN/STARTUP MOUNT.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('LOG_MODE is already ' || v_mode || '. Skipping SHUTDOWN/STARTUP.');
    END IF;
END;
/

-- ARCHIVELOG 切り替えが必要な場合のみ以下を実行
-- WHENEVER SQLERROR CONTINUE で "already ARCHIVELOG" エラーを無視

WHENEVER SQLERROR CONTINUE

-- 現在 NOARCHIVELOG の場合: SHUTDOWN IMMEDIATE → STARTUP MOUNT → ARCHIVELOG → OPEN
-- SQL*Plus の SHUTDOWN/STARTUP はネットワーク接続不要 (OS 認証セッションで継続)
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;

WHENEVER SQLERROR EXIT SQL.SQLCODE

-- ============================================================
-- Step 3: Supplemental Logging 有効化
-- ALL COLUMNS: 変更前後の全カラム値を redo log に記録する
-- BLOB / CLOB は out-of-line 格納のため SQL_REDO に含まれない場合がある
-- → PKG_CDC_LOGMINER で FLASHBACK QUERY フォールバックを使用して対応
-- ============================================================

ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- ============================================================
-- 設定確認
-- ============================================================
SELECT
    LOG_MODE,
    SUPPLEMENTAL_LOG_DATA_MIN AS SUPLOG_MIN,
    SUPPLEMENTAL_LOG_DATA_ALL AS SUPLOG_ALL
FROM V$DATABASE;

PROMPT ARCHIVELOG and Supplemental Logging setup completed.
EXIT;
