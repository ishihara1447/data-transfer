-- 最終ログ確定手順（フェーズ3 完了前の最終 SCN 設定）
-- 実行ユーザー: migration_ctl
-- 実行対象: oracle-tgt (localhost:1521/XEPDB1)
--
-- 目的: oracle-src の書込みを停止した後、最終同期点 SCN を確定する。
--       SET_TARGET_END_SCN を呼び出した後は上書き不可（設計書 §5.4）。
--
-- 手順（作業者が実施）:
--   1. oracle-src の業務アプリケーションを停止（書込み停止）
--   2. oracle-src で ALTER SYSTEM ARCHIVE LOG CURRENT（最終 Redo を確定）
--   3. 最終 Archived Redo の NEXT_CHANGE# を確認（これが TARGET_END_SCN）
--   4. scripts/67_collect_archivelogs.sh を最後に実行（全 Redo を収集）
--   5. このスクリプトで SET_TARGET_END_SCN を呼び出す
--   6. scripts/68_build_logminer_dict.sh で辞書ビルド（未実施の場合）
--   7. PKG_MIG_ADMIN.COMPLETE_PHASE3 で完了判定
--
-- 前提:
--   - MIG_RUN_ID と TARGET_END_SCN は実際の値に置き換えること
--   - COMPLETE_PHASE3 の条件 d: MIG_CHECKPOINT の SCN がこの値以上になること

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET SERVEROUTPUT ON FEEDBACK ON

-- -----------------------------------------------------------------------
-- 最終 SCN 確認（oracle-src で実行してから転記する）
-- -----------------------------------------------------------------------
-- oracle-src CDB$ROOT で以下を実行して NEXT_CHANGE# を取得:
--   SELECT MAX(NEXT_CHANGE#) FROM V$ARCHIVED_LOG WHERE STATUS='A';

-- -----------------------------------------------------------------------
-- Step 1: TARGET_END_SCN を確定する（上書き不可）
-- -----------------------------------------------------------------------
DECLARE
    v_run_id         NUMBER := 1;         -- 実際の MIG_RUN_ID に変更すること
    v_target_end_scn NUMBER := 99999999;  -- oracle-src の最終 NEXT_CHANGE# に変更
BEGIN
    PKG_MIG_ADMIN.SET_TARGET_END_SCN(
        p_run_id         => v_run_id,
        p_target_end_scn => v_target_end_scn
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SET_TARGET_END_SCN: TARGET_END_SCN=' || v_target_end_scn);
END;
/

-- -----------------------------------------------------------------------
-- Step 2: ARCHIVE_READY を設定（MARK_ARCHIVE_READY）
-- -----------------------------------------------------------------------
DECLARE
    v_run_id NUMBER := 1;  -- 実際の MIG_RUN_ID に変更すること
BEGIN
    PKG_MIG_ADMIN.MARK_ARCHIVE_READY(p_run_id => v_run_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('MARK_ARCHIVE_READY: done');
END;
/

-- -----------------------------------------------------------------------
-- Step 3: フェーズ3 完了判定（全条件充足後に実行）
-- -----------------------------------------------------------------------
DECLARE
    v_run_id NUMBER := 1;  -- 実際の MIG_RUN_ID に変更すること
BEGIN
    PKG_MIG_ADMIN.COMPLETE_PHASE3(p_run_id => v_run_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('COMPLETE_PHASE3: PHASE_STATUS=COMPLETED');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('COMPLETE_PHASE3 failed: ' || SQLERRM);
        ROLLBACK;
        RAISE;
END;
/

-- -----------------------------------------------------------------------
-- 確認: フェーズ3 の状態を表示
-- -----------------------------------------------------------------------
SELECT PHASE_CODE, STATUS, FINISHED_AT
FROM PHASE_STATUS
WHERE PHASE_CODE = 'PHASE3'
ORDER BY MIG_RUN_ID DESC;

EXIT;
