-- PKG_MIG_ADMIN フェーズ1・2追加 API
-- 実行ユーザー: migration_ctl
-- 実行対象: oracle-tgt (localhost:1521/XEPDB1)
-- 設計書: docs/migration-control-schema-design.md v3.0 §8.3
--
-- 既存の 03_pkg_mig_admin.sql を修正せず、PACKAGE と PACKAGE BODY を
-- CREATE OR REPLACE で全体再定義することで 8 本のプロシージャを追加する。
-- 既存の 10 プロシージャはそのまま含める（コピー＋追加）。
-- エラー番号規約（v3.0追加）:
--   -20010: COMPLETE_PHASE 完了条件未達

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON FEEDBACK ON SERVEROUTPUT ON SIZE UNLIMITED

-- ===========================================================================
-- パッケージ仕様部（既存 10 本 + 追加 8 本）
-- ===========================================================================

CREATE OR REPLACE PACKAGE PKG_MIG_ADMIN AS

    -- -----------------------------------------------------------------------
    -- 既存 API（03_pkg_mig_admin.sql から継続）
    -- -----------------------------------------------------------------------

    -- 移行実行を新規作成する（MIGRATION_RUN + 7フェーズのPHASE_STATUS）
    PROCEDURE CREATE_RUN (
        p_run_name       IN  VARCHAR2,
        p_run_type       IN  VARCHAR2,
        p_source_db_info IN  VARCHAR2 DEFAULT NULL,
        p_target_db_info IN  VARCHAR2 DEFAULT NULL,
        p_run_id         OUT NUMBER
    );

    -- 基準SCNを不変値として確定する（上書き禁止）
    PROCEDURE FIX_BASELINE_SCN (
        p_run_id       IN NUMBER,
        p_baseline_scn IN NUMBER
    );

    -- アーカイブログのカバレッジを確認し ARCHIVE_READY 状態へ遷移する
    PROCEDURE MARK_ARCHIVE_READY (
        p_run_id IN NUMBER
    );

    -- 最終同期点SCNを不変値として確定する（上書き禁止）
    PROCEDURE SET_TARGET_END_SCN (
        p_run_id         IN NUMBER,
        p_target_end_scn IN NUMBER
    );

    -- 最終適用済みSCNを前進更新する（後退禁止）
    PROCEDURE UPDATE_LAST_APPLIED_SCN (
        p_run_id IN NUMBER,
        p_scn    IN NUMBER
    );

    -- DataPumpジョブを開始状態へ遷移する（PLANNED/RETRY → RUNNING）
    PROCEDURE START_DATAPUMP_JOB (
        p_job_id IN NUMBER
    );

    -- DataPumpジョブを完了状態へ遷移する（RUNNING → COMPLETED）
    PROCEDURE COMPLETE_DATAPUMP_JOB (
        p_job_id      IN NUMBER,
        p_rows        IN NUMBER DEFAULT NULL,
        p_bytes       IN NUMBER DEFAULT NULL,
        p_error_count IN NUMBER DEFAULT 0
    );

    -- DataPumpジョブを失敗状態へ遷移する（→ FAILED）
    PROCEDURE FAIL_DATAPUMP_JOB (
        p_job_id        IN NUMBER,
        p_error_message IN VARCHAR2 DEFAULT NULL
    );

    -- アーカイブログ物理コピーを検証済みへ遷移する（RECEIVED → VERIFIED）
    PROCEDURE VERIFY_ARCHIVE_LOG_COPY (
        p_copy_id  IN NUMBER,
        p_checksum IN VARCHAR2 DEFAULT NULL
    );

    -- 状態変更をMIG_STATUS_HISTORYに記録する（追記専用）
    PROCEDURE LOG_STATUS_CHANGE (
        p_run_id     IN NUMBER,
        p_table_name IN VARCHAR2,
        p_record_id  IN NUMBER,
        p_old_status IN VARCHAR2 DEFAULT NULL,
        p_new_status IN VARCHAR2,
        p_note       IN VARCHAR2 DEFAULT NULL
    );

    -- -----------------------------------------------------------------------
    -- v3.0 追加 API（フェーズ1・2対応）
    -- -----------------------------------------------------------------------

    -- DATAPUMP_FILE へ新規レコード INSERT（STATUS='CREATED'）
    PROCEDURE REGISTER_DATAPUMP_FILE (
        p_run_id           IN  NUMBER,
        p_job_id           IN  NUMBER,
        p_file_role        IN  VARCHAR2,
        p_file_name        IN  VARCHAR2,
        p_file_path        IN  VARCHAR2 DEFAULT NULL,
        p_storage_location IN  VARCHAR2 DEFAULT NULL,
        p_file_id          OUT NUMBER
    );

    -- チェックサム記録 → STATUS='VERIFIED'
    PROCEDURE VERIFY_DATAPUMP_FILE (
        p_file_id         IN NUMBER,
        p_file_size_bytes IN NUMBER,
        p_checksum_algo   IN VARCHAR2,
        p_checksum_value  IN VARCHAR2
    );

    -- STATUS='CONSUMED'、CONSUMED_BY_IMPORT_JOB_ID と CONSUMED_AT を記録
    PROCEDURE CONSUME_DATAPUMP_FILE (
        p_file_id       IN NUMBER,
        p_import_job_id IN NUMBER
    );

    -- VALIDATION_RUN INSERT（STATUS='RUNNING'）
    PROCEDURE START_VALIDATION_RUN (
        p_run_id            IN  NUMBER,
        p_phase_code        IN  VARCHAR2,
        p_validation_type   IN  VARCHAR2,
        p_validation_run_id OUT NUMBER
    );

    -- STATUS='COMPLETED', OVERALL_RESULT を記録
    PROCEDURE COMPLETE_VALIDATION_RUN (
        p_validation_run_id IN NUMBER,
        p_overall_result    IN VARCHAR2
    );

    -- VALIDATION_RESULT に 1 件 INSERT
    PROCEDURE RECORD_VALIDATION_RESULT (
        p_validation_run_id IN  NUMBER,
        p_mig_object_id     IN  NUMBER DEFAULT NULL,
        p_check_name        IN  VARCHAR2,
        p_expected_value    IN  VARCHAR2 DEFAULT NULL,
        p_actual_value      IN  VARCHAR2 DEFAULT NULL,
        p_result            IN  VARCHAR2,
        p_result_id         OUT NUMBER
    );

    -- ERROR_EVENT INSERT（SEVERITY='ERROR' 等）
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

    -- フェーズ完了の機械判定（全条件 SQL 確認後に PHASE_STATUS を COMPLETED へ）
    PROCEDURE COMPLETE_PHASE (
        p_run_id     IN NUMBER,
        p_phase_code IN VARCHAR2
    );

