-- PKG_MIG_ADMIN v5.0（フェーズ4 API 追加版）
-- 注意: このファイルはパッケージ全体を再定義する。07の24本に加えフェーズ4用APIを追加した。
-- 設計: docs/phase4-design.md §5
-- 実行ユーザー: migration_ctl / 実行対象: oracle-tgt (localhost:1522/XEPDB1)
-- 前提: 01〜09 の SQL が全て適用済みであること
-- エラー番号規約:
--   -20001: 汎用の事前条件不満
--   -20002: 事前条件不満（重複・状態不正）
--   -20011: COMPLETE_PHASE3 完了条件未達
--   -20012: フェーズ4追加: 不正な状態遷移

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON FEEDBACK ON SERVEROUTPUT ON SIZE UNLIMITED

-- ===========================================================================
-- パッケージ仕様部
-- 既存24本 + フェーズ4追加型定義 + フェーズ4追加API
-- ===========================================================================

CREATE OR REPLACE PACKAGE PKG_MIG_ADMIN AS

    -- -----------------------------------------------------------------------
    -- 既存 API（07_pkg_mig_admin_phase3.sql から継続）
    -- -----------------------------------------------------------------------

    PROCEDURE CREATE_RUN (
        p_run_name       IN  VARCHAR2,
        p_run_type       IN  VARCHAR2,
        p_source_db_info IN  VARCHAR2 DEFAULT NULL,
        p_target_db_info IN  VARCHAR2 DEFAULT NULL,
        p_run_id         OUT NUMBER
    );

    PROCEDURE FIX_BASELINE_SCN (
        p_run_id       IN NUMBER,
        p_baseline_scn IN NUMBER
    );

    PROCEDURE MARK_ARCHIVE_READY (
        p_run_id IN NUMBER
    );

    PROCEDURE SET_TARGET_END_SCN (
        p_run_id         IN NUMBER,
        p_target_end_scn IN NUMBER
    );

    PROCEDURE UPDATE_LAST_APPLIED_SCN (
        p_run_id IN NUMBER,
        p_scn    IN NUMBER
    );

    PROCEDURE START_DATAPUMP_JOB (
        p_job_id IN NUMBER
    );

    PROCEDURE COMPLETE_DATAPUMP_JOB (
        p_job_id      IN NUMBER,
        p_rows        IN NUMBER DEFAULT NULL,
        p_bytes       IN NUMBER DEFAULT NULL,
        p_error_count IN NUMBER DEFAULT 0
    );

    PROCEDURE FAIL_DATAPUMP_JOB (
        p_job_id        IN NUMBER,
        p_error_message IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE VERIFY_ARCHIVE_LOG_COPY (
        p_copy_id  IN NUMBER,
        p_checksum IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE LOG_STATUS_CHANGE (
        p_run_id     IN NUMBER,
        p_table_name IN VARCHAR2,
        p_record_id  IN NUMBER,
        p_old_status IN VARCHAR2 DEFAULT NULL,
        p_new_status IN VARCHAR2,
        p_note       IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE REGISTER_DATAPUMP_FILE (
        p_run_id           IN  NUMBER,
        p_job_id           IN  NUMBER,
        p_file_role        IN  VARCHAR2,
        p_file_name        IN  VARCHAR2,
        p_file_path        IN  VARCHAR2 DEFAULT NULL,
        p_storage_location IN  VARCHAR2 DEFAULT NULL,
        p_file_id          OUT NUMBER
    );

    PROCEDURE VERIFY_DATAPUMP_FILE (
        p_file_id         IN NUMBER,
        p_file_size_bytes IN NUMBER,
        p_checksum_algo   IN VARCHAR2,
        p_checksum_value  IN VARCHAR2
    );

    PROCEDURE CONSUME_DATAPUMP_FILE (
        p_file_id       IN NUMBER,
        p_import_job_id IN NUMBER
    );

    PROCEDURE START_VALIDATION_RUN (
        p_run_id            IN  NUMBER,
        p_phase_code        IN  VARCHAR2,
        p_validation_type   IN  VARCHAR2,
        p_validation_run_id OUT NUMBER
    );

    PROCEDURE COMPLETE_VALIDATION_RUN (
        p_validation_run_id IN NUMBER,
        p_overall_result    IN VARCHAR2
    );

    PROCEDURE RECORD_VALIDATION_RESULT (
        p_validation_run_id IN  NUMBER,
        p_mig_object_id     IN  NUMBER DEFAULT NULL,
        p_check_name        IN  VARCHAR2,
        p_expected_value    IN  VARCHAR2 DEFAULT NULL,
        p_actual_value      IN  VARCHAR2 DEFAULT NULL,
        p_result            IN  VARCHAR2,
        p_result_id         OUT NUMBER
    );

    PROCEDURE RAISE_ERROR_EVENT (
        p_run_id          IN  NUMBER,
        p_phase_code      IN  VARCHAR2 DEFAULT NULL,
        p_severity        IN  VARCHAR2,
        p_component_name  IN  VARCHAR2 DEFAULT NULL,
        p_datapump_job_id IN  NUMBER   DEFAULT NULL,
        p_ora_error_code  IN  VARCHAR2 DEFAULT NULL,
        p_error_message   IN  VARCHAR2 DEFAULT NULL,
        p_event_id        OUT NUMBER
    );

    PROCEDURE COMPLETE_PHASE (
        p_run_id     IN NUMBER,
        p_phase_code IN VARCHAR2
    );

    PROCEDURE REGISTER_ARCHIVE_LOG (
        p_run_id         IN  NUMBER,
        p_dbid           IN  NUMBER,
        p_resetlogs_id   IN  NUMBER,
        p_thread_no      IN  NUMBER,
        p_seq_no         IN  NUMBER,
        p_first_scn      IN  NUMBER,
        p_next_scn       IN  NUMBER,
        p_first_time     IN  TIMESTAMP DEFAULT NULL,
        p_next_time      IN  TIMESTAMP DEFAULT NULL,
        p_archive_log_id OUT NUMBER
    );

    PROCEDURE RECEIVE_ARCHIVE_LOG (
        p_archive_log_id IN NUMBER
    );

    PROCEDURE REGISTER_ARCHIVE_LOG_COPY (
        p_archive_log_id IN  NUMBER,
        p_storage_loc    IN  VARCHAR2,
        p_file_path      IN  VARCHAR2,
        p_file_size      IN  NUMBER,
        p_checksum_algo  IN  VARCHAR2,
        p_checksum_val   IN  VARCHAR2,
        p_copy_id        OUT NUMBER
    );

    PROCEDURE SET_DICT_MARKERS (
        p_archive_log_id IN NUMBER,
        p_dict_begin     IN CHAR,
        p_dict_end       IN CHAR
    );

    PROCEDURE UPSERT_CHECKPOINT (
        p_run_id    IN NUMBER,
        p_component IN VARCHAR2,
        p_key       IN VARCHAR2,
        p_thread_no IN NUMBER,
        p_seq_no    IN NUMBER,
        p_scn       IN NUMBER
    );

    PROCEDURE COMPLETE_PHASE3 (
        p_run_id IN NUMBER
    );

    -- -----------------------------------------------------------------------
    -- v5.0 追加 API（フェーズ4: Archived Redo 解析・差分反映）
    -- 設計: docs/phase4-design.md §5
    -- -----------------------------------------------------------------------

    -- バルク登録用 Collection 型定義
    TYPE T_MINED_TX_REC IS RECORD (
        MIG_RUN_ID           NUMBER,
        LOGMINER_BATCH_ID    NUMBER,
        XID                  VARCHAR2(50),
        START_SCN            NUMBER,
        COMMIT_SCN           NUMBER,
        CHANGE_COUNT         NUMBER
    );
    TYPE T_MINED_TX_TBL IS TABLE OF T_MINED_TX_REC INDEX BY PLS_INTEGER;

    TYPE T_MINED_CHG_REC IS RECORD (
        MIG_RUN_ID           NUMBER,
        LOGMINER_BATCH_ID    NUMBER,
        MINED_TRANSACTION_ID NUMBER,
        RS_ID                VARCHAR2(100),
        SSN                  NUMBER,
        SCN                  NUMBER,
        COMMIT_SCN           NUMBER,
        OPERATION            VARCHAR2(20),
        SEG_OWNER            VARCHAR2(100),
        TABLE_NAME           VARCHAR2(100),
        CSF                  NUMBER
    );
    TYPE T_MINED_CHG_TBL IS TABLE OF T_MINED_CHG_REC INDEX BY PLS_INTEGER;

    TYPE T_APPLY_TASK_REC IS RECORD (
        MIG_RUN_ID           NUMBER,
        APPLY_BATCH_ID       NUMBER,
        MINED_CHANGE_ID      NUMBER,
        SEG_OWNER            VARCHAR2(100),
        TABLE_NAME           VARCHAR2(100),
        DML_TYPE             VARCHAR2(10),
        KEY_PAYLOAD          VARCHAR2(4000),
        DML_TEXT             VARCHAR2(4000)
    );
    TYPE T_APPLY_TASK_TBL IS TABLE OF T_APPLY_TASK_REC INDEX BY PLS_INTEGER;

    -- LOGMINER_BATCH API
    PROCEDURE REGISTER_LOGMINER_BATCH (
        p_run_id         IN  NUMBER,
        p_batch_no       IN  NUMBER,
        p_from_scn       IN  NUMBER,
        p_to_scn         IN  NUMBER,
        p_dict_method    IN  VARCHAR2,
        p_logmnr_options IN  VARCHAR2 DEFAULT NULL,
        p_batch_id       OUT NUMBER
    );

    PROCEDURE BEGIN_LOGMINER_BATCH (p_batch_id IN NUMBER);

    PROCEDURE COMPLETE_LOGMINER_BATCH (
        p_batch_id     IN NUMBER,
        p_change_count IN NUMBER DEFAULT NULL,
        p_tx_count     IN NUMBER DEFAULT NULL
    );

    PROCEDURE FAIL_LOGMINER_BATCH (
        p_batch_id  IN NUMBER,
        p_error_msg IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE ADD_BATCH_LOG (
        p_batch_id       IN NUMBER,
        p_archive_log_id IN NUMBER,
        p_add_order      IN NUMBER
    );

    -- ARCHIVE_LOG 状態更新
    PROCEDURE SET_MINING_STATUS (
        p_archive_log_id IN NUMBER,
        p_mining_status  IN VARCHAR2
    );

    PROCEDURE SET_APPLY_STATUS (
        p_archive_log_id IN NUMBER,
        p_apply_status   IN VARCHAR2
    );

    -- バルク登録
    PROCEDURE BULK_INS_MINED_TX  (p_rows IN T_MINED_TX_TBL);
    PROCEDURE BULK_INS_MINED_CHG (p_rows IN T_MINED_CHG_TBL);

    -- APPLY_BATCH API
    PROCEDURE REGISTER_APPLY_BATCH (
        p_run_id          IN  NUMBER,
        p_batch_no        IN  NUMBER,
        p_from_commit_scn IN  NUMBER,
        p_to_commit_scn   IN  NUMBER,
        p_batch_id        OUT NUMBER
    );

    PROCEDURE BEGIN_APPLY_BATCH (p_batch_id IN NUMBER);

    PROCEDURE COMPLETE_APPLY_BATCH (
        p_batch_id IN NUMBER,
        p_applied  IN NUMBER DEFAULT 0,
        p_skipped  IN NUMBER DEFAULT 0,
        p_errors   IN NUMBER DEFAULT 0
    );

    PROCEDURE FAIL_APPLY_BATCH (
        p_batch_id  IN NUMBER,
        p_error_msg IN VARCHAR2 DEFAULT NULL
    );

    -- APPLY_TASK API
    PROCEDURE QUEUE_APPLY_TASK (
        p_batch_id        IN  NUMBER,
        p_mined_change_id IN  NUMBER,
        p_seg_owner       IN  VARCHAR2,
        p_table_name      IN  VARCHAR2,
        p_dml_type        IN  VARCHAR2,
        p_key_payload     IN  VARCHAR2 DEFAULT NULL,
        p_dml_text        IN  VARCHAR2 DEFAULT NULL,
        p_task_id         OUT NUMBER
    );

    PROCEDURE START_APPLY_TASK (
        p_task_id  IN NUMBER,
        p_executor IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE COMPLETE_APPLY_TASK (p_task_id IN NUMBER);

    PROCEDURE RETRY_APPLY_TASK (
        p_task_id   IN NUMBER,
        p_error_id  IN NUMBER  DEFAULT NULL,
        p_error_msg IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE ERROR_APPLY_TASK (
        p_task_id   IN NUMBER,
        p_error_id  IN NUMBER  DEFAULT NULL,
        p_error_msg IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE BULK_INS_APPLY_TASKS (p_rows IN T_APPLY_TASK_TBL);

    -- 状態更新ユーティリティ
    PROCEDURE UPDATE_MINED_TX_STATUS (
        p_mined_transaction_id IN NUMBER,
        p_new_status           IN VARCHAR2
    );

    PROCEDURE UPDATE_MINED_CHG_STATUS (
        p_mined_change_id IN NUMBER,
        p_new_status      IN VARCHAR2
    );

END PKG_MIG_ADMIN;
/

-- ===========================================================================
-- パッケージ本体
-- ===========================================================================

CREATE OR REPLACE PACKAGE BODY PKG_MIG_ADMIN AS

    -- =========================================================================
    -- 既存プロシージャ（07_pkg_mig_admin_phase3.sql から継続・変更なし）
    -- =========================================================================

    PROCEDURE CREATE_RUN (
        p_run_name       IN  VARCHAR2,
        p_run_type       IN  VARCHAR2,
        p_source_db_info IN  VARCHAR2 DEFAULT NULL,
        p_target_db_info IN  VARCHAR2 DEFAULT NULL,
        p_run_id         OUT NUMBER
    ) IS
        v_run_id NUMBER;
    BEGIN
        INSERT INTO MIGRATION_RUN (
            RUN_NAME, RUN_TYPE, SOURCE_DB_INFO, TARGET_DB_INFO, STATUS
        ) VALUES (
            p_run_name, p_run_type, p_source_db_info, p_target_db_info, 'CREATED'
        )
        RETURNING MIG_RUN_ID INTO v_run_id;

        INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE, STATUS)
        VALUES (v_run_id, 'PREP_A', 'NOT_STARTED');
        INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE, STATUS)
        VALUES (v_run_id, 'PREP_B', 'NOT_STARTED');
        INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE, STATUS)
        VALUES (v_run_id, 'PHASE1', 'NOT_STARTED');
        INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE, STATUS)
        VALUES (v_run_id, 'PHASE2', 'NOT_STARTED');
        INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE, STATUS)
        VALUES (v_run_id, 'PHASE3', 'NOT_STARTED');
        INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE, STATUS)
        VALUES (v_run_id, 'PHASE4', 'NOT_STARTED');
        INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE, STATUS)
        VALUES (v_run_id, 'PHASE5', 'NOT_STARTED');

        LOG_STATUS_CHANGE(
            p_run_id     => v_run_id,
            p_table_name => 'MIGRATION_RUN',
            p_record_id  => v_run_id,
            p_old_status => NULL,
            p_new_status => 'CREATED',
            p_note       => 'CREATE_RUN: ' || p_run_name
        );

        COMMIT;
        p_run_id := v_run_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END CREATE_RUN;

    PROCEDURE FIX_BASELINE_SCN (
        p_run_id       IN NUMBER,
        p_baseline_scn IN NUMBER
    ) IS
        v_baseline_scn     NUMBER;
        v_mining_start_scn NUMBER;
        v_old_status       VARCHAR2(20);
    BEGIN
        SELECT BASELINE_SCN, MINING_START_SCN, STATUS
        INTO v_baseline_scn, v_mining_start_scn, v_old_status
        FROM MIGRATION_RUN
        WHERE MIG_RUN_ID = p_run_id
        FOR UPDATE;

        IF v_baseline_scn IS NOT NULL THEN
            RAISE_APPLICATION_ERROR(-20001,
                'BASELINE_SCN は既に設定済みです（' || v_baseline_scn ||
                '）。上書きは禁止されています。');
        END IF;

        IF v_mining_start_scn IS NOT NULL
            AND p_baseline_scn < v_mining_start_scn
        THEN
            RAISE_APPLICATION_ERROR(-20002,
                'p_baseline_scn(' || p_baseline_scn ||
                ') は MINING_START_SCN(' || v_mining_start_scn ||
                ') より小さい値は設定できません。');
        END IF;

        UPDATE MIGRATION_RUN
        SET BASELINE_SCN      = p_baseline_scn,
            STATUS            = 'BASELINE_FIXED',
            BASELINE_FIXED_AT = SYSTIMESTAMP,
            UPDATED_AT        = SYSTIMESTAMP
        WHERE MIG_RUN_ID = p_run_id;

        LOG_STATUS_CHANGE(
            p_run_id     => p_run_id,
            p_table_name => 'MIGRATION_RUN',
            p_record_id  => p_run_id,
            p_old_status => v_old_status,
            p_new_status => 'BASELINE_FIXED',
            p_note       => 'BASELINE_SCN=' || p_baseline_scn
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END FIX_BASELINE_SCN;

    PROCEDURE MARK_ARCHIVE_READY (
        p_run_id IN NUMBER
    ) IS
        v_log_count  NUMBER;
        v_old_status VARCHAR2(20);
    BEGIN
        SELECT STATUS
        INTO v_old_status
        FROM MIGRATION_RUN
        WHERE MIG_RUN_ID = p_run_id
        FOR UPDATE;

        SELECT COUNT(*)
        INTO v_log_count
        FROM ARCHIVE_LOG
        WHERE MIG_RUN_ID = p_run_id;

        IF v_log_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20003,
                'ARCHIVE_LOG カバレッジが不足しています。MIG_RUN_ID=' || p_run_id ||
                ' に対応する ARCHIVE_LOG レコードが存在しません。');
        END IF;

        UPDATE MIGRATION_RUN
        SET STATUS           = 'ARCHIVE_READY',
            ARCHIVE_READY_AT = SYSTIMESTAMP,
            UPDATED_AT       = SYSTIMESTAMP
        WHERE MIG_RUN_ID = p_run_id;

        LOG_STATUS_CHANGE(
            p_run_id     => p_run_id,
            p_table_name => 'MIGRATION_RUN',
            p_record_id  => p_run_id,
            p_old_status => v_old_status,
            p_new_status => 'ARCHIVE_READY',
            p_note       => 'ARCHIVE_LOG件数=' || v_log_count
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END MARK_ARCHIVE_READY;

    PROCEDURE SET_TARGET_END_SCN (
        p_run_id         IN NUMBER,
        p_target_end_scn IN NUMBER
    ) IS
        v_target_end_scn NUMBER;
        v_status         VARCHAR2(20);
    BEGIN
        SELECT TARGET_END_SCN, STATUS
        INTO v_target_end_scn, v_status
        FROM MIGRATION_RUN
        WHERE MIG_RUN_ID = p_run_id
        FOR UPDATE;

        IF v_target_end_scn IS NOT NULL THEN
            RAISE_APPLICATION_ERROR(-20001,
                'TARGET_END_SCN は既に設定済みです（' || v_target_end_scn ||
                '）。上書きは禁止されています。');
        END IF;

        UPDATE MIGRATION_RUN
        SET TARGET_END_SCN = p_target_end_scn,
            UPDATED_AT     = SYSTIMESTAMP
        WHERE MIG_RUN_ID = p_run_id;

        LOG_STATUS_CHANGE(
            p_run_id     => p_run_id,
            p_table_name => 'MIGRATION_RUN',
            p_record_id  => p_run_id,
            p_old_status => v_status,
            p_new_status => v_status,
            p_note       => 'TARGET_END_SCN=' || p_target_end_scn
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END SET_TARGET_END_SCN;

    PROCEDURE UPDATE_LAST_APPLIED_SCN (
        p_run_id IN NUMBER,
        p_scn    IN NUMBER
    ) IS
        v_last_applied_scn NUMBER;
        v_target_end_scn   NUMBER;
    BEGIN
        SELECT LAST_APPLIED_SCN, TARGET_END_SCN
        INTO v_last_applied_scn, v_target_end_scn
        FROM MIGRATION_RUN
        WHERE MIG_RUN_ID = p_run_id
        FOR UPDATE;

        IF v_last_applied_scn IS NOT NULL
            AND p_scn < v_last_applied_scn
        THEN
            RAISE_APPLICATION_ERROR(-20004,
                'SCN後退は禁止されています。現在LAST_APPLIED_SCN=' ||
                v_last_applied_scn || '、指定値=' || p_scn);
        END IF;

        IF v_target_end_scn IS NOT NULL
            AND p_scn > v_target_end_scn
        THEN
            DBMS_OUTPUT.PUT_LINE(
                '警告: p_scn(' || p_scn ||
                ') が TARGET_END_SCN(' || v_target_end_scn ||
                ') を超えています。');
        END IF;

        UPDATE MIGRATION_RUN
        SET LAST_APPLIED_SCN = p_scn,
            UPDATED_AT       = SYSTIMESTAMP
        WHERE MIG_RUN_ID = p_run_id;

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END UPDATE_LAST_APPLIED_SCN;

    PROCEDURE START_DATAPUMP_JOB (
        p_job_id IN NUMBER
    ) IS
        v_status VARCHAR2(20);
        v_run_id NUMBER;
    BEGIN
        SELECT STATUS, MIG_RUN_ID
        INTO v_status, v_run_id
        FROM DATAPUMP_JOB
        WHERE DATAPUMP_JOB_ID = p_job_id
        FOR UPDATE;

        IF v_status NOT IN ('PLANNED', 'RETRY') THEN
            RAISE_APPLICATION_ERROR(-20002,
                'START_DATAPUMP_JOB の事前条件エラー: STATUS=' || v_status ||
                '。PLANNED または RETRY の状態から開始できます。');
        END IF;

        UPDATE DATAPUMP_JOB
        SET STATUS     = 'RUNNING',
            STARTED_AT = SYSTIMESTAMP,
            UPDATED_AT = SYSTIMESTAMP
        WHERE DATAPUMP_JOB_ID = p_job_id;

        LOG_STATUS_CHANGE(
            p_run_id     => v_run_id,
            p_table_name => 'DATAPUMP_JOB',
            p_record_id  => p_job_id,
            p_old_status => v_status,
            p_new_status => 'RUNNING',
            p_note       => NULL
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END START_DATAPUMP_JOB;

    PROCEDURE COMPLETE_DATAPUMP_JOB (
        p_job_id      IN NUMBER,
        p_rows        IN NUMBER DEFAULT NULL,
        p_bytes       IN NUMBER DEFAULT NULL,
        p_error_count IN NUMBER DEFAULT 0
    ) IS
        v_status VARCHAR2(20);
        v_run_id NUMBER;
    BEGIN
        SELECT STATUS, MIG_RUN_ID
        INTO v_status, v_run_id
        FROM DATAPUMP_JOB
        WHERE DATAPUMP_JOB_ID = p_job_id
        FOR UPDATE;

        IF v_status != 'RUNNING' THEN
            RAISE_APPLICATION_ERROR(-20002,
                'COMPLETE_DATAPUMP_JOB: ジョブ状態が RUNNING ではありません（現在: ' ||
                v_status || '）');
        END IF;

        UPDATE DATAPUMP_JOB
        SET STATUS          = 'COMPLETED',
            FINISHED_AT     = SYSTIMESTAMP,
            PROCESSED_ROWS  = p_rows,
            PROCESSED_BYTES = p_bytes,
            ERROR_COUNT     = p_error_count,
            UPDATED_AT      = SYSTIMESTAMP
        WHERE DATAPUMP_JOB_ID = p_job_id;

        LOG_STATUS_CHANGE(
            p_run_id     => v_run_id,
            p_table_name => 'DATAPUMP_JOB',
            p_record_id  => p_job_id,
            p_old_status => v_status,
            p_new_status => 'COMPLETED',
            p_note       => 'rows=' || NVL(TO_CHAR(p_rows), 'NULL') ||
                            ',bytes=' || NVL(TO_CHAR(p_bytes), 'NULL') ||
                            ',errors=' || NVL(TO_CHAR(p_error_count), '0')
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END COMPLETE_DATAPUMP_JOB;

    PROCEDURE FAIL_DATAPUMP_JOB (
        p_job_id        IN NUMBER,
        p_error_message IN VARCHAR2 DEFAULT NULL
    ) IS
        v_status VARCHAR2(20);
        v_run_id NUMBER;
    BEGIN
        SELECT STATUS, MIG_RUN_ID
        INTO v_status, v_run_id
        FROM DATAPUMP_JOB
        WHERE DATAPUMP_JOB_ID = p_job_id
        FOR UPDATE;

        IF v_status NOT IN ('PLANNED', 'RUNNING', 'RETRY') THEN
            RAISE_APPLICATION_ERROR(-20002,
                'FAIL_DATAPUMP_JOB: ジョブ状態が PLANNED/RUNNING/RETRY ではありません（現在: ' ||
                v_status || '）');
        END IF;

        UPDATE DATAPUMP_JOB
        SET STATUS      = 'FAILED',
            FINISHED_AT = SYSTIMESTAMP,
            REMARKS     = p_error_message,
            UPDATED_AT  = SYSTIMESTAMP
        WHERE DATAPUMP_JOB_ID = p_job_id;

        LOG_STATUS_CHANGE(
            p_run_id     => v_run_id,
            p_table_name => 'DATAPUMP_JOB',
            p_record_id  => p_job_id,
            p_old_status => v_status,
            p_new_status => 'FAILED',
            p_note       => p_error_message
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END FAIL_DATAPUMP_JOB;

    PROCEDURE VERIFY_ARCHIVE_LOG_COPY (
        p_copy_id  IN NUMBER,
        p_checksum IN VARCHAR2 DEFAULT NULL
    ) IS
        v_copy_status    VARCHAR2(20);
        v_archive_log_id NUMBER;
        v_run_id         NUMBER;
        v_unverified_cnt NUMBER;
    BEGIN
        SELECT COPY_STATUS, ARCHIVE_LOG_ID, MIG_RUN_ID
        INTO v_copy_status, v_archive_log_id, v_run_id
        FROM ARCHIVE_LOG_COPY
        WHERE ARCHIVE_LOG_COPY_ID = p_copy_id
        FOR UPDATE;

        IF v_copy_status != 'RECEIVED' THEN
            RAISE_APPLICATION_ERROR(-20002,
                'VERIFY_ARCHIVE_LOG_COPY の事前条件エラー: COPY_STATUS=' ||
                v_copy_status || '。RECEIVED 状態のみ VERIFIED へ遷移できます。');
        END IF;

        IF p_checksum IS NULL THEN
            UPDATE ARCHIVE_LOG_COPY
            SET COPY_STATUS = 'CORRUPT',
                UPDATED_AT  = SYSTIMESTAMP
            WHERE ARCHIVE_LOG_COPY_ID = p_copy_id;
            COMMIT;
            RAISE_APPLICATION_ERROR(-20005,
                'VERIFY_ARCHIVE_LOG_COPY: チェックサムが NULL のためファイル照合不能。' ||
                'COPY_STATUS を CORRUPT に更新しました。COPY_ID=' || p_copy_id);
        END IF;

        UPDATE ARCHIVE_LOG_COPY
        SET COPY_STATUS    = 'VERIFIED',
            VERIFIED_AT    = SYSTIMESTAMP,
            CHECKSUM_VALUE = p_checksum,
            UPDATED_AT     = SYSTIMESTAMP
        WHERE ARCHIVE_LOG_COPY_ID = p_copy_id;

        SELECT COUNT(*)
        INTO v_unverified_cnt
        FROM ARCHIVE_LOG_COPY
        WHERE ARCHIVE_LOG_ID = v_archive_log_id
          AND COPY_STATUS != 'VERIFIED';

        IF v_unverified_cnt = 0 THEN
            UPDATE ARCHIVE_LOG
            SET COLLECT_STATUS = 'VERIFIED',
                UPDATED_AT     = SYSTIMESTAMP
            WHERE ARCHIVE_LOG_ID = v_archive_log_id
              AND COLLECT_STATUS = 'RECEIVED';
        END IF;

        LOG_STATUS_CHANGE(
            p_run_id     => v_run_id,
            p_table_name => 'ARCHIVE_LOG_COPY',
            p_record_id  => p_copy_id,
            p_old_status => v_copy_status,
            p_new_status => 'VERIFIED',
            p_note       => 'checksum=' || p_checksum ||
                            ',unverified_remaining=' || v_unverified_cnt
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END VERIFY_ARCHIVE_LOG_COPY;

    PROCEDURE LOG_STATUS_CHANGE (
        p_run_id     IN NUMBER,
        p_table_name IN VARCHAR2,
        p_record_id  IN NUMBER,
        p_old_status IN VARCHAR2 DEFAULT NULL,
        p_new_status IN VARCHAR2,
        p_note       IN VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        INSERT INTO MIG_STATUS_HISTORY (
            MIG_RUN_ID, TABLE_NAME, RECORD_ID,
            OLD_STATUS, NEW_STATUS, CHANGED_BY, CHANGED_AT, NOTE
        ) VALUES (
            p_run_id, p_table_name, p_record_id,
            p_old_status, p_new_status, USER, SYSTIMESTAMP, p_note
        );
    EXCEPTION
        WHEN OTHERS THEN
            RAISE;
    END LOG_STATUS_CHANGE;

    PROCEDURE REGISTER_DATAPUMP_FILE (
        p_run_id           IN  NUMBER,
        p_job_id           IN  NUMBER,
        p_file_role        IN  VARCHAR2,
        p_file_name        IN  VARCHAR2,
        p_file_path        IN  VARCHAR2 DEFAULT NULL,
        p_storage_location IN  VARCHAR2 DEFAULT NULL,
        p_file_id          OUT NUMBER
    ) IS
        v_file_id NUMBER;
    BEGIN
        INSERT INTO DATAPUMP_FILE (
            MIG_RUN_ID, DATAPUMP_JOB_ID, FILE_ROLE, STATUS,
            FILE_NAME, FILE_PATH, STORAGE_LOCATION
        ) VALUES (
            p_run_id, p_job_id, p_file_role, 'CREATED',
            p_file_name, p_file_path, p_storage_location
        )
        RETURNING DATAPUMP_FILE_ID INTO v_file_id;

        LOG_STATUS_CHANGE(
            p_run_id     => p_run_id,
            p_table_name => 'DATAPUMP_FILE',
            p_record_id  => v_file_id,
            p_old_status => NULL,
            p_new_status => 'CREATED',
            p_note       => 'REGISTER_DATAPUMP_FILE: ' || p_file_name
        );

        COMMIT;
        p_file_id := v_file_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END REGISTER_DATAPUMP_FILE;

    PROCEDURE VERIFY_DATAPUMP_FILE (
        p_file_id         IN NUMBER,
        p_file_size_bytes IN NUMBER,
        p_checksum_algo   IN VARCHAR2,
        p_checksum_value  IN VARCHAR2
    ) IS
        v_status VARCHAR2(20);
        v_run_id NUMBER;
    BEGIN
        IF p_checksum_value IS NULL THEN
            RAISE_APPLICATION_ERROR(-20005,
                'VERIFY_DATAPUMP_FILE: p_checksum_value が NULL のためファイル照合不能。' ||
                'FILE_ID=' || p_file_id);
        END IF;

        SELECT STATUS, MIG_RUN_ID
        INTO v_status, v_run_id
        FROM DATAPUMP_FILE
        WHERE DATAPUMP_FILE_ID = p_file_id
        FOR UPDATE;

        IF v_status != 'CREATED' THEN
            RAISE_APPLICATION_ERROR(-20002,
                'VERIFY_DATAPUMP_FILE の事前条件エラー: STATUS=' || v_status ||
                '。CREATED 状態のみ VERIFIED へ遷移できます。FILE_ID=' || p_file_id);
        END IF;

        UPDATE DATAPUMP_FILE
        SET STATUS          = 'VERIFIED',
            FILE_SIZE_BYTES = p_file_size_bytes,
            CHECKSUM_ALGO   = p_checksum_algo,
            CHECKSUM_VALUE  = p_checksum_value,
            VERIFIED_AT     = SYSTIMESTAMP,
            UPDATED_AT      = SYSTIMESTAMP
        WHERE DATAPUMP_FILE_ID = p_file_id;

        LOG_STATUS_CHANGE(
            p_run_id     => v_run_id,
            p_table_name => 'DATAPUMP_FILE',
            p_record_id  => p_file_id,
            p_old_status => 'CREATED',
            p_new_status => 'VERIFIED',
            p_note       => 'checksum_algo=' || p_checksum_algo ||
                            ',size=' || NVL(TO_CHAR(p_file_size_bytes), 'NULL')
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END VERIFY_DATAPUMP_FILE;

    PROCEDURE CONSUME_DATAPUMP_FILE (
        p_file_id       IN NUMBER,
        p_import_job_id IN NUMBER
    ) IS
        v_status VARCHAR2(20);
        v_run_id NUMBER;
    BEGIN
        SELECT STATUS, MIG_RUN_ID
        INTO v_status, v_run_id
        FROM DATAPUMP_FILE
        WHERE DATAPUMP_FILE_ID = p_file_id
        FOR UPDATE;

        IF v_status != 'VERIFIED' THEN
            RAISE_APPLICATION_ERROR(-20002,
                'CONSUME_DATAPUMP_FILE の事前条件エラー: STATUS=' || v_status ||
                '。VERIFIED 状態のみ CONSUMED へ遷移できます。FILE_ID=' || p_file_id);
        END IF;

        UPDATE DATAPUMP_FILE
        SET STATUS                    = 'CONSUMED',
            CONSUMED_BY_IMPORT_JOB_ID = p_import_job_id,
            CONSUMED_AT               = SYSTIMESTAMP,
            UPDATED_AT                = SYSTIMESTAMP
        WHERE DATAPUMP_FILE_ID = p_file_id;

        LOG_STATUS_CHANGE(
            p_run_id     => v_run_id,
            p_table_name => 'DATAPUMP_FILE',
            p_record_id  => p_file_id,
            p_old_status => 'VERIFIED',
            p_new_status => 'CONSUMED',
            p_note       => 'import_job_id=' || p_import_job_id
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END CONSUME_DATAPUMP_FILE;

    PROCEDURE START_VALIDATION_RUN (
        p_run_id            IN  NUMBER,
        p_phase_code        IN  VARCHAR2,
        p_validation_type   IN  VARCHAR2,
        p_validation_run_id OUT NUMBER
    ) IS
        v_vrun_id NUMBER;
    BEGIN
        INSERT INTO VALIDATION_RUN (
            MIG_RUN_ID, PHASE_CODE, VALIDATION_TYPE, STATUS, STARTED_AT
        ) VALUES (
            p_run_id, p_phase_code, p_validation_type, 'RUNNING', SYSTIMESTAMP
        )
        RETURNING VALIDATION_RUN_ID INTO v_vrun_id;

        LOG_STATUS_CHANGE(
            p_run_id     => p_run_id,
            p_table_name => 'VALIDATION_RUN',
            p_record_id  => v_vrun_id,
            p_old_status => NULL,
            p_new_status => 'RUNNING',
            p_note       => 'phase=' || p_phase_code ||
                            ',type=' || p_validation_type
        );

        COMMIT;
        p_validation_run_id := v_vrun_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END START_VALIDATION_RUN;

    PROCEDURE COMPLETE_VALIDATION_RUN (
        p_validation_run_id IN NUMBER,
        p_overall_result    IN VARCHAR2
    ) IS
        v_status VARCHAR2(20);
        v_run_id NUMBER;
    BEGIN
        SELECT STATUS, MIG_RUN_ID
        INTO v_status, v_run_id
        FROM VALIDATION_RUN
        WHERE VALIDATION_RUN_ID = p_validation_run_id
        FOR UPDATE;

        IF v_status != 'RUNNING' THEN
            RAISE_APPLICATION_ERROR(-20002,
                'COMPLETE_VALIDATION_RUN の事前条件エラー: STATUS=' || v_status ||
                '。RUNNING 状態のみ COMPLETED へ遷移できます。');
        END IF;

        IF p_overall_result NOT IN ('PASS', 'WARN', 'FAIL') THEN
            RAISE_APPLICATION_ERROR(-20002,
                'COMPLETE_VALIDATION_RUN: p_overall_result の値が不正です: ' ||
                NVL(p_overall_result, 'NULL') ||
                '。PASS / WARN / FAIL のいずれかを指定してください。');
        END IF;

        UPDATE VALIDATION_RUN
        SET STATUS         = 'COMPLETED',
            OVERALL_RESULT = p_overall_result,
            FINISHED_AT    = SYSTIMESTAMP,
            UPDATED_AT     = SYSTIMESTAMP
        WHERE VALIDATION_RUN_ID = p_validation_run_id;

        LOG_STATUS_CHANGE(
            p_run_id     => v_run_id,
            p_table_name => 'VALIDATION_RUN',
            p_record_id  => p_validation_run_id,
            p_old_status => 'RUNNING',
            p_new_status => 'COMPLETED',
            p_note       => 'overall_result=' || p_overall_result
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END COMPLETE_VALIDATION_RUN;

    PROCEDURE RECORD_VALIDATION_RESULT (
        p_validation_run_id IN  NUMBER,
        p_mig_object_id     IN  NUMBER DEFAULT NULL,
        p_check_name        IN  VARCHAR2,
        p_expected_value    IN  VARCHAR2 DEFAULT NULL,
        p_actual_value      IN  VARCHAR2 DEFAULT NULL,
        p_result            IN  VARCHAR2,
        p_result_id         OUT NUMBER
    ) IS
        v_result_id NUMBER;
    BEGIN
        INSERT INTO VALIDATION_RESULT (
            VALIDATION_RUN_ID, MIG_OBJECT_ID, CHECK_NAME,
            EXPECTED_VALUE, ACTUAL_VALUE, RESULT, APPROVED_FLAG
        ) VALUES (
            p_validation_run_id, p_mig_object_id, p_check_name,
            p_expected_value, p_actual_value, p_result, 'N'
        )
        RETURNING VALIDATION_RESULT_ID INTO v_result_id;

        p_result_id := v_result_id;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE;
    END RECORD_VALIDATION_RESULT;

    PROCEDURE RAISE_ERROR_EVENT (
        p_run_id          IN  NUMBER,
        p_phase_code      IN  VARCHAR2 DEFAULT NULL,
        p_severity        IN  VARCHAR2,
        p_component_name  IN  VARCHAR2 DEFAULT NULL,
        p_datapump_job_id IN  NUMBER   DEFAULT NULL,
        p_ora_error_code  IN  VARCHAR2 DEFAULT NULL,
        p_error_message   IN  VARCHAR2 DEFAULT NULL,
        p_event_id        OUT NUMBER
    ) IS
        v_event_id NUMBER;
    BEGIN
        INSERT INTO ERROR_EVENT (
            MIG_RUN_ID, PHASE_CODE, SEVERITY, COMPONENT_NAME,
            DATAPUMP_JOB_ID, ORA_ERROR_CODE, ERROR_MESSAGE, RESOLVE_STATUS
        ) VALUES (
            p_run_id, p_phase_code, p_severity, p_component_name,
            p_datapump_job_id, p_ora_error_code, p_error_message, 'OPEN'
        )
        RETURNING ERROR_EVENT_ID INTO v_event_id;

        COMMIT;
        p_event_id := v_event_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END RAISE_ERROR_EVENT;

    PROCEDURE COMPLETE_PHASE (
        p_run_id     IN NUMBER,
        p_phase_code IN VARCHAR2
    ) IS
        v_cnt        NUMBER;
        v_fail_list  VARCHAR2(4000) := '';
        v_phase_id   NUMBER;
        v_old_status VARCHAR2(20);
    BEGIN
        SELECT PHASE_STATUS_ID, STATUS
        INTO v_phase_id, v_old_status
        FROM PHASE_STATUS
        WHERE MIG_RUN_ID = p_run_id
          AND PHASE_CODE  = p_phase_code
        FOR UPDATE;

        IF p_phase_code = 'PHASE1' THEN
            SELECT COUNT(*) INTO v_cnt
            FROM DATAPUMP_JOB
            WHERE MIG_RUN_ID = p_run_id AND OPERATION = 'EXPORT'
              AND STATUS != 'COMPLETED';
            IF v_cnt > 0 THEN v_fail_list := v_fail_list || 'EXPORT_JOB_NOT_COMPLETED,'; END IF;

            SELECT COUNT(*) INTO v_cnt
            FROM DATAPUMP_JOB_OBJECT djo
            JOIN DATAPUMP_JOB dj ON djo.DATAPUMP_JOB_ID = dj.DATAPUMP_JOB_ID
            WHERE dj.MIG_RUN_ID = p_run_id AND dj.OPERATION = 'EXPORT'
              AND djo.STATUS NOT IN ('COMPLETED', 'SKIPPED');
            IF v_cnt > 0 THEN v_fail_list := v_fail_list || 'EXPORT_JOB_OBJECT_NOT_DONE,'; END IF;

            SELECT COUNT(*) INTO v_cnt
            FROM DATAPUMP_FILE
            WHERE MIG_RUN_ID = p_run_id AND FILE_ROLE = 'DUMP'
              AND STATUS NOT IN ('VERIFIED', 'CONSUMED');
            IF v_cnt > 0 THEN v_fail_list := v_fail_list || 'DUMP_FILE_NOT_VERIFIED,'; END IF;

            SELECT COUNT(*) INTO v_cnt
            FROM DATAPUMP_JOB dj
            JOIN MIGRATION_RUN mr ON dj.MIG_RUN_ID = mr.MIG_RUN_ID
            WHERE dj.MIG_RUN_ID = p_run_id AND dj.OPERATION = 'EXPORT'
              AND (dj.BASELINE_SCN IS NULL OR dj.BASELINE_SCN != mr.BASELINE_SCN);
            IF v_cnt > 0 THEN v_fail_list := v_fail_list || 'BASELINE_SCN_MISMATCH,'; END IF;

            SELECT COUNT(*) INTO v_cnt
            FROM ERROR_EVENT
            WHERE MIG_RUN_ID = p_run_id AND SEVERITY IN ('FATAL', 'ERROR')
              AND RESOLVE_STATUS = 'OPEN';
            IF v_cnt > 0 THEN v_fail_list := v_fail_list || 'OPEN_ERROR_EVENT_EXISTS,'; END IF;

            SELECT COUNT(*) INTO v_cnt
            FROM MIGRATION_OBJECT
            WHERE MIG_RUN_ID = p_run_id AND FULL_LOAD_FLAG = 'Y'
              AND EXPORT_GROUP_CODE IS NULL;
            IF v_cnt > 0 THEN v_fail_list := v_fail_list || 'EXPORT_GROUP_CODE_NOT_SET,'; END IF;

        ELSIF p_phase_code = 'PHASE2' THEN
            SELECT COUNT(*) INTO v_cnt
            FROM DATAPUMP_JOB
            WHERE MIG_RUN_ID = p_run_id AND OPERATION = 'IMPORT'
              AND STATUS != 'COMPLETED';
            IF v_cnt > 0 THEN v_fail_list := v_fail_list || 'IMPORT_JOB_NOT_COMPLETED,'; END IF;

            SELECT COUNT(*) INTO v_cnt
            FROM DATAPUMP_JOB_OBJECT djo
            JOIN DATAPUMP_JOB dj ON djo.DATAPUMP_JOB_ID = dj.DATAPUMP_JOB_ID
            WHERE dj.MIG_RUN_ID = p_run_id AND dj.OPERATION = 'IMPORT'
              AND djo.STATUS NOT IN ('COMPLETED', 'SKIPPED');
            IF v_cnt > 0 THEN v_fail_list := v_fail_list || 'IMPORT_JOB_OBJECT_NOT_DONE,'; END IF;

            SELECT COUNT(*) INTO v_cnt
            FROM DATAPUMP_FILE
            WHERE MIG_RUN_ID = p_run_id AND FILE_ROLE = 'DUMP'
              AND TARGET_VERIFIED_AT IS NULL;
            IF v_cnt > 0 THEN v_fail_list := v_fail_list || 'DUMP_FILE_NOT_TARGET_VERIFIED,'; END IF;

            SELECT COUNT(*) INTO v_cnt
            FROM VALIDATION_RUN
            WHERE MIG_RUN_ID = p_run_id AND PHASE_CODE = 'PHASE2'
              AND STATUS = 'COMPLETED' AND OVERALL_RESULT = 'PASS';
            IF v_cnt = 0 THEN v_fail_list := v_fail_list || 'NO_PASS_VALIDATION_RUN,'; END IF;

            SELECT COUNT(*) INTO v_cnt
            FROM VALIDATION_RESULT vr
            JOIN VALIDATION_RUN vrun ON vr.VALIDATION_RUN_ID = vrun.VALIDATION_RUN_ID
            WHERE vrun.MIG_RUN_ID = p_run_id AND vrun.PHASE_CODE = 'PHASE2'
              AND vr.RESULT = 'FAIL' AND vr.APPROVED_FLAG = 'N';
            IF v_cnt > 0 THEN v_fail_list := v_fail_list || 'UNAPPROVED_FAIL_RESULT_EXISTS,'; END IF;

            SELECT COUNT(*) INTO v_cnt
            FROM ERROR_EVENT
            WHERE MIG_RUN_ID = p_run_id AND SEVERITY IN ('FATAL', 'ERROR')
              AND RESOLVE_STATUS = 'OPEN';
            IF v_cnt > 0 THEN v_fail_list := v_fail_list || 'OPEN_ERROR_EVENT_EXISTS,'; END IF;

        ELSE
            RAISE_APPLICATION_ERROR(-20010,
                'COMPLETE_PHASE: 未対応の PHASE_CODE=' || p_phase_code ||
                '。PHASE1 または PHASE2 を指定してください。');
        END IF;

        IF v_fail_list IS NOT NULL THEN
            v_fail_list := RTRIM(v_fail_list, ',');
            RAISE_APPLICATION_ERROR(-20010,
                'COMPLETE_PHASE(' || p_phase_code || '): 完了条件未達 [' ||
                v_fail_list || ']');
        END IF;

        UPDATE PHASE_STATUS
        SET STATUS      = 'COMPLETED',
            FINISHED_AT = SYSTIMESTAMP,
            UPDATED_AT  = SYSTIMESTAMP
        WHERE PHASE_STATUS_ID = v_phase_id;

        LOG_STATUS_CHANGE(
            p_run_id     => p_run_id,
            p_table_name => 'PHASE_STATUS',
            p_record_id  => v_phase_id,
            p_old_status => v_old_status,
            p_new_status => 'COMPLETED',
            p_note       => 'COMPLETE_PHASE: ' || p_phase_code
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END COMPLETE_PHASE;

    PROCEDURE REGISTER_ARCHIVE_LOG (
        p_run_id         IN  NUMBER,
        p_dbid           IN  NUMBER,
        p_resetlogs_id   IN  NUMBER,
        p_thread_no      IN  NUMBER,
        p_seq_no         IN  NUMBER,
        p_first_scn      IN  NUMBER,
        p_next_scn       IN  NUMBER,
        p_first_time     IN  TIMESTAMP DEFAULT NULL,
        p_next_time      IN  TIMESTAMP DEFAULT NULL,
        p_archive_log_id OUT NUMBER
    ) IS
        v_cnt NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_cnt
        FROM   ARCHIVE_LOG
        WHERE  MIG_RUN_ID          = p_run_id
        AND    SOURCE_RESETLOGS_ID = p_resetlogs_id
        AND    THREAD_NO           = p_thread_no
        AND    SEQUENCE_NO         = p_seq_no;

        IF v_cnt > 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
                'ARCHIVE_LOG already registered: thread=' || p_thread_no ||
                ' seq=' || p_seq_no);
        END IF;

        INSERT INTO ARCHIVE_LOG (
            ARCHIVE_LOG_ID, MIG_RUN_ID, SOURCE_DBID, SOURCE_RESETLOGS_ID,
            THREAD_NO, SEQUENCE_NO, FIRST_CHANGE_SCN, NEXT_CHANGE_SCN,
            FIRST_TIME, NEXT_TIME, COLLECT_STATUS
        ) VALUES (
            SEQ_ARCHIVE_LOG.NEXTVAL, p_run_id, p_dbid, p_resetlogs_id,
            p_thread_no, p_seq_no, p_first_scn, p_next_scn,
            p_first_time, p_next_time, 'EXPECTED'
        ) RETURNING ARCHIVE_LOG_ID INTO p_archive_log_id;

        LOG_STATUS_CHANGE(p_run_id, 'ARCHIVE_LOG', p_archive_log_id,
            NULL, 'EXPECTED',
            'thread=' || p_thread_no || ' seq=' || p_seq_no);
        COMMIT;
    END REGISTER_ARCHIVE_LOG;

    PROCEDURE RECEIVE_ARCHIVE_LOG (
        p_archive_log_id IN NUMBER
    ) IS
        v_status VARCHAR2(20);
        v_run_id NUMBER;
    BEGIN
        SELECT COLLECT_STATUS, MIG_RUN_ID INTO v_status, v_run_id
        FROM   ARCHIVE_LOG WHERE ARCHIVE_LOG_ID = p_archive_log_id;

        IF v_status <> 'EXPECTED' THEN
            RAISE_APPLICATION_ERROR(-20002,
                'RECEIVE_ARCHIVE_LOG requires COLLECT_STATUS=EXPECTED but was ' || v_status);
        END IF;

        UPDATE ARCHIVE_LOG
        SET    COLLECT_STATUS = 'RECEIVED',
               UPDATED_AT     = SYSTIMESTAMP
        WHERE  ARCHIVE_LOG_ID = p_archive_log_id;

        LOG_STATUS_CHANGE(v_run_id, 'ARCHIVE_LOG', p_archive_log_id,
            'EXPECTED', 'RECEIVED', NULL);
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'ARCHIVE_LOG not found: id=' || p_archive_log_id);
    END RECEIVE_ARCHIVE_LOG;

    PROCEDURE REGISTER_ARCHIVE_LOG_COPY (
        p_archive_log_id IN  NUMBER,
        p_storage_loc    IN  VARCHAR2,
        p_file_path      IN  VARCHAR2,
        p_file_size      IN  NUMBER,
        p_checksum_algo  IN  VARCHAR2,
        p_checksum_val   IN  VARCHAR2,
        p_copy_id        OUT NUMBER
    ) IS
        v_run_id NUMBER;
    BEGIN
        SELECT MIG_RUN_ID INTO v_run_id
        FROM   ARCHIVE_LOG WHERE ARCHIVE_LOG_ID = p_archive_log_id;

        INSERT INTO ARCHIVE_LOG_COPY (
            ARCHIVE_LOG_COPY_ID, ARCHIVE_LOG_ID, MIG_RUN_ID,
            STORAGE_LOCATION, FILE_PATH, FILE_SIZE_BYTES,
            CHECKSUM_ALGO, CHECKSUM_VALUE, COPY_STATUS, RECEIVED_AT
        ) VALUES (
            SEQ_ARCHIVE_LOG_COPY.NEXTVAL, p_archive_log_id, v_run_id,
            p_storage_loc, p_file_path, p_file_size,
            p_checksum_algo, p_checksum_val, 'RECEIVED', SYSTIMESTAMP
        ) RETURNING ARCHIVE_LOG_COPY_ID INTO p_copy_id;

        LOG_STATUS_CHANGE(v_run_id, 'ARCHIVE_LOG_COPY', p_copy_id,
            NULL, 'RECEIVED', p_storage_loc);
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'ARCHIVE_LOG not found: id=' || p_archive_log_id);
    END REGISTER_ARCHIVE_LOG_COPY;

    PROCEDURE SET_DICT_MARKERS (
        p_archive_log_id IN NUMBER,
        p_dict_begin     IN CHAR,
        p_dict_end       IN CHAR
    ) IS
        v_run_id NUMBER;
    BEGIN
        IF p_dict_begin NOT IN ('Y','N') OR p_dict_end NOT IN ('Y','N') THEN
            RAISE_APPLICATION_ERROR(-20002,
                'SET_DICT_MARKERS accepts only Y or N');
        END IF;

        SELECT MIG_RUN_ID INTO v_run_id
        FROM   ARCHIVE_LOG WHERE ARCHIVE_LOG_ID = p_archive_log_id;

        UPDATE ARCHIVE_LOG
        SET    DICTIONARY_BEGIN_FLAG = p_dict_begin,
               DICTIONARY_END_FLAG   = p_dict_end,
               UPDATED_AT            = SYSTIMESTAMP
        WHERE  ARCHIVE_LOG_ID = p_archive_log_id;

        LOG_STATUS_CHANGE(v_run_id, 'ARCHIVE_LOG', p_archive_log_id,
            NULL, 'DICT_MARKED',
            'begin=' || p_dict_begin || ' end=' || p_dict_end);
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'ARCHIVE_LOG not found: id=' || p_archive_log_id);
    END SET_DICT_MARKERS;

    PROCEDURE UPSERT_CHECKPOINT (
        p_run_id    IN NUMBER,
        p_component IN VARCHAR2,
        p_key       IN VARCHAR2,
        p_thread_no IN NUMBER,
        p_seq_no    IN NUMBER,
        p_scn       IN NUMBER
    ) IS
    BEGIN
        MERGE INTO MIG_CHECKPOINT dst
        USING (
            SELECT p_run_id    AS MIG_RUN_ID,
                   p_component AS COMPONENT_NAME,
                   p_key       AS CHECKPOINT_KEY
            FROM DUAL
        ) src
        ON (    dst.MIG_RUN_ID     = src.MIG_RUN_ID
            AND dst.COMPONENT_NAME = src.COMPONENT_NAME
            AND dst.CHECKPOINT_KEY = src.CHECKPOINT_KEY)
        WHEN MATCHED THEN
            UPDATE SET
                dst.THREAD_NO      = p_thread_no,
                dst.SEQUENCE_NO    = p_seq_no,
                dst.CHECKPOINT_SCN = p_scn,
                dst.UPDATED_AT     = SYSTIMESTAMP
        WHEN NOT MATCHED THEN
            INSERT (
                MIG_CHECKPOINT_ID, MIG_RUN_ID, COMPONENT_NAME,
                CHECKPOINT_KEY, THREAD_NO, SEQUENCE_NO,
                CHECKPOINT_SCN, CREATED_AT
            )
            VALUES (
                SEQ_MIG_CHECKPOINT.NEXTVAL, p_run_id, p_component,
                p_key, p_thread_no, p_seq_no, p_scn, SYSTIMESTAMP
            );
        COMMIT;
    END UPSERT_CHECKPOINT;

    PROCEDURE COMPLETE_PHASE3 (
        p_run_id IN NUMBER
    ) IS
        v_mining_scn      NUMBER;
        v_target_scn      NUMBER;
        v_err_cnt         NUMBER;
        v_behind_cnt      NUMBER;
        v_cp_cnt          NUMBER;
        v_missing_cnt     NUMBER;
        v_old_status      VARCHAR2(20);
        v_phase_status_id NUMBER;
    BEGIN
        SELECT MINING_START_SCN, TARGET_END_SCN
        INTO   v_mining_scn, v_target_scn
        FROM   MIGRATION_RUN WHERE MIG_RUN_ID = p_run_id;

        IF v_mining_scn IS NULL THEN
            RAISE_APPLICATION_ERROR(-20011,
                'PHASE3 incomplete: MINING_START_SCN not set');
        END IF;

        IF v_target_scn IS NULL THEN
            RAISE_APPLICATION_ERROR(-20011,
                'PHASE3 incomplete: TARGET_END_SCN not set');
        END IF;

        SELECT COUNT(*) INTO v_err_cnt
        FROM   ERROR_EVENT
        WHERE  MIG_RUN_ID     = p_run_id
        AND    RESOLVE_STATUS = 'OPEN'
        AND    SEVERITY IN ('FATAL','ERROR');
        IF v_err_cnt > 0 THEN
            RAISE_APPLICATION_ERROR(-20011,
                'PHASE3 incomplete: Unresolved FATAL/ERROR events exist (' ||
                v_err_cnt || ')');
        END IF;

        SELECT COUNT(*) INTO v_cp_cnt
        FROM   MIG_CHECKPOINT
        WHERE  MIG_RUN_ID     = p_run_id
        AND    COMPONENT_NAME = 'ARCHIVE_COLLECTOR';
        IF v_cp_cnt = 0 THEN
            RAISE_APPLICATION_ERROR(-20011,
                'PHASE3 incomplete: no ARCHIVE_COLLECTOR checkpoint');
        END IF;

        SELECT COUNT(*) INTO v_behind_cnt
        FROM   MIG_CHECKPOINT
        WHERE  MIG_RUN_ID     = p_run_id
        AND    COMPONENT_NAME = 'ARCHIVE_COLLECTOR'
        AND    (CHECKPOINT_SCN IS NULL OR CHECKPOINT_SCN < v_target_scn);
        IF v_behind_cnt > 0 THEN
            RAISE_APPLICATION_ERROR(-20011,
                'PHASE3 incomplete: ARCHIVE_COLLECTOR checkpoint not reached ' ||
                'TARGET_END_SCN (' || v_behind_cnt || ' thread(s) behind)');
        END IF;

        SELECT COUNT(*) INTO v_missing_cnt
        FROM   ARCHIVE_LOG
        WHERE  MIG_RUN_ID     = p_run_id
        AND    COLLECT_STATUS = 'MISSING';
        IF v_missing_cnt > 0 THEN
            RAISE_APPLICATION_ERROR(-20011,
                'PHASE3 incomplete: Missing archive logs exist (' ||
                v_missing_cnt || ')');
        END IF;

        SELECT PHASE_STATUS_ID, STATUS
        INTO   v_phase_status_id, v_old_status
        FROM   PHASE_STATUS
        WHERE  MIG_RUN_ID = p_run_id AND PHASE_CODE = 'PHASE3';

        UPDATE PHASE_STATUS
        SET    STATUS      = 'COMPLETED',
               FINISHED_AT = SYSTIMESTAMP,
               UPDATED_AT  = SYSTIMESTAMP
        WHERE  MIG_RUN_ID = p_run_id AND PHASE_CODE = 'PHASE3';

        LOG_STATUS_CHANGE(p_run_id, 'PHASE_STATUS', v_phase_status_id,
            v_old_status, 'COMPLETED', 'PHASE3 all conditions satisfied');
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            ROLLBACK;
            RAISE_APPLICATION_ERROR(-20011,
                'PHASE3 incomplete: MIGRATION_RUN or PHASE_STATUS not found');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END COMPLETE_PHASE3;

    -- =========================================================================
    -- v5.0 追加 API 実装（フェーズ4）
    -- =========================================================================

    -- -------------------------------------------------------------------------
    -- REGISTER_LOGMINER_BATCH: STATUS='PLANNED' で INSERT
    -- -------------------------------------------------------------------------
    PROCEDURE REGISTER_LOGMINER_BATCH (
        p_run_id         IN  NUMBER,
        p_batch_no       IN  NUMBER,
        p_from_scn       IN  NUMBER,
        p_to_scn         IN  NUMBER,
        p_dict_method    IN  VARCHAR2,
        p_logmnr_options IN  VARCHAR2 DEFAULT NULL,
        p_batch_id       OUT NUMBER
    ) IS
        v_cnt    NUMBER;
        v_new_id NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_cnt
        FROM   LOGMINER_BATCH
        WHERE  MIG_RUN_ID = p_run_id AND BATCH_NO = p_batch_no;

        IF v_cnt > 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
                'REGISTER_LOGMINER_BATCH: (MIG_RUN_ID, BATCH_NO) already exists: ' ||
                p_run_id || ',' || p_batch_no);
        END IF;

        INSERT INTO LOGMINER_BATCH (
            LOGMINER_BATCH_ID, MIG_RUN_ID, BATCH_NO,
            FROM_SCN, TO_SCN, DICT_METHOD, LOGMNR_OPTIONS,
            STATUS, CREATED_AT
        ) VALUES (
            SEQ_LOGMINER_BATCH.NEXTVAL, p_run_id, p_batch_no,
            p_from_scn, p_to_scn, p_dict_method, p_logmnr_options,
            'PLANNED', SYSTIMESTAMP
        ) RETURNING LOGMINER_BATCH_ID INTO v_new_id;

        LOG_STATUS_CHANGE(p_run_id, 'LOGMINER_BATCH', v_new_id,
            NULL, 'PLANNED',
            'batch_no=' || p_batch_no ||
            ' scn=' || p_from_scn || '-' || p_to_scn);
        COMMIT;
        p_batch_id := v_new_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END REGISTER_LOGMINER_BATCH;

    -- -------------------------------------------------------------------------
    -- BEGIN_LOGMINER_BATCH: PLANNED/RETRY → RUNNING
    -- -------------------------------------------------------------------------
    PROCEDURE BEGIN_LOGMINER_BATCH (p_batch_id IN NUMBER) IS
        v_status VARCHAR2(20);
        v_run_id NUMBER;
    BEGIN
        SELECT STATUS, MIG_RUN_ID INTO v_status, v_run_id
        FROM   LOGMINER_BATCH
        WHERE  LOGMINER_BATCH_ID = p_batch_id
        FOR UPDATE;

        IF v_status NOT IN ('PLANNED','RETRY') THEN
            RAISE_APPLICATION_ERROR(-20012,
                'BEGIN_LOGMINER_BATCH: invalid state transition. ' ||
                'Expected PLANNED or RETRY but was ' || v_status);
        END IF;

        UPDATE LOGMINER_BATCH
        SET    STATUS     = 'RUNNING',
               STARTED_AT = SYSTIMESTAMP,
               UPDATED_AT = SYSTIMESTAMP
        WHERE  LOGMINER_BATCH_ID = p_batch_id;

        LOG_STATUS_CHANGE(v_run_id, 'LOGMINER_BATCH', p_batch_id,
            v_status, 'RUNNING', NULL);
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'LOGMINER_BATCH not found: id=' || p_batch_id);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END BEGIN_LOGMINER_BATCH;

    -- -------------------------------------------------------------------------
    -- COMPLETE_LOGMINER_BATCH: RUNNING → COMPLETED
    -- -------------------------------------------------------------------------
    PROCEDURE COMPLETE_LOGMINER_BATCH (
        p_batch_id     IN NUMBER,
        p_change_count IN NUMBER DEFAULT NULL,
        p_tx_count     IN NUMBER DEFAULT NULL
    ) IS
        v_status VARCHAR2(20);
        v_run_id NUMBER;
    BEGIN
        SELECT STATUS, MIG_RUN_ID INTO v_status, v_run_id
        FROM   LOGMINER_BATCH
        WHERE  LOGMINER_BATCH_ID = p_batch_id
        FOR UPDATE;

        IF v_status != 'RUNNING' THEN
            RAISE_APPLICATION_ERROR(-20012,
                'COMPLETE_LOGMINER_BATCH: invalid state transition. ' ||
                'Expected RUNNING but was ' || v_status);
        END IF;

        UPDATE LOGMINER_BATCH
        SET    STATUS            = 'COMPLETED',
               CHANGE_COUNT      = p_change_count,
               TRANSACTION_COUNT = p_tx_count,
               FINISHED_AT       = SYSTIMESTAMP,
               UPDATED_AT        = SYSTIMESTAMP
        WHERE  LOGMINER_BATCH_ID = p_batch_id;

        LOG_STATUS_CHANGE(v_run_id, 'LOGMINER_BATCH', p_batch_id,
            'RUNNING', 'COMPLETED',
            'change_count=' || NVL(TO_CHAR(p_change_count), 'NULL') ||
            ' tx_count=' || NVL(TO_CHAR(p_tx_count), 'NULL'));
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'LOGMINER_BATCH not found: id=' || p_batch_id);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END COMPLETE_LOGMINER_BATCH;

    -- -------------------------------------------------------------------------
    -- FAIL_LOGMINER_BATCH: → FAILED（状態チェックなし）
    -- -------------------------------------------------------------------------
    PROCEDURE FAIL_LOGMINER_BATCH (
        p_batch_id  IN NUMBER,
        p_error_msg IN VARCHAR2 DEFAULT NULL
    ) IS
        v_status VARCHAR2(20);
        v_run_id NUMBER;
    BEGIN
        SELECT STATUS, MIG_RUN_ID INTO v_status, v_run_id
        FROM   LOGMINER_BATCH
        WHERE  LOGMINER_BATCH_ID = p_batch_id;

        UPDATE LOGMINER_BATCH
        SET    STATUS        = 'FAILED',
               ERROR_MESSAGE = p_error_msg,
               FINISHED_AT   = SYSTIMESTAMP,
               UPDATED_AT    = SYSTIMESTAMP
        WHERE  LOGMINER_BATCH_ID = p_batch_id;

        LOG_STATUS_CHANGE(v_run_id, 'LOGMINER_BATCH', p_batch_id,
            v_status, 'FAILED', p_error_msg);
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'LOGMINER_BATCH not found: id=' || p_batch_id);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END FAIL_LOGMINER_BATCH;

    -- -------------------------------------------------------------------------
    -- ADD_BATCH_LOG: LOGMINER_BATCH_LOG に1行追加
    -- -------------------------------------------------------------------------
    PROCEDURE ADD_BATCH_LOG (
        p_batch_id       IN NUMBER,
        p_archive_log_id IN NUMBER,
        p_add_order      IN NUMBER
    ) IS
        v_cnt    NUMBER;
        v_new_id NUMBER;
        v_run_id NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_cnt
        FROM   LOGMINER_BATCH_LOG
        WHERE  LOGMINER_BATCH_ID = p_batch_id
        AND    ARCHIVE_LOG_ID    = p_archive_log_id;

        IF v_cnt > 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
                'ADD_BATCH_LOG: (LOGMINER_BATCH_ID, ARCHIVE_LOG_ID) already exists');
        END IF;

        SELECT MIG_RUN_ID INTO v_run_id
        FROM   LOGMINER_BATCH WHERE LOGMINER_BATCH_ID = p_batch_id;

        INSERT INTO LOGMINER_BATCH_LOG (
            BATCH_LOG_ID, LOGMINER_BATCH_ID, ARCHIVE_LOG_ID, ADD_ORDER, CREATED_AT
        ) VALUES (
            SEQ_LOGMINER_BATCH_LOG.NEXTVAL, p_batch_id, p_archive_log_id,
            p_add_order, SYSTIMESTAMP
        ) RETURNING BATCH_LOG_ID INTO v_new_id;

        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'LOGMINER_BATCH not found: id=' || p_batch_id);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END ADD_BATCH_LOG;

    -- -------------------------------------------------------------------------
    -- SET_MINING_STATUS: ARCHIVE_LOG.MINING_STATUS を更新
    -- -------------------------------------------------------------------------
    PROCEDURE SET_MINING_STATUS (
        p_archive_log_id IN NUMBER,
        p_mining_status  IN VARCHAR2
    ) IS
        v_old_status  ARCHIVE_LOG.MINING_STATUS%TYPE;
        v_run_id      ARCHIVE_LOG.MIG_RUN_ID%TYPE;
    BEGIN
        SELECT MIG_RUN_ID, MINING_STATUS
          INTO v_run_id, v_old_status
          FROM ARCHIVE_LOG
         WHERE ARCHIVE_LOG_ID = p_archive_log_id;

        UPDATE ARCHIVE_LOG
           SET MINING_STATUS = p_mining_status,
               UPDATED_AT    = SYSTIMESTAMP
         WHERE ARCHIVE_LOG_ID = p_archive_log_id;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
                'ARCHIVE_LOG not found: id=' || p_archive_log_id);
        END IF;

        LOG_STATUS_CHANGE(
            p_run_id     => v_run_id,
            p_table_name => 'ARCHIVE_LOG',
            p_record_id  => p_archive_log_id,
            p_old_status => v_old_status,
            p_new_status => p_mining_status,
            p_note       => 'MINING_STATUS'
        );

        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'SET_MINING_STATUS: ARCHIVE_LOG not found: id=' || p_archive_log_id);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END SET_MINING_STATUS;

    -- -------------------------------------------------------------------------
    -- SET_APPLY_STATUS: ARCHIVE_LOG.APPLY_STATUS を更新
    -- -------------------------------------------------------------------------
    PROCEDURE SET_APPLY_STATUS (
        p_archive_log_id IN NUMBER,
        p_apply_status   IN VARCHAR2
    ) IS
        v_old_status  ARCHIVE_LOG.APPLY_STATUS%TYPE;
        v_run_id      ARCHIVE_LOG.MIG_RUN_ID%TYPE;
    BEGIN
        SELECT MIG_RUN_ID, APPLY_STATUS
          INTO v_run_id, v_old_status
          FROM ARCHIVE_LOG
         WHERE ARCHIVE_LOG_ID = p_archive_log_id;

        UPDATE ARCHIVE_LOG
           SET APPLY_STATUS = p_apply_status,
               UPDATED_AT   = SYSTIMESTAMP
         WHERE ARCHIVE_LOG_ID = p_archive_log_id;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
                'ARCHIVE_LOG not found: id=' || p_archive_log_id);
        END IF;

        LOG_STATUS_CHANGE(
            p_run_id     => v_run_id,
            p_table_name => 'ARCHIVE_LOG',
            p_record_id  => p_archive_log_id,
            p_old_status => v_old_status,
            p_new_status => p_apply_status,
            p_note       => 'APPLY_STATUS'
        );

        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'SET_APPLY_STATUS: ARCHIVE_LOG not found: id=' || p_archive_log_id);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END SET_APPLY_STATUS;

    -- -------------------------------------------------------------------------
    -- BULK_INS_MINED_TX: MINED_TRANSACTION を FORALL バルク INSERT
    -- UQ違反は SAVE EXCEPTIONS で集積してエラー件数を RAISE する
    -- -------------------------------------------------------------------------
    PROCEDURE BULK_INS_MINED_TX (p_rows IN T_MINED_TX_TBL) IS
        e_forall_errors EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_forall_errors, -24381);
        v_err_cnt NUMBER;
    BEGIN
        IF p_rows.COUNT = 0 THEN
            RETURN;
        END IF;

        FORALL i IN 1..p_rows.COUNT SAVE EXCEPTIONS
            INSERT INTO MINED_TRANSACTION (
                MINED_TRANSACTION_ID, MIG_RUN_ID, LOGMINER_BATCH_ID,
                XID, START_SCN, COMMIT_SCN, CHANGE_COUNT,
                STATUS, CREATED_AT
            ) VALUES (
                SEQ_MINED_TRANSACTION.NEXTVAL,
                p_rows(i).MIG_RUN_ID,
                p_rows(i).LOGMINER_BATCH_ID,
                p_rows(i).XID,
                p_rows(i).START_SCN,
                p_rows(i).COMMIT_SCN,
                p_rows(i).CHANGE_COUNT,
                'MINED',
                SYSTIMESTAMP
            );

        COMMIT;
    EXCEPTION
        WHEN e_forall_errors THEN
            ROLLBACK;
            v_err_cnt := SQL%BULK_EXCEPTIONS.COUNT;
            RAISE_APPLICATION_ERROR(-20002,
                'BULK_INS_MINED_TX: ' || v_err_cnt ||
                ' row(s) failed (UQ or constraint violation)');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END BULK_INS_MINED_TX;

    -- -------------------------------------------------------------------------
    -- BULK_INS_MINED_CHG: MINED_CHANGE を FORALL バルク INSERT
    -- SQL_REDO/SQL_UNDO（CLOB）は NULL で登録（後続処理で個別 CLOB 更新）
    -- -------------------------------------------------------------------------
    PROCEDURE BULK_INS_MINED_CHG (p_rows IN T_MINED_CHG_TBL) IS
        e_forall_errors EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_forall_errors, -24381);
        v_err_cnt NUMBER;
    BEGIN
        IF p_rows.COUNT = 0 THEN
            RETURN;
        END IF;

        FORALL i IN 1..p_rows.COUNT SAVE EXCEPTIONS
            INSERT INTO MINED_CHANGE (
                MINED_CHANGE_ID, MIG_RUN_ID, MINED_TRANSACTION_ID,
                LOGMINER_BATCH_ID, RS_ID, SSN, SCN, COMMIT_SCN,
                OPERATION, SEG_OWNER, TABLE_NAME, CSF,
                SQL_REDO, SQL_UNDO, STATUS, CREATED_AT
            ) VALUES (
                SEQ_MINED_CHANGE.NEXTVAL,
                p_rows(i).MIG_RUN_ID,
                p_rows(i).MINED_TRANSACTION_ID,
                p_rows(i).LOGMINER_BATCH_ID,
                p_rows(i).RS_ID,
                p_rows(i).SSN,
                p_rows(i).SCN,
                p_rows(i).COMMIT_SCN,
                p_rows(i).OPERATION,
                p_rows(i).SEG_OWNER,
                p_rows(i).TABLE_NAME,
                p_rows(i).CSF,
                NULL,
                NULL,
                'MINED',
                SYSTIMESTAMP
            );

        COMMIT;
    EXCEPTION
        WHEN e_forall_errors THEN
            ROLLBACK;
            v_err_cnt := SQL%BULK_EXCEPTIONS.COUNT;
            RAISE_APPLICATION_ERROR(-20002,
                'BULK_INS_MINED_CHG: ' || v_err_cnt ||
                ' row(s) failed (UQ or constraint violation)');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END BULK_INS_MINED_CHG;

    -- -------------------------------------------------------------------------
    -- REGISTER_APPLY_BATCH: STATUS='PLANNED' で INSERT
    -- -------------------------------------------------------------------------
    PROCEDURE REGISTER_APPLY_BATCH (
        p_run_id          IN  NUMBER,
        p_batch_no        IN  NUMBER,
        p_from_commit_scn IN  NUMBER,
        p_to_commit_scn   IN  NUMBER,
        p_batch_id        OUT NUMBER
    ) IS
        v_cnt    NUMBER;
        v_new_id NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_cnt
        FROM   APPLY_BATCH
        WHERE  MIG_RUN_ID = p_run_id AND BATCH_NO = p_batch_no;

        IF v_cnt > 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
                'REGISTER_APPLY_BATCH: (MIG_RUN_ID, BATCH_NO) already exists: ' ||
                p_run_id || ',' || p_batch_no);
        END IF;

        INSERT INTO APPLY_BATCH (
            APPLY_BATCH_ID, MIG_RUN_ID, BATCH_NO,
            FROM_COMMIT_SCN, TO_COMMIT_SCN, STATUS, CREATED_AT
        ) VALUES (
            SEQ_APPLY_BATCH.NEXTVAL, p_run_id, p_batch_no,
            p_from_commit_scn, p_to_commit_scn, 'PLANNED', SYSTIMESTAMP
        ) RETURNING APPLY_BATCH_ID INTO v_new_id;

        LOG_STATUS_CHANGE(p_run_id, 'APPLY_BATCH', v_new_id,
            NULL, 'PLANNED',
            'batch_no=' || p_batch_no ||
            ' scn=' || p_from_commit_scn || '-' || p_to_commit_scn);
        COMMIT;
        p_batch_id := v_new_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END REGISTER_APPLY_BATCH;

    -- -------------------------------------------------------------------------
    -- BEGIN_APPLY_BATCH: PLANNED/RETRY → RUNNING
    -- -------------------------------------------------------------------------
    PROCEDURE BEGIN_APPLY_BATCH (p_batch_id IN NUMBER) IS
        v_status VARCHAR2(20);
        v_run_id NUMBER;
    BEGIN
        SELECT STATUS, MIG_RUN_ID INTO v_status, v_run_id
        FROM   APPLY_BATCH
        WHERE  APPLY_BATCH_ID = p_batch_id
        FOR UPDATE;

        IF v_status NOT IN ('PLANNED','RETRY') THEN
            RAISE_APPLICATION_ERROR(-20012,
                'BEGIN_APPLY_BATCH: invalid state transition. ' ||
                'Expected PLANNED or RETRY but was ' || v_status);
        END IF;

        UPDATE APPLY_BATCH
        SET    STATUS     = 'RUNNING',
               STARTED_AT = SYSTIMESTAMP,
               UPDATED_AT = SYSTIMESTAMP
        WHERE  APPLY_BATCH_ID = p_batch_id;

        LOG_STATUS_CHANGE(v_run_id, 'APPLY_BATCH', p_batch_id,
            v_status, 'RUNNING', NULL);
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'APPLY_BATCH not found: id=' || p_batch_id);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END BEGIN_APPLY_BATCH;

    -- -------------------------------------------------------------------------
    -- COMPLETE_APPLY_BATCH: RUNNING → COMPLETED
    -- -------------------------------------------------------------------------
    PROCEDURE COMPLETE_APPLY_BATCH (
        p_batch_id IN NUMBER,
        p_applied  IN NUMBER DEFAULT 0,
        p_skipped  IN NUMBER DEFAULT 0,
        p_errors   IN NUMBER DEFAULT 0
    ) IS
        v_status VARCHAR2(20);
        v_run_id NUMBER;
    BEGIN
        SELECT STATUS, MIG_RUN_ID INTO v_status, v_run_id
        FROM   APPLY_BATCH
        WHERE  APPLY_BATCH_ID = p_batch_id
        FOR UPDATE;

        IF v_status != 'RUNNING' THEN
            RAISE_APPLICATION_ERROR(-20012,
                'COMPLETE_APPLY_BATCH: invalid state transition. ' ||
                'Expected RUNNING but was ' || v_status);
        END IF;

        UPDATE APPLY_BATCH
        SET    STATUS        = 'COMPLETED',
               APPLIED_COUNT = p_applied,
               SKIPPED_COUNT = p_skipped,
               ERROR_COUNT   = p_errors,
               FINISHED_AT   = SYSTIMESTAMP,
               UPDATED_AT    = SYSTIMESTAMP
        WHERE  APPLY_BATCH_ID = p_batch_id;

        LOG_STATUS_CHANGE(v_run_id, 'APPLY_BATCH', p_batch_id,
            'RUNNING', 'COMPLETED',
            'applied=' || p_applied ||
            ' skipped=' || p_skipped ||
            ' errors=' || p_errors);
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'APPLY_BATCH not found: id=' || p_batch_id);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END COMPLETE_APPLY_BATCH;

    -- -------------------------------------------------------------------------
    -- FAIL_APPLY_BATCH: → FAILED（状態チェックなし）
    -- -------------------------------------------------------------------------
    PROCEDURE FAIL_APPLY_BATCH (
        p_batch_id  IN NUMBER,
        p_error_msg IN VARCHAR2 DEFAULT NULL
    ) IS
        v_status VARCHAR2(20);
        v_run_id NUMBER;
    BEGIN
        SELECT STATUS, MIG_RUN_ID INTO v_status, v_run_id
        FROM   APPLY_BATCH
        WHERE  APPLY_BATCH_ID = p_batch_id;

        UPDATE APPLY_BATCH
        SET    STATUS        = 'FAILED',
               ERROR_MESSAGE = p_error_msg,
               FINISHED_AT   = SYSTIMESTAMP,
               UPDATED_AT    = SYSTIMESTAMP
        WHERE  APPLY_BATCH_ID = p_batch_id;

        LOG_STATUS_CHANGE(v_run_id, 'APPLY_BATCH', p_batch_id,
            v_status, 'FAILED', p_error_msg);
        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'APPLY_BATCH not found: id=' || p_batch_id);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END FAIL_APPLY_BATCH;

    -- -------------------------------------------------------------------------
    -- QUEUE_APPLY_TASK: APPLY_TASK を STATUS='PENDING' で1件登録
    -- APPLY_BATCH から MIG_RUN_ID を取得してINSERT
    -- -------------------------------------------------------------------------
    PROCEDURE QUEUE_APPLY_TASK (
        p_batch_id        IN  NUMBER,
        p_mined_change_id IN  NUMBER,
        p_seg_owner       IN  VARCHAR2,
        p_table_name      IN  VARCHAR2,
        p_dml_type        IN  VARCHAR2,
        p_key_payload     IN  VARCHAR2 DEFAULT NULL,
        p_dml_text        IN  VARCHAR2 DEFAULT NULL,
        p_task_id         OUT NUMBER
    ) IS
        v_run_id NUMBER;
        v_new_id NUMBER;
    BEGIN
        SELECT MIG_RUN_ID INTO v_run_id
        FROM   APPLY_BATCH WHERE APPLY_BATCH_ID = p_batch_id;

        INSERT INTO APPLY_TASK (
            APPLY_TASK_ID, APPLY_BATCH_ID, MINED_CHANGE_ID,
            MIG_RUN_ID, SEG_OWNER, TABLE_NAME, DML_TYPE,
            KEY_PAYLOAD, DML_TEXT, STATUS, RETRY_COUNT, CREATED_AT
        ) VALUES (
            SEQ_APPLY_TASK.NEXTVAL, p_batch_id, p_mined_change_id,
            v_run_id, p_seg_owner, p_table_name, p_dml_type,
            p_key_payload, p_dml_text, 'PENDING', 0, SYSTIMESTAMP
        ) RETURNING APPLY_TASK_ID INTO v_new_id;

        COMMIT;
        p_task_id := v_new_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'APPLY_BATCH not found: id=' || p_batch_id);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END QUEUE_APPLY_TASK;

    -- -------------------------------------------------------------------------
    -- START_APPLY_TASK: PENDING/RETRY → RUNNING
    -- -------------------------------------------------------------------------
    PROCEDURE START_APPLY_TASK (
        p_task_id  IN NUMBER,
        p_executor IN VARCHAR2 DEFAULT NULL
    ) IS
        v_status VARCHAR2(20);
    BEGIN
        SELECT STATUS INTO v_status
        FROM   APPLY_TASK
        WHERE  APPLY_TASK_ID = p_task_id
        FOR UPDATE;

        IF v_status NOT IN ('PENDING','RETRY') THEN
            RAISE_APPLICATION_ERROR(-20012,
                'START_APPLY_TASK: invalid state transition. ' ||
                'Expected PENDING or RETRY but was ' || v_status);
        END IF;

        UPDATE APPLY_TASK
        SET    STATUS      = 'RUNNING',
               STARTED_AT  = SYSTIMESTAMP,
               EXECUTED_BY = p_executor,
               UPDATED_AT  = SYSTIMESTAMP
        WHERE  APPLY_TASK_ID = p_task_id;

        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'APPLY_TASK not found: id=' || p_task_id);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END START_APPLY_TASK;

    -- -------------------------------------------------------------------------
    -- COMPLETE_APPLY_TASK: RUNNING → APPLIED
    -- -------------------------------------------------------------------------
    PROCEDURE COMPLETE_APPLY_TASK (p_task_id IN NUMBER) IS
        v_status VARCHAR2(20);
    BEGIN
        SELECT STATUS INTO v_status
        FROM   APPLY_TASK
        WHERE  APPLY_TASK_ID = p_task_id
        FOR UPDATE;

        IF v_status != 'RUNNING' THEN
            RAISE_APPLICATION_ERROR(-20012,
                'COMPLETE_APPLY_TASK: invalid state transition. ' ||
                'Expected RUNNING but was ' || v_status);
        END IF;

        UPDATE APPLY_TASK
        SET    STATUS     = 'APPLIED',
               APPLIED_AT = SYSTIMESTAMP,
               UPDATED_AT = SYSTIMESTAMP
        WHERE  APPLY_TASK_ID = p_task_id;

        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'APPLY_TASK not found: id=' || p_task_id);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END COMPLETE_APPLY_TASK;

    -- -------------------------------------------------------------------------
    -- RETRY_APPLY_TASK: RUNNING → RETRY（再試行可能エラー）
    -- -------------------------------------------------------------------------
    PROCEDURE RETRY_APPLY_TASK (
        p_task_id   IN NUMBER,
        p_error_id  IN NUMBER  DEFAULT NULL,
        p_error_msg IN VARCHAR2 DEFAULT NULL
    ) IS
        v_status VARCHAR2(20);
    BEGIN
        SELECT STATUS INTO v_status
        FROM   APPLY_TASK
        WHERE  APPLY_TASK_ID = p_task_id
        FOR UPDATE;

        IF v_status != 'RUNNING' THEN
            RAISE_APPLICATION_ERROR(-20012,
                'RETRY_APPLY_TASK: invalid state transition. ' ||
                'Expected RUNNING but was ' || v_status);
        END IF;

        UPDATE APPLY_TASK
        SET    STATUS         = 'RETRY',
               RETRY_COUNT    = RETRY_COUNT + 1,
               ERROR_EVENT_ID = p_error_id,
               ERROR_MESSAGE  = p_error_msg,
               UPDATED_AT     = SYSTIMESTAMP
        WHERE  APPLY_TASK_ID = p_task_id;

        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'APPLY_TASK not found: id=' || p_task_id);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END RETRY_APPLY_TASK;

    -- -------------------------------------------------------------------------
    -- ERROR_APPLY_TASK: RUNNING → ERROR（再試行不可エラー）
    -- -------------------------------------------------------------------------
    PROCEDURE ERROR_APPLY_TASK (
        p_task_id   IN NUMBER,
        p_error_id  IN NUMBER  DEFAULT NULL,
        p_error_msg IN VARCHAR2 DEFAULT NULL
    ) IS
        v_status   VARCHAR2(20);
        v_batch_id NUMBER;
        v_run_id   NUMBER;
    BEGIN
        SELECT STATUS INTO v_status
        FROM   APPLY_TASK
        WHERE  APPLY_TASK_ID = p_task_id
        FOR UPDATE;

        IF v_status != 'RUNNING' THEN
            RAISE_APPLICATION_ERROR(-20012,
                'ERROR_APPLY_TASK: invalid state transition. ' ||
                'Expected RUNNING but was ' || v_status);
        END IF;

        UPDATE APPLY_TASK
        SET    STATUS         = 'ERROR',
               RETRY_COUNT    = RETRY_COUNT + 1,
               ERROR_EVENT_ID = p_error_id,
               ERROR_MESSAGE  = p_error_msg,
               UPDATED_AT     = SYSTIMESTAMP
        WHERE  APPLY_TASK_ID = p_task_id;

        -- LOG_STATUS_CHANGE を追加（APPLY_TASK の ERROR 遷移は追跡対象）
        SELECT APPLY_BATCH_ID INTO v_batch_id
        FROM   APPLY_TASK WHERE APPLY_TASK_ID = p_task_id;

        SELECT MIG_RUN_ID INTO v_run_id
        FROM   APPLY_BATCH WHERE APPLY_BATCH_ID = v_batch_id;

        LOG_STATUS_CHANGE(v_run_id, 'APPLY_TASK', p_task_id, 'RUNNING', 'ERROR',
            'error_id=' || NVL(TO_CHAR(p_error_id), 'NULL'));

        COMMIT;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002,
                'APPLY_TASK not found: id=' || p_task_id);
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END ERROR_APPLY_TASK;

    -- -------------------------------------------------------------------------
    -- BULK_INS_APPLY_TASKS: APPLY_TASK を FORALL バルク INSERT
    -- 失敗時は呼び出し元でハンドリングする（SAVE EXCEPTIONS なし）
    -- -------------------------------------------------------------------------
    PROCEDURE BULK_INS_APPLY_TASKS (p_rows IN T_APPLY_TASK_TBL) IS
    BEGIN
        IF p_rows.COUNT = 0 THEN
            RETURN;
        END IF;

        FORALL i IN 1..p_rows.COUNT
            INSERT INTO APPLY_TASK (
                APPLY_TASK_ID, APPLY_BATCH_ID, MINED_CHANGE_ID,
                MIG_RUN_ID, SEG_OWNER, TABLE_NAME, DML_TYPE,
                KEY_PAYLOAD, DML_TEXT, STATUS, RETRY_COUNT, CREATED_AT
            ) VALUES (
                SEQ_APPLY_TASK.NEXTVAL,
                p_rows(i).APPLY_BATCH_ID,
                p_rows(i).MINED_CHANGE_ID,
                p_rows(i).MIG_RUN_ID,
                p_rows(i).SEG_OWNER,
                p_rows(i).TABLE_NAME,
                p_rows(i).DML_TYPE,
                p_rows(i).KEY_PAYLOAD,
                p_rows(i).DML_TEXT,
                'PENDING',
                0,
                SYSTIMESTAMP
            );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END BULK_INS_APPLY_TASKS;

    -- -------------------------------------------------------------------------
    -- UPDATE_MINED_TX_STATUS: MINED_TRANSACTION.STATUS を更新
    -- -------------------------------------------------------------------------
    PROCEDURE UPDATE_MINED_TX_STATUS (
        p_mined_transaction_id IN NUMBER,
        p_new_status           IN VARCHAR2
    ) IS
    BEGIN
        UPDATE MINED_TRANSACTION
        SET    STATUS     = p_new_status,
               UPDATED_AT = SYSTIMESTAMP
        WHERE  MINED_TRANSACTION_ID = p_mined_transaction_id;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
                'UPDATE_MINED_TX_STATUS: MINED_TRANSACTION not found: id=' ||
                p_mined_transaction_id);
        END IF;

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END UPDATE_MINED_TX_STATUS;

    -- -------------------------------------------------------------------------
    -- UPDATE_MINED_CHG_STATUS: MINED_CHANGE.STATUS を更新
    -- -------------------------------------------------------------------------
    PROCEDURE UPDATE_MINED_CHG_STATUS (
        p_mined_change_id IN NUMBER,
        p_new_status      IN VARCHAR2
    ) IS
    BEGIN
        UPDATE MINED_CHANGE
        SET    STATUS     = p_new_status,
               UPDATED_AT = SYSTIMESTAMP
        WHERE  MINED_CHANGE_ID = p_mined_change_id;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
                'UPDATE_MINED_CHG_STATUS: MINED_CHANGE not found: id=' ||
                p_mined_change_id);
        END IF;

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END UPDATE_MINED_CHG_STATUS;

END PKG_MIG_ADMIN;
/

SHOW ERRORS PACKAGE PKG_MIG_ADMIN;
SHOW ERRORS PACKAGE BODY PKG_MIG_ADMIN;

EXIT;
