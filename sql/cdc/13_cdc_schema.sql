-- CDC 検証フェーズ: CDC_SCHEMA 制御テーブル作成 (oracle-src 用)
-- cdc_state: CDC 実行状態管理
-- cdc_error_log: CDC 適用エラーログ
-- Oracle 12c 互換: IDENTITY 列不使用, SEQUENCE + TRIGGER で採番
-- 実行ユーザー: SYS AS SYSDBA
-- 実行対象: oracle-src (localhost:1521/XEPDB1)

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

-- ============================================================
-- シーケンス
-- ============================================================

CREATE SEQUENCE cdc_schema.seq_cdc_state
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE SEQUENCE cdc_schema.seq_cdc_error_log
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- ============================================================
-- CDC 実行状態管理テーブル
-- snapshot_scn   : Phase A で取得したスナップショット SCN (CDC 開始基点)
-- last_applied_scn: Phase B で最後に適用完了した SCN
-- status         : IDLE / RUNNING / ERROR
-- ============================================================

CREATE TABLE cdc_schema.cdc_state (
    state_id         NUMBER(10)    NOT NULL,
    run_name         VARCHAR2(100) NOT NULL,
    snapshot_scn     NUMBER(20)    NOT NULL,
    last_applied_scn NUMBER(20),
    status           VARCHAR2(20)  DEFAULT 'IDLE' NOT NULL,
    started_at       TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    last_run_at      TIMESTAMP,
    finished_at      TIMESTAMP,
    error_message    VARCHAR2(4000),
    CONSTRAINT pk_cdc_state        PRIMARY KEY (state_id),
    CONSTRAINT uq_cdc_state_name   UNIQUE (run_name),
    CONSTRAINT ck_cdc_state_status CHECK (status IN ('IDLE','RUNNING','ERROR','STOPPED'))
);

-- ============================================================
-- CDC エラーログテーブル
-- scn        : エラーが発生した変更の SCN
-- table_name : 適用対象テーブル名
-- operation  : INSERT / UPDATE / DELETE
-- sql_redo   : LogMiner から取得した SQL_REDO テキスト (LOB 対応)
-- ============================================================

CREATE TABLE cdc_schema.cdc_error_log (
    error_id      NUMBER(15)    NOT NULL,
    state_id      NUMBER(10),
    scn           NUMBER(20),
    table_name    VARCHAR2(100),
    operation     VARCHAR2(20),
    sql_redo      CLOB,
    error_code    NUMBER,
    error_message VARCHAR2(4000),
    backtrace     VARCHAR2(4000),
    lob_fallback  NUMBER(1)     DEFAULT 0,
    occurred_at   TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_cdc_error_log       PRIMARY KEY (error_id),
    CONSTRAINT fk_cdc_error_log_state FOREIGN KEY (state_id)
                                      REFERENCES cdc_schema.cdc_state(state_id),
    CONSTRAINT ck_cdc_error_lob_fb    CHECK (lob_fallback IN (0, 1))
);

-- ============================================================
-- BEFORE INSERT トリガー
-- ============================================================

CREATE OR REPLACE TRIGGER cdc_schema.trg_cdc_state_bi
BEFORE INSERT ON cdc_schema.cdc_state
FOR EACH ROW
BEGIN
    IF :NEW.state_id IS NULL THEN
        SELECT cdc_schema.seq_cdc_state.NEXTVAL INTO :NEW.state_id FROM DUAL;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER cdc_schema.trg_cdc_error_log_bi
BEFORE INSERT ON cdc_schema.cdc_error_log
FOR EACH ROW
BEGIN
    IF :NEW.error_id IS NULL THEN
        SELECT cdc_schema.seq_cdc_error_log.NEXTVAL INTO :NEW.error_id FROM DUAL;
    END IF;
END;
/

PROMPT CDC_SCHEMA DDL completed: 2 tables, 2 sequences, 2 triggers.
EXIT;
