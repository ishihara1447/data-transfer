-- 差分抽出方式: staging_ctl スキーマ + delta_queue + apply_ledger (oracle-tgt 用)
-- ★Phase1: COMMIT_SCN対応版。apply_ledger で冪等な再開を保証する。
-- 設計: docs/phase1-commit-scn-redesign.md
-- 実行ユーザー: SYS AS SYSDBA / 実行対象: oracle-tgt XEPDB1

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

-- ============================================================
-- staging_ctl: 差分適用の制御スキーマ
-- ============================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_users WHERE username = 'STAGING_CTL';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE USER staging_ctl IDENTIFIED BY stagingctl1';
        EXECUTE IMMEDIATE 'GRANT CONNECT, RESOURCE TO staging_ctl';
        EXECUTE IMMEDIATE 'ALTER USER staging_ctl QUOTA UNLIMITED ON USERS';
        EXECUTE IMMEDIATE 'GRANT SELECT ANY TABLE TO staging_ctl';
        EXECUTE IMMEDIATE 'GRANT INSERT ANY TABLE TO staging_ctl';
        EXECUTE IMMEDIATE 'GRANT UPDATE ANY TABLE TO staging_ctl';
        EXECUTE IMMEDIATE 'GRANT DELETE ANY TABLE TO staging_ctl';
    END IF;
END;
/

-- Data Pump import 権限（再実行時の冪等性のため毎回付与）
BEGIN
    EXECUTE IMMEDIATE 'GRANT DATAPUMP_IMP_FULL_DATABASE TO staging_ctl';
    EXECUTE IMMEDIATE 'GRANT READ, WRITE ON DIRECTORY DATA_PUMP_DIR TO staging_ctl';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

-- ============================================================
-- delta_queue: 搬送されてきた差分（src と同一構造 + commit_scn/xid）
-- ★Phase1: commit_scn / xid / change_scn / seq_in_tx を含む
-- ============================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_tables
    WHERE owner = 'STAGING_CTL' AND table_name = 'DELTA_QUEUE';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE staging_ctl.delta_queue PURGE';
    END IF;
END;
/

CREATE TABLE staging_ctl.delta_queue (
    delta_id      NUMBER         NOT NULL,
    commit_scn    NUMBER(20)     NOT NULL,   -- ★コミットSCN
    xid           VARCHAR2(40)   NOT NULL,   -- ★トランザクションID
    change_scn    NUMBER(20)     NOT NULL,
    seq_in_tx     NUMBER         NOT NULL,   -- ★Tx内順序
    table_name    VARCHAR2(100)  NOT NULL,
    operation     VARCHAR2(20)   NOT NULL,
    sql_redo      VARCHAR2(4000),
    pk_value      VARCHAR2(100),
    extracted_at  TIMESTAMP,
    CONSTRAINT pk_tgt_delta_queue PRIMARY KEY (delta_id)
);

CREATE INDEX staging_ctl.ix_tgt_delta_order
    ON staging_ctl.delta_queue (commit_scn, xid, seq_in_tx);

-- ============================================================
-- apply_ledger: トランザクション単位の適用台帳 ★G4の核心
-- (xid, commit_scn) で冪等性を担保。再開時の二重適用を防ぐ。
-- ============================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_tables
    WHERE owner = 'STAGING_CTL' AND table_name = 'APPLY_LEDGER';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE '
            CREATE TABLE staging_ctl.apply_ledger (
                xid            VARCHAR2(40)  NOT NULL,
                commit_scn     NUMBER(20)    NOT NULL,
                batch_id       NUMBER,
                change_count   NUMBER,
                applied_at     TIMESTAMP     DEFAULT SYSTIMESTAMP,
                status         VARCHAR2(20)  DEFAULT ''APPLIED'',
                error_message  VARCHAR2(4000),
                CONSTRAINT pk_apply_ledger PRIMARY KEY (xid, commit_scn)
            )';
    END IF;
END;
/

-- ============================================================
-- delta_apply_state: 適用進捗のサマリ（再開点）
-- ★Phase1: last_applied_commit_scn ベース
-- ============================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_tables
    WHERE owner = 'STAGING_CTL' AND table_name = 'DELTA_APPLY_STATE';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE staging_ctl.delta_apply_state PURGE';
    END IF;
END;
/

CREATE TABLE staging_ctl.delta_apply_state (
    run_name                VARCHAR2(50) NOT NULL,
    last_applied_commit_scn NUMBER(20)   DEFAULT 0 NOT NULL,  -- ★再開点
    applied_tx_count        NUMBER       DEFAULT 0,
    applied_row_count       NUMBER       DEFAULT 0,
    failed_tx_count         NUMBER       DEFAULT 0,
    last_run_at             TIMESTAMP,
    CONSTRAINT pk_delta_apply_state PRIMARY KEY (run_name)
);

INSERT INTO staging_ctl.delta_apply_state(run_name) VALUES('delta_run_01');
COMMIT;

PROMPT staging_ctl, delta_queue(commit_scn版), apply_ledger, delta_apply_state created on oracle-tgt.
EXIT;
