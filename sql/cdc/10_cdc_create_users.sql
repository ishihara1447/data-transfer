-- CDC 検証フェーズ用ユーザー作成
-- oracle-src: src_schema / cdc_schema / log_schema
-- oracle-tgt: tgt_schema
-- Oracle 12c 互換: CREATE USER / GRANT のみ使用
-- 実行ユーザー: SYS AS SYSDBA（CDB$ROOT ではなく PDB 上で実行）

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

-- src_schema: 移行元テーブル群 (oracle-src でのみ作成)
CREATE USER src_schema IDENTIFIED BY &&SRC_SCHEMA_PASS;
GRANT CONNECT, RESOURCE, CREATE VIEW TO src_schema;
GRANT CREATE DATABASE LINK TO src_schema;
-- LogMiner で redo log を参照するために必要な権限
GRANT SELECT ANY TRANSACTION TO src_schema;
GRANT LOGMINING TO src_schema;
GRANT SELECT ON V_$LOGMNR_CONTENTS TO src_schema;
GRANT SELECT ON V_$DATABASE TO src_schema;
GRANT EXECUTE ON DBMS_LOGMNR TO src_schema;
GRANT EXECUTE ON DBMS_LOGMNR_D TO src_schema;
GRANT EXECUTE ON DBMS_SCHEDULER TO src_schema;
-- Flashback Query 用 (LOB フォールバック)
GRANT FLASHBACK ANY TABLE TO src_schema;

-- tgt_schema: 移行先テーブル群 (oracle-src では DBリンク経由で参照, oracle-tgt では本体)
CREATE USER tgt_schema IDENTIFIED BY &&TGT_SCHEMA_PASS;
GRANT CONNECT, RESOURCE TO tgt_schema;

-- cdc_schema: CDC パッケージ実装・状態管理 (oracle-src でのみ作成)
CREATE USER cdc_schema IDENTIFIED BY &&CDC_SCHEMA_PASS;
GRANT CONNECT, RESOURCE TO cdc_schema;
-- LogMiner 操作権限
GRANT LOGMINING                  TO cdc_schema;
GRANT EXECUTE ON DBMS_LOGMNR     TO cdc_schema;
GRANT EXECUTE ON DBMS_LOGMNR_D   TO cdc_schema;
GRANT EXECUTE ON DBMS_SCHEDULER  TO cdc_schema;
-- V$ / データディクショナリ参照 (SELECT ANY DICTIONARY で一括付与)
GRANT SELECT ANY DICTIONARY      TO cdc_schema;
-- スナップショット: src_schema 全テーブルへの読み取り + Flashback
GRANT SELECT ANY TABLE           TO cdc_schema;
GRANT SELECT ANY TRANSACTION     TO cdc_schema;
GRANT FLASHBACK ANY TABLE        TO cdc_schema;
-- DB リンク作成
GRANT CREATE PUBLIC DATABASE LINK TO cdc_schema;
GRANT CREATE DATABASE LINK        TO cdc_schema;

-- log_schema: 移行フェーズ用ログ管理 (oracle-src でのみ作成)
CREATE USER log_schema IDENTIFIED BY &&LOG_SCHEMA_PASS;
GRANT CONNECT, RESOURCE TO log_schema;

-- 表領域のデフォルト quota 設定
ALTER USER src_schema  QUOTA UNLIMITED ON USERS;
ALTER USER tgt_schema  QUOTA UNLIMITED ON USERS;
ALTER USER cdc_schema  QUOTA UNLIMITED ON USERS;
ALTER USER log_schema  QUOTA UNLIMITED ON USERS;

PROMPT Users created.
EXIT;
