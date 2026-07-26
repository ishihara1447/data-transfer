-- PKG_MIG_ADMIN: 移行管理APIパッケージ
-- 実行ユーザー: migration_ctl
-- 実行対象: oracle-tgt (localhost:1522/XEPDB1)
-- 設計書: docs/migration-control-schema-design.md §8

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

-- ===========================================================================
-- パッケージ仕様部
-- エラー番号規約:
--   -20001: 既設定値への上書き禁止（BASELINE_SCN, TARGET_END_SCN等）
--   -20002: 不正な状態遷移・事前条件不満
--   -20003: カバレッジ不足（MARK_ARCHIVE_READY）
--   -20004: SCN後退禁止（UPDATE_LAST_APPLIED_SCN）
--   -20005: ファイル検証失敗（VERIFY_ARCHIVE_LOG_COPY チェックサムNULL）
-- ===========================================================================

CREATE OR REPLACE PACKAGE PKG_MIG_ADMIN AS

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

END PKG_MIG_ADMIN;
/

-- ===========================================================================
-- パッケージ本体
-- ===========================================================================

CREATE OR REPLACE PACKAGE BODY PKG_MIG_ADMIN AS

    -- =========================================================================
    -- CREATE_RUN: MIGRATION_RUN 1行 + PHASE_STATUS 7行を同一トランザクションで作成
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

    -- =========================================================================
    -- FIX_BASELINE_SCN: 基準SCNを確定（一度設定したら上書き禁止）
    -- =========================================================================
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

    -- =========================================================================
    -- MARK_ARCHIVE_READY: アーカイブカバレッジ確認後 ARCHIVE_READY へ遷移
    --
    -- PoC段階の簡略実装: ARCHIVE_LOG が1件以上存在することを確認する。
    -- 本番フェーズ移行前には MINING_START_SCN からの COLLECT_STATUS='VERIFIED'
    -- 連続性チェック（FIRST_CHANGE_SCN/NEXT_CHANGE_SCN のギャップ確認）に強化すること。
    -- =========================================================================
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

    -- =========================================================================
    -- SET_TARGET_END_SCN: 最終同期点SCNを確定（上書き禁止）
    -- =========================================================================
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

    -- =========================================================================
    -- UPDATE_LAST_APPLIED_SCN: 最終適用済みSCNを前進更新（後退禁止）
    -- =========================================================================
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

    -- =========================================================================
    -- START_DATAPUMP_JOB: PLANNED/RETRY → RUNNING
    -- =========================================================================
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

    -- =========================================================================
    -- COMPLETE_DATAPUMP_JOB: RUNNING → COMPLETED（件数・バイト数・エラー数記録）
    -- 事前条件: STATUS = 'RUNNING'（それ以外は -20002 例外）
    -- =========================================================================
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

        -- 事前条件: STATUS = 'RUNNING'
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

    -- =========================================================================
    -- FAIL_DATAPUMP_JOB: → FAILED（エラーメッセージをREMARKSに記録）
    -- 事前条件: STATUS IN ('PLANNED','RUNNING','RETRY')（それ以外は -20002 例外）
    -- =========================================================================
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

        -- 事前条件: STATUS IN ('PLANNED', 'RUNNING', 'RETRY')
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

    -- =========================================================================
    -- VERIFY_ARCHIVE_LOG_COPY: RECEIVED → VERIFIED
    --
    -- 前提条件: 呼び出し側がファイル実体の存在・サイズ・チェックサムを確認済みであること。
    -- PL/SQL内でOSファイル確認は不可のため、本APIはDB状態の更新のみ担当する。
    -- p_checksum が NULL の場合はチェックサム照合不可とみなし CORRUPT へ遷移する。
    --
    -- ARCHIVE_LOG.COLLECT_STATUS 更新条件:
    -- 同一 ARCHIVE_LOG_ID の全 ARCHIVE_LOG_COPY が VERIFIED になった時点でのみ
    -- COLLECT_STATUS を RECEIVED → VERIFIED へ更新する（1件目検証時点では更新しない）。
    -- =========================================================================
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

        -- 事前条件: COPY_STATUS = 'RECEIVED'
        IF v_copy_status != 'RECEIVED' THEN
            RAISE_APPLICATION_ERROR(-20002,
                'VERIFY_ARCHIVE_LOG_COPY の事前条件エラー: COPY_STATUS=' ||
                v_copy_status || '。RECEIVED 状態のみ VERIFIED へ遷移できます。');
        END IF;

        -- チェックサムNULL → CORRUPT遷移 + 例外（照合不能ファイルをVERIFIEDにしない不変条件）
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

        -- ARCHIVE_LOG_COPY を VERIFIED へ更新
        UPDATE ARCHIVE_LOG_COPY
        SET COPY_STATUS    = 'VERIFIED',
            VERIFIED_AT    = SYSTIMESTAMP,
            CHECKSUM_VALUE = p_checksum,
            UPDATED_AT     = SYSTIMESTAMP
        WHERE ARCHIVE_LOG_COPY_ID = p_copy_id;

        -- 同一 ARCHIVE_LOG_ID の未検証コピー数を確認
        -- VERIFIED でないコピーが残っている場合は ARCHIVE_LOG を更新しない
        SELECT COUNT(*)
        INTO v_unverified_cnt
        FROM ARCHIVE_LOG_COPY
        WHERE ARCHIVE_LOG_ID = v_archive_log_id
          AND COPY_STATUS != 'VERIFIED';

        IF v_unverified_cnt = 0 THEN
            -- 全コピーが VERIFIED → ARCHIVE_LOG を RECEIVED から VERIFIED に更新
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

    -- =========================================================================
    -- LOG_STATUS_CHANGE: MIG_STATUS_HISTORYへ追記（追記専用・UPDATE/DELETE禁止）
    -- =========================================================================
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
        -- LOG_STATUS_CHANGE 自体はCOMMITしない。呼び出し元でCOMMITする。
    EXCEPTION
        WHEN OTHERS THEN
            RAISE;
    END LOG_STATUS_CHANGE;

END PKG_MIG_ADMIN;
/

SHOW ERRORS PACKAGE PKG_MIG_ADMIN;
SHOW ERRORS PACKAGE BODY PKG_MIG_ADMIN;

EXIT;
