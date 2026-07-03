-- delta_queue パージ: SYS.delta_purge_tgt プロシージャ (oracle-tgt 用)
-- staging_ctl.delta_queue の適用済み行を安全な条件下でパージする。
--
-- 安全条件（この条件を満たす行のみ削除する）:
--   1. そのTx(xid, commit_scn)が apply_ledger に APPLIED/PARTIAL/MANUAL_REVIEW で記録済み
--   2. commit_scn <= delta_apply_state.last_applied_commit_scn（再開点より確実に手前）
--   3. extracted_at < SYSTIMESTAMP - (p_retention_min/1440)（保持マージン経過済み。分→日換算）
--
-- LOB手動キュー(delta_manual_review_queue)との関係:
--   replay_allowed='N' の行は delta_apply で log_to_review_queue() によって
--   delta_manual_review_queue に pk_value / sql_redo_assembled 等が既にコピーされている。
--   LOB再同期(38_/39_)は delta_manual_review_queue.pk_value を使って処理を行うため、
--   適用済み delta_queue 行を削除しても LOB 再同期フロー（lob_resync_build_targets →
--   lob_resync_export_rows → lob_resync_merge）には支障しない。
--   根拠: 38_lob_resync_tgt.sql の lob_resync_build_targets は delta_manual_review_queue を
--   参照しており、delta_queue を直接参照しない。
--
-- パラメータ:
--   p_run_name       : delta_apply_state の run_name（既定 'delta_run_01'）
--   p_retention_min  : 保持マージン分数（既定 60。ops_config の delta_purge_retention_min に従う）
--   p_dry_run        : 'Y' なら削除せず対象件数のみ DBMS_OUTPUT。'N' なら実削除。
--
-- 冪等性: CREATE OR REPLACE のため再実行可能。削除ロジックも条件ベースで冪等。
-- 実行ユーザー: SYS AS SYSDBA / 実行対象: oracle-tgt XEPDB1

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

SET SERVEROUTPUT ON SIZE UNLIMITED

CREATE OR REPLACE PROCEDURE SYS.delta_purge_tgt(
    p_run_name      IN VARCHAR2 DEFAULT 'delta_run_01',
    p_retention_min IN NUMBER   DEFAULT 60,
    p_dry_run       IN VARCHAR2 DEFAULT 'Y'
)
    AUTHID CURRENT_USER
AS
    v_last_applied_scn  NUMBER;
    v_purge_count       NUMBER := 0;
    v_remain_count      NUMBER := 0;
    v_total_count       NUMBER := 0;
    v_retention_min     NUMBER;
    v_cutoff_ts         TIMESTAMP;
BEGIN
    -- 保持マージンの決定（引数が NULL の場合は 60 分をデフォルトとする）
    v_retention_min := NVL(p_retention_min, 60);

    -- 再開点を取得（この SCN 以降の行は絶対に残す）
    BEGIN
        SELECT last_applied_commit_scn INTO v_last_applied_scn
        FROM staging_ctl.delta_apply_state
        WHERE run_name = p_run_name;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('delta_purge_tgt: run_name=' || p_run_name || ' not found. abort.');
        RETURN;
    END;

    -- 保持マージンのカットオフ時刻（この時刻より新しい行は残す）
    v_cutoff_ts := SYSTIMESTAMP - (v_retention_min / (24 * 60));

    DBMS_OUTPUT.PUT_LINE('delta_purge_tgt: run_name=' || p_run_name
        || ' last_applied_scn=' || v_last_applied_scn
        || ' retention_min=' || v_retention_min
        || ' dry_run=' || p_dry_run);

    -- 現在の総件数
    SELECT COUNT(*) INTO v_total_count FROM staging_ctl.delta_queue;

    -- パージ対象件数を計算
    -- 削除可能条件:
    --   a) (xid, commit_scn) が apply_ledger に APPLIED/PARTIAL/MANUAL_REVIEW で記録済み
    --   b) commit_scn <= last_applied_commit_scn（再開点より手前: 再適用・再開に不要）
    --   c) extracted_at < cutoff_ts（保持マージン経過済み）
    -- 残す行（削除しない）:
    --   - FAILED のTx（再適用に必要）
    --   - last_applied_commit_scn より後の commit_scn（再開に必要）
    --   - 保持マージン内の行（トラブル調査のため）
    SELECT COUNT(*) INTO v_purge_count
    FROM staging_ctl.delta_queue dq
    WHERE EXISTS (
        SELECT 1 FROM staging_ctl.apply_ledger al
        WHERE al.xid = dq.xid
          AND al.commit_scn = dq.commit_scn
          AND al.status IN ('APPLIED', 'PARTIAL', 'MANUAL_REVIEW')
    )
    AND dq.commit_scn <= v_last_applied_scn
    AND dq.extracted_at < v_cutoff_ts;

    v_remain_count := v_total_count - v_purge_count;

    DBMS_OUTPUT.PUT_LINE('delta_purge_tgt: total=' || v_total_count
        || ' purge_target=' || v_purge_count
        || ' remain=' || v_remain_count);

    IF p_dry_run = 'Y' THEN
        DBMS_OUTPUT.PUT_LINE('delta_purge_tgt: DRY_RUN mode. no rows deleted.');
        RETURN;
    END IF;

    -- 実削除（p_dry_run != 'Y'）
    BEGIN
        DELETE FROM staging_ctl.delta_queue dq
        WHERE EXISTS (
            SELECT 1 FROM staging_ctl.apply_ledger al
            WHERE al.xid = dq.xid
              AND al.commit_scn = dq.commit_scn
              AND al.status IN ('APPLIED', 'PARTIAL', 'MANUAL_REVIEW')
        )
        AND dq.commit_scn <= v_last_applied_scn
        AND dq.extracted_at < v_cutoff_ts;

        -- 削除後の残存件数を確認
        SELECT COUNT(*) INTO v_remain_count FROM staging_ctl.delta_queue;

        COMMIT;

        DBMS_OUTPUT.PUT_LINE('delta_purge_tgt: deleted=' || v_purge_count
            || ' remain_after_purge=' || v_remain_count
            || ' status=SUCCESS');

    EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('delta_purge_tgt: FAILED err=' || SUBSTR(SQLERRM, 1, 3900));
        RAISE;
    END;

END delta_purge_tgt;
/
SHOW ERRORS PROCEDURE SYS.delta_purge_tgt;

PROMPT SYS.delta_purge_tgt created on oracle-tgt.
EXIT;
