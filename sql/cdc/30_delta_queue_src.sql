-- 差分抽出方式: delta_queue テーブル (oracle-src 用) ★Phase2: SQL_REDO安全性判定カラム追加版
-- PKG_DELTA_EXTRACT が LogMiner で抽出した変更を貯める搬送用キュー
-- このテーブルを Data Pump でダンプファイル化して oracle-tgt に搬送する
-- 設計: docs/phase1-commit-scn-redesign.md / docs/delta-extract-design.md (セクション9)
-- 実行ユーザー: SYS AS SYSDBA / 実行対象: oracle-src XEPDB1

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

-- ============================================================
-- delta_queue: 抽出された差分の格納先（＝搬送元）
-- ★Phase1: commit_scn / xid / change_scn / seq_in_tx を追加
-- ★Phase2: LogMiner STATUS/CSF/OPERATION_CODE + replay_category/replay_allowed を追加
-- ============================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_tables
    WHERE owner = 'CDC_SCHEMA' AND table_name = 'DELTA_QUEUE';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE cdc_schema.delta_queue PURGE';
    END IF;
END;
/

CREATE TABLE cdc_schema.delta_queue (
    delta_id           NUMBER         NOT NULL,   -- 連番（搬送単位内の物理順序）
    commit_scn         NUMBER(20)     NOT NULL,   -- ★コミットSCN（境界判定の基準）
    xid                VARCHAR2(40)   NOT NULL,   -- ★トランザクションID
    change_scn         NUMBER(20)     NOT NULL,   -- 変更SCN（Tx内順序の補助）
    seq_in_tx          NUMBER         NOT NULL,   -- ★Tx内の操作順（commit内連番）
    table_name         VARCHAR2(100)  NOT NULL,
    operation          VARCHAR2(20)   NOT NULL,   -- INSERT/UPDATE/DELETE
    -- ★Phase2: LogMiner メタ情報（SQL_REDO安全性判定用）
    operation_code     NUMBER,                    -- V$LOGMNR_CONTENTS.OPERATION_CODE
    status_code        NUMBER,                    -- V$LOGMNR_CONTENTS.STATUS (0=正常)
    info_text          VARCHAR2(4000),            -- V$LOGMNR_CONTENTS.INFO (STATUS異常時の詳細)
    csf                NUMBER        DEFAULT 0,   -- 0=SQL完結, 1=次行に継続 (Continuation SQL Flag)
    rs_id              VARCHAR2(64),              -- V$LOGMNR_CONTENTS.RS_ID (Redo順序ID)
    ssn                NUMBER,                    -- V$LOGMNR_CONTENTS.SSN (文順序番号)
    -- SQL テキスト
    sql_redo           VARCHAR2(4000),            -- LogMiner生成SQL（先頭4000文字）
    sql_redo_assembled CLOB,                      -- ★CSF連結済み完全SQL（適用時はこちらを使う）
    -- ★Phase2: 適用方式分類（delta_extractが付与）
    replay_category    VARCHAR2(1),               -- A/B/C/D/E (docs/delta-extract-design.md 参照)
    replay_allowed     CHAR(1)       DEFAULT 'N', -- Y=直接適用可 / N=直接適用禁止
    fallback_required  CHAR(1)       DEFAULT 'N', -- Y=LOBフォールバック必要
    fallback_reason    VARCHAR2(4000),            -- 直接適用禁止の理由
    -- 参照用
    pk_value           VARCHAR2(100),             -- PK値（LOB再取得用ベストエフォート抽出）
    extracted_at       TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_delta_queue PRIMARY KEY (delta_id)
);

-- 適用順序保証のためのインデックス（commit_scn, xid, seq_in_tx）
CREATE INDEX cdc_schema.ix_delta_queue_order
    ON cdc_schema.delta_queue (commit_scn, xid, seq_in_tx);

-- delta_id 採番用シーケンス
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_sequences
    WHERE sequence_owner = 'CDC_SCHEMA' AND sequence_name = 'SEQ_DELTA_QUEUE';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'DROP SEQUENCE cdc_schema.seq_delta_queue';
    END IF;
END;
/

CREATE SEQUENCE cdc_schema.seq_delta_queue
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- ============================================================
-- delta_extract_state: 抽出の進捗管理
-- ★Phase1: last_extracted_commit_scn（commit基準）+ baseline_scn
-- ============================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_tables
    WHERE owner = 'CDC_SCHEMA' AND table_name = 'DELTA_EXTRACT_STATE';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE cdc_schema.delta_extract_state PURGE';
    END IF;
END;
/

CREATE TABLE cdc_schema.delta_extract_state (
    run_name                  VARCHAR2(50)  NOT NULL,
    baseline_scn              NUMBER(20),                    -- 初期ロードのFLASHBACK_SCN
    last_extracted_commit_scn NUMBER(20)    DEFAULT 0 NOT NULL,  -- ★高位水準点(HW): commitフィルタ基準の再開点
    mine_start_scn            NUMBER(20)    DEFAULT 0 NOT NULL,  -- ★低位水準点(LW): START_LOGMNR の採掘開始点
    status                    VARCHAR2(20)  DEFAULT 'IDLE',
    last_run_at               TIMESTAMP,
    error_message             VARCHAR2(4000),
    CONSTRAINT pk_delta_extract_state PRIMARY KEY (run_name)
);
-- ★HW/LW 分離（長時間Tx境界バグ対策）:
--   last_extracted_commit_scn(HW) = WHERE COMMIT_SCN > HW のフィルタ基準。抽出済み最大COMMIT_SCNへ前進。
--   mine_start_scn(LW)            = START_LOGMNR の STARTSCN。未コミットの最古Txの開始SCNより前に保つ。
--   LW を HW と同一視すると、baseline を跨ぐ長時間Txの開始レコードが採掘窓から外れ欠落する。
--   詳細: docs/phase1-commit-scn-redesign.md セクション10.1

PROMPT delta_queue(commit_scn/xid版), seq_delta_queue, delta_extract_state created on oracle-src.
EXIT;
