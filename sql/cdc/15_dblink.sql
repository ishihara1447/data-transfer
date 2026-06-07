-- CDC 検証フェーズ: oracle-tgt への DB リンク作成 (oracle-src 用)
-- CDC プロセス (PKG_CDC_SNAPSHOT / PKG_CDC_LOGMINER) が
-- oracle-tgt の tgt_schema に対して DML を発行するために使用する
-- 実行ユーザー: SYS AS SYSDBA
-- 実行対象: oracle-src XEPDB1 (localhost:1521/XEPDB1)

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

-- ============================================================
-- SYS スキーマに PUBLIC DB リンクを作成
-- tgt_admin: oracle-tgt の tgt_schema ユーザー (接続用)
-- oracle-tgt: Docker ネットワーク内のコンテナ名 (DNS 解決可能)
-- ============================================================

-- 既存リンクがある場合は削除してから再作成 (冪等対応)
BEGIN
    EXECUTE IMMEDIATE 'DROP PUBLIC DATABASE LINK tgt_db';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -2024 THEN RAISE; END IF;
END;
/

CREATE PUBLIC DATABASE LINK tgt_db
    CONNECT TO tgt_schema IDENTIFIED BY &&TGT_SCHEMA_PASS
    USING '(DESCRIPTION=
              (ADDRESS=(PROTOCOL=TCP)(HOST=oracle-tgt)(PORT=1521))
              (CONNECT_DATA=(SERVICE_NAME=XEPDB1)))';

-- ============================================================
-- 接続確認
-- ============================================================
SELECT 1 AS link_ok FROM DUAL@tgt_db;

PROMPT DB link tgt_db created and verified.
EXIT;
