-- ARCHIVE_LOG / ARCHIVE_LOG_COPY 台帳登録サンプル
-- 実行ユーザー: migration_ctl
-- 実行対象: oracle-tgt (localhost:1521/XEPDB1)
--
-- 目的: REGISTER_ARCHIVE_LOG / REGISTER_ARCHIVE_LOG_COPY / VERIFY_ARCHIVE_LOG_COPY
--       の使用例を示す（動作確認用サンプル）。
--       実際の収集は scripts/67_collect_archivelogs.sh で行う。
--
-- 前提:
--   - MIG_RUN_ID, SOURCE_DBID, RESETLOGS_ID, THREAD_NO, SEQ_NO 等は
--     実際の値に置き換えること
--   - ファイルコピーは docker cp で /migfs/archivelogs/ に転送済みであること

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET SERVEROUTPUT ON FEEDBACK ON

-- -----------------------------------------------------------------------
-- Step 1: ARCHIVE_LOG に論理エントリを登録（EXPECTED 状態で INSERT）
-- -----------------------------------------------------------------------
DECLARE
    v_run_id         NUMBER := 1;         -- 実際の MIG_RUN_ID に変更すること
    v_dbid           NUMBER := 3024951340; -- V$DATABASE.DBID（oracle-src で確認）
    v_resetlogs_id   NUMBER := 1143830636; -- V$ARCHIVED_LOG.RESETLOGS_ID
    v_thread_no      NUMBER := 1;          -- RAC Thread 番号（本環境は 1 固定）
    v_seq_no         NUMBER := 200;        -- 登録する Sequence 番号
    v_first_scn      NUMBER := 26000000;   -- FIRST_CHANGE#
    v_next_scn       NUMBER := 26100000;   -- NEXT_CHANGE#
    v_archive_log_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_ARCHIVE_LOG(
        p_run_id         => v_run_id,
        p_dbid           => v_dbid,
        p_resetlogs_id   => v_resetlogs_id,
        p_thread_no      => v_thread_no,
        p_seq_no         => v_seq_no,
        p_first_scn      => v_first_scn,
        p_next_scn       => v_next_scn,
        p_archive_log_id => v_archive_log_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('REGISTER_ARCHIVE_LOG: ARCHIVE_LOG_ID=' || v_archive_log_id);

    -- -----------------------------------------------------------------------
    -- Step 2: ファイルコピー受信完了を記録（EXPECTED -> RECEIVED）
    -- -----------------------------------------------------------------------
    PKG_MIG_ADMIN.RECEIVE_ARCHIVE_LOG(p_archive_log_id => v_archive_log_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('RECEIVE_ARCHIVE_LOG: COLLECT_STATUS=RECEIVED');

    -- -----------------------------------------------------------------------
    -- Step 3: コピー情報とチェックサムを登録（ARCHIVE_LOG_COPY 行を INSERT）
    -- -----------------------------------------------------------------------
    DECLARE
        v_copy_id  NUMBER;
        v_checksum VARCHAR2(64) := 'abc123def456...'; -- sha256sum の実際の値に変更
        v_filesize NUMBER := 1048576;                  -- 実際のファイルサイズ（バイト）
        v_filepath VARCHAR2(512) :=
            '/migfs/archivelogs/arch1_200_1143830636.dbf'; -- 実際のパス
    BEGIN
        PKG_MIG_ADMIN.REGISTER_ARCHIVE_LOG_COPY(
            p_archive_log_id => v_archive_log_id,
            p_storage_loc    => 'MIGFS',
            p_file_path      => v_filepath,
            p_file_size      => v_filesize,
            p_checksum_algo  => 'SHA256',
            p_checksum_val   => v_checksum,
            p_copy_id        => v_copy_id
        );
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('REGISTER_ARCHIVE_LOG_COPY: COPY_ID=' || v_copy_id);

        -- -----------------------------------------------------------------------
        -- Step 4: チェックサム検証（RECEIVED -> VERIFIED）
        -- 全コピーが VERIFIED になると ARCHIVE_LOG.COLLECT_STATUS も VERIFIED になる
        -- -----------------------------------------------------------------------
        PKG_MIG_ADMIN.VERIFY_ARCHIVE_LOG_COPY(
            p_copy_id  => v_copy_id,
            p_checksum => v_checksum
        );
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('VERIFY_ARCHIVE_LOG_COPY: COPY_STATUS=VERIFIED');
    END;
END;
/

-- -----------------------------------------------------------------------
-- 確認: 登録した行の状態を表示
-- -----------------------------------------------------------------------
SELECT
    al.ARCHIVE_LOG_ID,
    al.THREAD_NO,
    al.SEQUENCE_NO,
    al.COLLECT_STATUS,
    alc.ARCHIVE_LOG_COPY_ID,
    alc.COPY_STATUS,
    alc.FILE_PATH
FROM ARCHIVE_LOG al
JOIN ARCHIVE_LOG_COPY alc ON alc.ARCHIVE_LOG_ID = al.ARCHIVE_LOG_ID
ORDER BY al.SEQUENCE_NO;

EXIT;
