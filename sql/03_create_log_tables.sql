-- ログテーブル作成 + クロススキーマ権限付与
-- SYS でクロススキーマ GRANT → log_schema でテーブル・シーケンス・トリガー作成

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

-- --- クロススキーマ権限付与 (SYS) ---
CONNECT sys/&&ORACLE_PASSWORD@//&&ORACLE_HOST:&&ORACLE_PORT/&&ORACLE_SERVICE AS SYSDBA

PROMPT Granting cross-schema privileges to log_schema...
-- PL/SQL 内から参照するため、ロール経由ではなく直接 GRANT が必要
GRANT SELECT ON src_schema.customers TO log_schema;
GRANT SELECT ON src_schema.orders    TO log_schema;
GRANT SELECT, DELETE, INSERT ON tgt_schema.customers TO log_schema;
GRANT SELECT, DELETE, INSERT ON tgt_schema.orders    TO log_schema;

-- --- ログテーブル・シーケンス・トリガー作成 (LOG_SCHEMA) ---
CONNECT log_schema/&&LOG_SCHEMA_PASS@//&&ORACLE_HOST:&&ORACLE_PORT/&&ORACLE_SERVICE

PROMPT Creating migration_run_log...
CREATE SEQUENCE seq_migration_run_log
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE migration_run_log (
    run_id          NUMBER(10)    NOT NULL,
    run_name        VARCHAR2(100) NOT NULL,
    status          VARCHAR2(20)  NOT NULL,
    started_at      DATE          NOT NULL,
    finished_at     DATE,
    total_src_count NUMBER(10)    DEFAULT 0,
    total_tgt_count NUMBER(10)    DEFAULT 0,
    error_message   VARCHAR2(4000),
    CONSTRAINT pk_migration_run_log PRIMARY KEY (run_id),
    CONSTRAINT chk_run_status CHECK (status IN ('RUNNING','SUCCESS','FAILED'))
);

CREATE OR REPLACE TRIGGER trg_migration_run_log_bi
BEFORE INSERT ON migration_run_log
FOR EACH ROW
BEGIN
    IF :NEW.run_id IS NULL THEN
        SELECT seq_migration_run_log.NEXTVAL INTO :NEW.run_id FROM DUAL;
    END IF;
END;
/

PROMPT Creating migration_step_log...
CREATE SEQUENCE seq_migration_step_log
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE migration_step_log (
    step_log_id  NUMBER(10)    NOT NULL,
    run_id       NUMBER(10)    NOT NULL,
    step_name    VARCHAR2(100) NOT NULL,
    status       VARCHAR2(20)  NOT NULL,
    src_count    NUMBER(10)    DEFAULT 0,
    tgt_count    NUMBER(10)    DEFAULT 0,
    batch_no     NUMBER        DEFAULT 0,
    started_at   DATE          NOT NULL,
    finished_at  DATE,
    CONSTRAINT pk_migration_step_log PRIMARY KEY (step_log_id),
    CONSTRAINT fk_step_log_run FOREIGN KEY (run_id)
        REFERENCES migration_run_log(run_id),
    CONSTRAINT chk_step_status CHECK (status IN ('RUNNING','SUCCESS','FAILED','SKIPPED'))
);

CREATE OR REPLACE TRIGGER trg_migration_step_log_bi
BEFORE INSERT ON migration_step_log
FOR EACH ROW
BEGIN
    IF :NEW.step_log_id IS NULL THEN
        SELECT seq_migration_step_log.NEXTVAL INTO :NEW.step_log_id FROM DUAL;
    END IF;
END;
/

PROMPT Creating migration_error_log...
CREATE SEQUENCE seq_migration_error_log
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE migration_error_log (
    error_id         NUMBER(10)    NOT NULL,
    run_id           NUMBER(10)    NOT NULL,
    step_name        VARCHAR2(100),
    error_code       NUMBER,
    error_message    VARCHAR2(4000),
    error_backtrace  VARCHAR2(4000),
    occurred_at      DATE          NOT NULL,
    target_record_id VARCHAR2(100),
    target_table     VARCHAR2(100),
    batch_no         NUMBER,
    error_context    VARCHAR2(4000),
    CONSTRAINT pk_migration_error_log PRIMARY KEY (error_id),
    CONSTRAINT fk_error_log_run FOREIGN KEY (run_id)
        REFERENCES migration_run_log(run_id)
);

CREATE OR REPLACE TRIGGER trg_migration_error_log_bi
BEFORE INSERT ON migration_error_log
FOR EACH ROW
BEGIN
    IF :NEW.error_id IS NULL THEN
        SELECT seq_migration_error_log.NEXTVAL INTO :NEW.error_id FROM DUAL;
    END IF;
END;
/

PROMPT Log tables created.
EXIT;
