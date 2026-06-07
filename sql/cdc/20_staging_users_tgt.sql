-- STAGING_SCHEMA ユーザー作成 (oracle-tgt 用)
-- 移行元と同一構造の受け皿スキーマ。DataPump import でテーブル・シーケンス・トリガーを流し込む。
-- 実行ユーザー: SYS AS SYSDBA
-- 実行対象: oracle-tgt (localhost:1522/XEPDB1)

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

-- STAGING_SCHEMA: DataPump import 先（移行元と同一構造）
CREATE USER staging_schema IDENTIFIED BY &&STAGING_SCHEMA_PASS;
GRANT CONNECT, RESOURCE TO staging_schema;
ALTER USER staging_schema QUOTA UNLIMITED ON USERS;

-- redo log 受信ディレクトリ用 Oracle Directory オブジェクト
-- archive log の flat-file 辞書をこのパスに配置する
CREATE OR REPLACE DIRECTORY redo_from_src AS '/opt/oracle/redo_from_src';
GRANT READ, WRITE ON DIRECTORY redo_from_src TO staging_schema;

-- LogMiner 操作は SYS が実行するため STAGING_SCHEMA への SELECT ANY TABLE 付与
GRANT SELECT ANY TABLE TO staging_schema;

-- LogMiner 差分適用後の進捗管理テーブル (SYS スキーマに作成)
CREATE TABLE sys.redo_sync_state (
    state_id         NUMBER        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    last_applied_scn NUMBER(20),
    dict_file        VARCHAR2(500),
    status           VARCHAR2(20) DEFAULT 'IDLE',
    started_at       TIMESTAMP    DEFAULT SYSTIMESTAMP,
    last_run_at      TIMESTAMP,
    error_message    VARCHAR2(4000)
);

INSERT INTO sys.redo_sync_state (last_applied_scn, dict_file, status)
VALUES (0, '/opt/oracle/redo_from_src/dict.ora', 'IDLE');
COMMIT;

PROMPT staging_schema and redo_sync_state created on oracle-tgt.
EXIT;