END PKG_MIG_ADMIN;
/

-- ===========================================================================
-- パッケージ本体
-- ===========================================================================

CREATE OR REPLACE PACKAGE BODY PKG_MIG_ADMIN AS

    -- =========================================================================
    -- 既存プロシージャ（03_pkg_mig_admin.sql から継続・変更なし）
    -- =========================================================================

    -- -------------------------------------------------------------------------
    -- CREATE_RUN: MIGRATION_RUN 1行 + PHASE_STATUS 7行を同一トランザクションで作成
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- FIX_BASELINE_SCN: 基準SCNを確定（一度設定したら上書き禁止）
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- MARK_ARCHIVE_READY: アーカイブカバレッジ確認後 ARCHIVE_READY へ遷移
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- SET_TARGET_END_SCN: 最終同期点SCNを確定（上書き禁止）
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- UPDATE_LAST_APPLIED_SCN: 最終適用済みSCNを前進更新（後退禁止）
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- START_DATAPUMP_JOB: PLANNED/RETRY → RUNNING
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- COMPLETE_DATAPUMP_JOB: RUNNING → COMPLETED（件数・バイト数・エラー数記録）
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- FAIL_DATAPUMP_JOB: → FAILED（エラーメッセージをREMARKSに記録）
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- VERIFY_ARCHIVE_LOG_COPY: RECEIVED → VERIFIED
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- LOG_STATUS_CHANGE: MIG_STATUS_HISTORYへ追記（追記専用・UPDATE/DELETE禁止）
    -- -------------------------------------------------------------------------
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

    -- =========================================================================
    -- v3.0 追加プロシージャ（フェーズ1・2対応）
    -- =========================================================================

    -- -------------------------------------------------------------------------
    -- REGISTER_DATAPUMP_FILE: DATAPUMP_FILE へ新規レコード INSERT（STATUS='CREATED'）
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- VERIFY_DATAPUMP_FILE: チェックサム記録 → STATUS='VERIFIED'
    -- ガード: p_checksum_value が NULL → -20005 例外
    -- 事前条件: STATUS = 'CREATED' → それ以外は -20002 例外
    -- -------------------------------------------------------------------------
    PROCEDURE VERIFY_DATAPUMP_FILE (
        p_file_id         IN NUMBER,
        p_file_size_bytes IN NUMBER,
        p_checksum_algo   IN VARCHAR2,
        p_checksum_value  IN VARCHAR2
    ) IS
        v_status VARCHAR2(20);
        v_run_id NUMBER;
    BEGIN
        -- チェックサム NULL チェック（事前条件より先に評価する）
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

    -- -------------------------------------------------------------------------
    -- CONSUME_DATAPUMP_FILE: STATUS='CONSUMED'、消費情報を記録
    -- 事前条件: STATUS = 'VERIFIED' → それ以外は -20002 例外
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- START_VALIDATION_RUN: VALIDATION_RUN INSERT（STATUS='RUNNING'）
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- COMPLETE_VALIDATION_RUN: STATUS='COMPLETED', OVERALL_RESULT を記録
    -- 事前条件: STATUS = 'RUNNING' → それ以外は -20002 例外
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- RECORD_VALIDATION_RESULT: VALIDATION_RESULT に 1 件 INSERT
    -- 本 API は COMMIT しない（呼び出し元でまとめて COMMIT する）
    -- -------------------------------------------------------------------------
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
        -- COMMIT しない。呼び出し元でトランザクション制御する。
    EXCEPTION
        WHEN OTHERS THEN
            RAISE;
    END RECORD_VALIDATION_RESULT;

    -- -------------------------------------------------------------------------
    -- RAISE_ERROR_EVENT: ERROR_EVENT INSERT（RESOLVE_STATUS='OPEN'）
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- COMPLETE_PHASE: フェーズ完了の機械判定
    -- 全条件が満たされた場合のみ PHASE_STATUS.STATUS を COMPLETED へ更新する。
    -- 条件未達時は -20010 例外で失敗理由をカンマ区切りで通知する。
    -- -------------------------------------------------------------------------
    PROCEDURE COMPLETE_PHASE (
        p_run_id     IN NUMBER,
        p_phase_code IN VARCHAR2
    ) IS
        v_cnt         NUMBER;
        v_fail_list   VARCHAR2(4000) := '';
        v_phase_id    NUMBER;
        v_old_status  VARCHAR2(20);
    BEGIN
        -- PHASE_STATUS 行をロック
        SELECT PHASE_STATUS_ID, STATUS
        INTO v_phase_id, v_old_status
        FROM PHASE_STATUS
        WHERE MIG_RUN_ID = p_run_id
          AND PHASE_CODE  = p_phase_code
        FOR UPDATE;

        IF p_phase_code = 'PHASE1' THEN
            -- 条件1: EXPORT ジョブが全て COMPLETED
            SELECT COUNT(*) INTO v_cnt
            FROM DATAPUMP_JOB
            WHERE MIG_RUN_ID = p_run_id
              AND OPERATION   = 'EXPORT'
              AND STATUS      != 'COMPLETED';
            IF v_cnt > 0 THEN
                v_fail_list := v_fail_list || 'EXPORT_JOB_NOT_COMPLETED,';
            END IF;

            -- 条件2: JOB_OBJECT が全て COMPLETED or SKIPPED（EXPORT ジョブ配下）
            SELECT COUNT(*) INTO v_cnt
            FROM DATAPUMP_JOB_OBJECT djo
            JOIN DATAPUMP_JOB dj ON djo.DATAPUMP_JOB_ID = dj.DATAPUMP_JOB_ID
            WHERE dj.MIG_RUN_ID = p_run_id
              AND dj.OPERATION   = 'EXPORT'
              AND djo.STATUS NOT IN ('COMPLETED', 'SKIPPED');
            IF v_cnt > 0 THEN
                v_fail_list := v_fail_list || 'EXPORT_JOB_OBJECT_NOT_DONE,';
            END IF;

            -- 条件3: DUMP ファイルが全て VERIFIED 以上（VERIFIED or CONSUMED）
            SELECT COUNT(*) INTO v_cnt
            FROM DATAPUMP_FILE
            WHERE MIG_RUN_ID = p_run_id
              AND FILE_ROLE   = 'DUMP'
              AND STATUS NOT IN ('VERIFIED', 'CONSUMED');
            IF v_cnt > 0 THEN
                v_fail_list := v_fail_list || 'DUMP_FILE_NOT_VERIFIED,';
            END IF;

            -- 条件4: 全 EXPORT ジョブの BASELINE_SCN が MIGRATION_RUN.BASELINE_SCN と一致
            SELECT COUNT(*) INTO v_cnt
            FROM DATAPUMP_JOB dj
            JOIN MIGRATION_RUN mr ON dj.MIG_RUN_ID = mr.MIG_RUN_ID
            WHERE dj.MIG_RUN_ID = p_run_id
              AND dj.OPERATION   = 'EXPORT'
              AND (dj.BASELINE_SCN IS NULL
                   OR dj.BASELINE_SCN != mr.BASELINE_SCN);
            IF v_cnt > 0 THEN
                v_fail_list := v_fail_list || 'BASELINE_SCN_MISMATCH,';
            END IF;

            -- 条件5: FATAL/ERROR の未解消エラーがない
            SELECT COUNT(*) INTO v_cnt
            FROM ERROR_EVENT
            WHERE MIG_RUN_ID    = p_run_id
              AND SEVERITY       IN ('FATAL', 'ERROR')
              AND RESOLVE_STATUS  = 'OPEN';
            IF v_cnt > 0 THEN
                v_fail_list := v_fail_list || 'OPEN_ERROR_EVENT_EXISTS,';
            END IF;

            -- 条件6: 全 MIGRATION_OBJECT に EXPORT_GROUP_CODE が設定済み
            SELECT COUNT(*) INTO v_cnt
            FROM MIGRATION_OBJECT
            WHERE MIG_RUN_ID       = p_run_id
              AND FULL_LOAD_FLAG    = 'Y'
              AND EXPORT_GROUP_CODE IS NULL;
            IF v_cnt > 0 THEN
                v_fail_list := v_fail_list || 'EXPORT_GROUP_CODE_NOT_SET,';
            END IF;

        ELSIF p_phase_code = 'PHASE2' THEN
            -- 条件1: IMPORT ジョブが全て COMPLETED
            SELECT COUNT(*) INTO v_cnt
            FROM DATAPUMP_JOB
            WHERE MIG_RUN_ID = p_run_id
              AND OPERATION   = 'IMPORT'
              AND STATUS      != 'COMPLETED';
            IF v_cnt > 0 THEN
                v_fail_list := v_fail_list || 'IMPORT_JOB_NOT_COMPLETED,';
            END IF;

            -- 条件2: JOB_OBJECT が全て COMPLETED or SKIPPED（IMPORT ジョブ配下）
            SELECT COUNT(*) INTO v_cnt
            FROM DATAPUMP_JOB_OBJECT djo
            JOIN DATAPUMP_JOB dj ON djo.DATAPUMP_JOB_ID = dj.DATAPUMP_JOB_ID
            WHERE dj.MIG_RUN_ID = p_run_id
              AND dj.OPERATION   = 'IMPORT'
              AND djo.STATUS NOT IN ('COMPLETED', 'SKIPPED');
            IF v_cnt > 0 THEN
                v_fail_list := v_fail_list || 'IMPORT_JOB_OBJECT_NOT_DONE,';
            END IF;

            -- 条件3: ダンプファイルの TARGET_VERIFIED_AT が全て設定済み
            SELECT COUNT(*) INTO v_cnt
            FROM DATAPUMP_FILE
            WHERE MIG_RUN_ID      = p_run_id
              AND FILE_ROLE        = 'DUMP'
              AND TARGET_VERIFIED_AT IS NULL;
            IF v_cnt > 0 THEN
                v_fail_list := v_fail_list || 'DUMP_FILE_NOT_TARGET_VERIFIED,';
            END IF;

            -- 条件4: 必須 VALIDATION_RUN が COMPLETED かつ OVERALL_RESULT='PASS'
            SELECT COUNT(*) INTO v_cnt
            FROM VALIDATION_RUN
            WHERE MIG_RUN_ID    = p_run_id
              AND PHASE_CODE     = 'PHASE2'
              AND STATUS         = 'COMPLETED'
              AND OVERALL_RESULT = 'PASS';
            IF v_cnt = 0 THEN
                v_fail_list := v_fail_list || 'NO_PASS_VALIDATION_RUN,';
            END IF;

            -- 条件5: VALIDATION_RESULT に FAIL かつ APPROVED_FLAG='N' がない
            SELECT COUNT(*) INTO v_cnt
            FROM VALIDATION_RESULT vr
            JOIN VALIDATION_RUN vrun ON vr.VALIDATION_RUN_ID = vrun.VALIDATION_RUN_ID
            WHERE vrun.MIG_RUN_ID  = p_run_id
              AND vrun.PHASE_CODE   = 'PHASE2'
              AND vr.RESULT         = 'FAIL'
              AND vr.APPROVED_FLAG  = 'N';
            IF v_cnt > 0 THEN
                v_fail_list := v_fail_list || 'UNAPPROVED_FAIL_RESULT_EXISTS,';
            END IF;

            -- 条件6: FATAL/ERROR の未解消エラーがない
            SELECT COUNT(*) INTO v_cnt
            FROM ERROR_EVENT
            WHERE MIG_RUN_ID    = p_run_id
              AND SEVERITY       IN ('FATAL', 'ERROR')
              AND RESOLVE_STATUS  = 'OPEN';
            IF v_cnt > 0 THEN
                v_fail_list := v_fail_list || 'OPEN_ERROR_EVENT_EXISTS,';
            END IF;

        ELSE
            RAISE_APPLICATION_ERROR(-20010,
                'COMPLETE_PHASE: 未対応の PHASE_CODE=' || p_phase_code ||
                '。PHASE1 または PHASE2 を指定してください。');
        END IF;

        -- 失敗条件がある場合は例外を発生させる
        IF v_fail_list IS NOT NULL THEN
            -- 末尾のカンマを除去
            v_fail_list := RTRIM(v_fail_list, ',');
            RAISE_APPLICATION_ERROR(-20010,
                'COMPLETE_PHASE(' || p_phase_code || '): 完了条件未達 [' ||
                v_fail_list || ']');
        END IF;

        -- 全条件クリア → PHASE_STATUS を COMPLETED へ更新
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

END PKG_MIG_ADMIN;
/

SHOW ERRORS PACKAGE PKG_MIG_ADMIN;
SHOW ERRORS PACKAGE BODY PKG_MIG_ADMIN;

EXIT;
