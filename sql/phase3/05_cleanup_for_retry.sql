-- フェーズ3 再実行用初期化スクリプト
-- 実行ユーザー: migration_ctl
-- 実行対象: oracle-tgt (localhost:1521/XEPDB1)
--
-- 目的: フェーズ3 のデータをクリアして再実行を可能にする。
--       DROP USER は使用しない（テーブル定義を破壊しない）。
--       MIG_RUN_ID を指定して特定の実行分だけ削除する。
--
-- 禁止事項:
--   - DROP USER migration_ctl CASCADE は使用禁止
--   - sql/migration_ctl/02 や 03 のみ再適用する方式は使用禁止
--
-- 使用方法:
--   このスクリプトを実行する前に、対象の MIG_RUN_ID を変数定義部に設定すること。
--
-- 注意: TRUNCATE は全件削除のため、テスト環境でのみ使用すること。
--       本番は MIG_RUN_ID を指定した DELETE を使用すること。

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET SERVEROUTPUT ON FEEDBACK ON

-- -----------------------------------------------------------------------
-- 特定 MIG_RUN_ID のフェーズ3 データを削除する（推奨）
-- v_run_id を対象の MIG_RUN_ID に変更して実行すること
-- -----------------------------------------------------------------------
DECLARE
    v_run_id NUMBER := 1;  -- 対象の MIG_RUN_ID に変更すること
    v_cnt    NUMBER;
BEGIN
    -- Step 1: MIG_CHECKPOINT（ARCHIVE_COLLECTOR 分）を削除
    DELETE FROM MIG_CHECKPOINT
    WHERE MIG_RUN_ID     = v_run_id
      AND COMPONENT_NAME = 'ARCHIVE_COLLECTOR';
    v_cnt := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('MIG_CHECKPOINT deleted: ' || v_cnt || ' rows');

    -- Step 2: ARCHIVE_LOG_COPY を削除（FK 制約のため先に削除）
    DELETE FROM ARCHIVE_LOG_COPY
    WHERE MIG_RUN_ID = v_run_id;
    v_cnt := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('ARCHIVE_LOG_COPY deleted: ' || v_cnt || ' rows');

    -- Step 3: ARCHIVE_LOG を削除
    DELETE FROM ARCHIVE_LOG
    WHERE MIG_RUN_ID = v_run_id;
    v_cnt := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('ARCHIVE_LOG deleted: ' || v_cnt || ' rows');

    -- Step 4: PHASE_STATUS の PHASE3 を NOT_STARTED に戻す
    UPDATE PHASE_STATUS
    SET STATUS      = 'NOT_STARTED',
        STARTED_AT  = NULL,
        FINISHED_AT = NULL,
        UPDATED_AT  = SYSTIMESTAMP
    WHERE MIG_RUN_ID  = v_run_id
      AND PHASE_CODE  = 'PHASE3';
    v_cnt := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('PHASE_STATUS PHASE3 reset: ' || v_cnt || ' rows');

    -- Step 5: MIGRATION_RUN の TARGET_END_SCN と ARCHIVE_READY_AT をリセット
    UPDATE MIGRATION_RUN
    SET TARGET_END_SCN   = NULL,
        ARCHIVE_READY_AT = NULL,
        UPDATED_AT       = SYSTIMESTAMP
    WHERE MIG_RUN_ID = v_run_id;
    v_cnt := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('MIGRATION_RUN reset: ' || v_cnt || ' rows');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Cleanup completed for MIG_RUN_ID=' || v_run_id);
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERROR: ' || SQLERRM);
        RAISE;
END;
/

EXIT;
