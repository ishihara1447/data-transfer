-- delta_queue パージ: SYS.delta_purge_src プロシージャ (oracle-src 用)
-- cdc_schema.delta_queue の搬送済み・適用済み行を安全な条件下でパージする。
--
-- 安全条件（この条件を満たす行のみ削除する）:
--   1. delta_id <= p_tgt_max_delta_id（tgt の MAX(delta_id) = 搬送済みの根拠）
--   2. commit_scn <= p_tgt_last_applied_scn（tgt で適用済み。この SCN より後の行は残す）
--   3. extracted_at < SYSTIMESTAMP - (p_retention_min/1440)（保持マージン経過済み。分→日換算）
--
-- tgt との役割分離について:
--   src の PL/SQL からは tgt DB に直接接続しない（DB Link 禁止・役割分離の原則）。
--   tgt 側の2値（MAX(delta_id) と last_applied_commit_scn）はシェル(45_purge_cycle.sh)が
--   tgt を照会して取得し、このプロシージャに引数として渡す。
--
-- delta_queue と LogMiner (採掘)の関係:
--   delta_extract は V$LOGMNR_CONTENTS（REDOログ）を採掘して delta_queue に書き込む。
--   逆に delta_queue は採掘には不要（採掘はREDOを直接読む）。
--   delta_queue は「搬送待ちの差分データ」の一時蓄積場所であり、搬送・適用が完了した
--   行を削除してもLogMinerの再開（mine_start_scn/last_extracted_commit_scn）には影響しない。
--   commit済み行のみが対象のため、未コミットTxが絡む可能性は commit_scn 条件で排除される。
--
-- パラメータ:
--   p_tgt_max_delta_id      : tgt.staging_ctl.delta_queue の MAX(delta_id)（搬送済みの証拠）
--   p_tgt_last_applied_scn  : tgt.staging_ctl.delta_apply_state.last_applied_commit_scn
--   p_retention_min         : 保持マージン分数（既定 60）
--   p_dry_run               : 'Y' なら削除せず対象件数のみ DBMS_OUTPUT。'N' なら実削除。
--
-- 冪等性: CREATE OR REPLACE のため再実行可能。削除ロジックも条件ベースで冪等。
-- 実行ユーザー: SYS AS SYSDBA / 実行対象: oracle-src XEPDB1

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

SET SERVEROUTPUT ON SIZE UNLIMITED

CREATE OR REPLACE PROCEDURE SYS.delta_purge_src(
    p_tgt_max_delta_id     IN NUMBER,
    p_tgt_last_applied_scn IN NUMBER,
    p_retention_min        IN NUMBER   DEFAULT 60,
    p_dry_run              IN VARCHAR2 DEFAULT 'Y'
)
    AUTHID CURRENT_USER
AS
    v_purge_count   NUMBER := 0;
    v_remain_count  NUMBER := 0;
    v_total_count   NUMBER := 0;
    v_retention_min NUMBER;
    v_cutoff_ts     TIMESTAMP;
BEGIN
    -- 保持マージンの決定（引数が NULL の場合は 60 分をデフォルトとする）
    v_retention_min := NVL(p_retention_min, 60);

    -- tgt の値が未取得（0 または負）の場合は安全のためスキップ
    IF NVL(p_tgt_max_delta_id, 0) <= 0 OR NVL(p_tgt_last_applied_scn, 0) <= 0 THEN
        DBMS_OUTPUT.PUT_LINE('delta_purge_src: tgt values not ready'
            || ' max_delta_id=' || NVL(TO_CHAR(p_tgt_max_delta_id), 'NULL')
            || ' last_applied_scn=' || NVL(TO_CHAR(p_tgt_last_applied_scn), 'NULL')
            || '. abort.');
        RETURN;
    END IF;

    -- 保持マージンのカットオフ時刻（この時刻より新しい行は残す）
    v_cutoff_ts := SYSTIMESTAMP - (v_retention_min / (24 * 60));

    DBMS_OUTPUT.PUT_LINE('delta_purge_src:'
        || ' tgt_max_delta_id=' || p_tgt_max_delta_id
        || ' tgt_last_applied_scn=' || p_tgt_last_applied_scn
        || ' retention_min=' || v_retention_min
        || ' dry_run=' || p_dry_run);

    -- 現在の総件数
    SELECT COUNT(*) INTO v_total_count FROM cdc_schema.delta_queue;

    -- パージ対象件数を計算
    -- 削除可能条件:
    --   a) delta_id <= p_tgt_max_delta_id（搬送済み: tgt に到達している）
    --   b) commit_scn <= p_tgt_last_applied_scn（適用済み: tgt で処理完了）
    --   c) extracted_at < cutoff_ts（保持マージン経過済み）
    -- 残す行（削除しない）:
    --   - tgt に届いていない行（delta_id > p_tgt_max_delta_id）
    --   - tgt でまだ適用されていない行（commit_scn > p_tgt_last_applied_scn）
    --   - 保持マージン内の行（トラブル調査のため）
    SELECT COUNT(*) INTO v_purge_count
    FROM cdc_schema.delta_queue
    WHERE delta_id <= p_tgt_max_delta_id
      AND commit_scn <= p_tgt_last_applied_scn
      AND extracted_at < v_cutoff_ts;

    v_remain_count := v_total_count - v_purge_count;

    DBMS_OUTPUT.PUT_LINE('delta_purge_src: total=' || v_total_count
        || ' purge_target=' || v_purge_count
        || ' remain=' || v_remain_count);

    IF p_dry_run = 'Y' THEN
        DBMS_OUTPUT.PUT_LINE('delta_purge_src: DRY_RUN mode. no rows deleted.');
        RETURN;
    END IF;

    -- 実削除（p_dry_run != 'Y'）
    BEGIN
        DELETE FROM cdc_schema.delta_queue
        WHERE delta_id <= p_tgt_max_delta_id
          AND commit_scn <= p_tgt_last_applied_scn
          AND extracted_at < v_cutoff_ts;

        -- 削除後の残存件数を確認
        SELECT COUNT(*) INTO v_remain_count FROM cdc_schema.delta_queue;

        COMMIT;

        DBMS_OUTPUT.PUT_LINE('delta_purge_src: deleted=' || v_purge_count
            || ' remain_after_purge=' || v_remain_count
            || ' status=SUCCESS');

    EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('delta_purge_src: FAILED err=' || SUBSTR(SQLERRM, 1, 3900));
        RAISE;
    END;

END delta_purge_src;
/
SHOW ERRORS PROCEDURE SYS.delta_purge_src;

PROMPT SYS.delta_purge_src created on oracle-src.
EXIT;
