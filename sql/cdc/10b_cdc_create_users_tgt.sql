-- CDC 検証フェーズ: oracle-tgt 用ユーザー作成
-- oracle-tgt には tgt_schema のみ作成すればよい
-- 実行ユーザー: SYS AS SYSDBA
-- 実行対象: oracle-tgt (localhost:1522/XEPDB1)

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

-- tgt_schema: CDC 適用先テーブル群
CREATE USER tgt_schema IDENTIFIED BY &&TGT_SCHEMA_PASS;
GRANT CONNECT, RESOURCE TO tgt_schema;
ALTER USER tgt_schema QUOTA UNLIMITED ON USERS;

-- exec_dml ヘルパー呼び出しのための EXECUTE ANY PROCEDURE は不要
-- (exec_dml は tgt_schema 自身のプロシージャのため tgt_schema ユーザーが自動的に実行可能)

PROMPT tgt_schema user created on oracle-tgt.
EXIT;
