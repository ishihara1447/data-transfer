-- SQL_REDO直接適用ホワイトリスト (oracle-src 用)
-- SQL_REDO を EXECUTE IMMEDIATE で直接適用してよいテーブルを明示的に管理する。
-- delta_extract が抽出時の replay_category='A' 判定に参照する。
--
-- 登録条件（すべて満たすこと）:
--   - LOB/XMLType/LONG/UDT などを含まない (cdc_table_catalog.lob_present='N')
--   - 移行元 SRC_SCHEMA と移行先 STAGING_SCHEMA の構造が同一
--   - 主キーまたは一意キーで対象行を安定して特定できる
--   - INSERT/UPDATE/DELETE の通常DMLのみ対象
--   - 検証環境でSQL_REDO再実行可否を PoC 確認済み
--
-- 禁止事項:
--   - LOBあり（cdc_table_catalog.lob_present='Y'）テーブルの登録禁止
--   - PoC 未確認テーブルの登録禁止
--   - replay_allowed='N' は「明示的除外」用（デフォルト非適用とは別）
--
-- 実行ユーザー: SYS AS SYSDBA / 実行対象: oracle-src XEPDB1 / Oracle 12c 互換 / 冪等

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_tables
    WHERE owner = 'CDC_SCHEMA' AND table_name = 'REDO_REPLAY_WHITELIST';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE cdc_schema.redo_replay_whitelist PURGE';
    END IF;
END;
/

CREATE TABLE cdc_schema.redo_replay_whitelist (
    owner_name      VARCHAR2(128) NOT NULL,
    table_name      VARCHAR2(128) NOT NULL,
    replay_allowed  CHAR(1)       DEFAULT 'Y' NOT NULL,
    reason          VARCHAR2(4000),
    verified_at     TIMESTAMP,
    verified_by     VARCHAR2(128),
    CONSTRAINT pk_redo_replay_whitelist PRIMARY KEY (owner_name, table_name),
    CONSTRAINT chk_redo_replay_allowed  CHECK (replay_allowed IN ('Y', 'N'))
);

COMMENT ON TABLE cdc_schema.redo_replay_whitelist IS
    'SQL_REDO直接適用(EXECUTE IMMEDIATE)を許可するテーブルのホワイトリスト。'
    || 'LOBあり・PoC未確認テーブルは登録禁止。delta_extractがreplay_category判定に使用する。';

-- REGIONS: LOBなし・STAGING同一構造・PK(REGION_ID NUMBER)安定
-- 検証環境 E2E で INSERT/UPDATE/DELETE の SQL_REDO 再実行動作確認済み
INSERT INTO cdc_schema.redo_replay_whitelist
    (owner_name, table_name, replay_allowed, reason, verified_at, verified_by)
VALUES
    ('SRC_SCHEMA', 'REGIONS', 'Y',
     'LOBなし・STAGING_SCHEMA同一構造・PK(REGION_ID NUMBER6)安定。'
     || 'cdc_table_catalog.lob_present=N・replay_category=A。検証環境PoC確認済み。',
     SYSTIMESTAMP, 'setup.sh');

-- CUSTOMERS / ORDERS は LOBあり → 登録禁止（参考: cdc_table_catalog.replay_category=C）
-- 将来 LOBフォールバック実装後に登録を検討する。

COMMIT;

PROMPT cdc_schema.redo_replay_whitelist created. Registered: REGIONS(Y). CUSTOMERS/ORDERS excluded(LOB).
EXIT;
