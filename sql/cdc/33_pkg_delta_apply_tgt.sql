-- 差分抽出方式: SYS.delta_apply プロシージャ (oracle-tgt 用) ★Phase2: replay_allowed判定版
-- 搬送されてきた staging_ctl.delta_queue の未適用Txを STAGING_SCHEMA に適用する。
--
-- ★Phase1 改修点（docs/phase1-commit-scn-redesign.md）:
--   G4: apply_ledger でトランザクション単位の冪等性を担保
--   - 適用順序を commit_scn, xid, seq_in_tx 順に変更
--   - トランザクション境界（xid 変化）で COMMIT し部分適用を防ぐ
--   - last_applied_commit_scn で再開点を管理
--
-- ★Phase2 追加（docs/delta-extract-design.md セクション9）:
--   - replay_allowed='N' のイベントは EXECUTE IMMEDIATE しない
--   - 代わりに staging_ctl.delta_manual_review_queue へ記録（手動調査対象）
--   - 適用には sql_redo_assembled (CSF連結済みCLOB) を優先使用
--   - apply_ledger の status に 'PARTIAL' / 'MANUAL_REVIEW' を追加
--   - replay_allowed='N' 行のみのTxは 'MANUAL_REVIEW' として記録（再処理しない）
--   - replay_allowed='Y'+'N' 混在Txは 'PARTIAL' として記録（Y行のみ適用・コミット）
--
-- 冪等性ルール:
--   - (xid, commit_scn) が apply_ledger にあれば適用済み → スキップ
--   - 適用後に apply_ledger へ記録
--   - 同一ダンプを二度ロードしても二重適用しない
--
-- 実行ユーザー: SYS AS SYSDBA / 実行対象: oracle-tgt XEPDB1（ローカル適用）

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

CREATE OR REPLACE PROCEDURE SYS.delta_apply(
    p_run_name IN VARCHAR2 DEFAULT 'delta_run_01'
)
    AUTHID CURRENT_USER
AS
    v_last_commit    NUMBER;
    v_sql            VARCHAR2(32767);  -- 拡張: CSF連結後は4000超になりうる
    v_applied_tx     NUMBER := 0;
    v_applied_rows   NUMBER := 0;
    v_failed_tx      NUMBER := 0;
    v_skipped_tx     NUMBER := 0;
    v_review_events  NUMBER := 0;
    v_err_msg        VARCHAR2(4000);
    v_max_commit     NUMBER := 0;

    -- 現在処理中のトランザクション状態
    v_cur_xid        VARCHAR2(40)  := NULL;
    v_cur_commit     NUMBER        := NULL;
    v_cur_rows       NUMBER        := 0;   -- 正常適用した行数
    v_cur_review     NUMBER        := 0;   -- 手動調査キューへ送った行数
    v_cur_failed     BOOLEAN       := FALSE;
    v_cur_skip       BOOLEAN       := FALSE;

    -- (xid, commit_scn) が既に処理済みか（APPLIED/PARTIAL/MANUAL_REVIEW/FAILED）
    FUNCTION already_applied(p_xid VARCHAR2, p_commit NUMBER) RETURN BOOLEAN IS
        v_cnt NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_cnt FROM staging_ctl.apply_ledger
        WHERE xid = p_xid AND commit_scn = p_commit
          AND status IN ('APPLIED', 'PARTIAL', 'MANUAL_REVIEW');
        RETURN v_cnt > 0;
    END already_applied;

    -- manual_review_queue への記録: AUTONOMOUS_TRANSACTION で外部COMMIT
    -- メインTxのROLLBACKに巻き込まれないよう独立コミット
    PROCEDURE log_to_review_queue(
        p_delta_id      NUMBER,
        p_commit_scn    NUMBER,
        p_xid           VARCHAR2,
        p_table_name    VARCHAR2,
        p_operation     VARCHAR2,
        p_op_code       NUMBER,
        p_status_code   NUMBER,
        p_info_text     VARCHAR2,
        p_replay_cat    VARCHAR2,
        p_fallback_rsn  VARCHAR2,
        p_sql_assembled CLOB
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO staging_ctl.delta_manual_review_queue
            (batch_delta_id, commit_scn, xid, seg_owner, seg_name,
             operation, operation_code, status_code, info_text,
             replay_category, fallback_reason, sql_redo_assembled)
        VALUES
            (p_delta_id, p_commit_scn, p_xid,
             'SRC_SCHEMA', p_table_name,
             p_operation, p_op_code, p_status_code, p_info_text,
             p_replay_cat, p_fallback_rsn, p_sql_assembled);
        COMMIT;
    EXCEPTION WHEN OTHERS THEN
        ROLLBACK;  -- キュー記録失敗はメイン処理を止めない
    END log_to_review_queue;

    -- 1トランザクション分を確定する（COMMIT or ROLLBACK + 台帳記録）
    PROCEDURE finalize_tx IS
        v_tx_status VARCHAR2(20);
    BEGIN
        IF v_cur_xid IS NULL OR v_cur_skip THEN
            RETURN;
        END IF;

        IF v_cur_failed THEN
            -- 失敗: ROLLBACK して FAILED 記録
            ROLLBACK;
            MERGE INTO staging_ctl.apply_ledger l
            USING (SELECT v_cur_xid AS xid, v_cur_commit AS commit_scn FROM DUAL) s
            ON (l.xid = s.xid AND l.commit_scn = s.commit_scn)
            WHEN MATCHED THEN
                UPDATE SET status = 'FAILED', error_message = v_err_msg,
                           applied_at = SYSTIMESTAMP
            WHEN NOT MATCHED THEN
                INSERT (xid, commit_scn, change_count, status, error_message)
                VALUES (v_cur_xid, v_cur_commit, v_cur_rows, 'FAILED', v_err_msg);
            COMMIT;
            v_failed_tx := v_failed_tx + 1;

        ELSE
            -- 成功系: 適用行数 vs 調査行数で status を決定
            IF v_cur_rows > 0 AND v_cur_review = 0 THEN
                v_tx_status := 'APPLIED';
                v_applied_tx  := v_applied_tx + 1;
                v_applied_rows := v_applied_rows + v_cur_rows;
                IF v_cur_commit > v_max_commit THEN
                    v_max_commit := v_cur_commit;
                END IF;
            ELSIF v_cur_rows > 0 AND v_cur_review > 0 THEN
                -- 一部適用・一部調査: STAGING への適用は COMMIT し PARTIAL 記録
                v_tx_status := 'PARTIAL';
                v_applied_tx  := v_applied_tx + 1;
                v_applied_rows := v_applied_rows + v_cur_rows;
                IF v_cur_commit > v_max_commit THEN
                    v_max_commit := v_cur_commit;
                END IF;
            ELSE
                -- 全行が手動調査へ（STAGING 適用なし）
                v_tx_status := 'MANUAL_REVIEW';
                -- max_commit は前進させる（再処理しないため）
                IF v_cur_commit > v_max_commit THEN
                    v_max_commit := v_cur_commit;
                END IF;
            END IF;

            -- 台帳記録してから COMMIT（APPLIED/PARTIAL は STAGING DML も含む）
            MERGE INTO staging_ctl.apply_ledger l
            USING (SELECT v_cur_xid AS xid, v_cur_commit AS commit_scn FROM DUAL) s
            ON (l.xid = s.xid AND l.commit_scn = s.commit_scn)
            WHEN MATCHED THEN
                UPDATE SET status = v_tx_status, change_count = v_cur_rows,
                           applied_at = SYSTIMESTAMP, error_message = NULL
            WHEN NOT MATCHED THEN
                INSERT (xid, commit_scn, change_count, status)
                VALUES (v_cur_xid, v_cur_commit, v_cur_rows, v_tx_status);
            COMMIT;
        END IF;
    END finalize_tx;

BEGIN
    SELECT last_applied_commit_scn INTO v_last_commit
    FROM staging_ctl.delta_apply_state WHERE run_name = p_run_name;

    -- 未適用差分を commit_scn, xid, seq_in_tx 順に処理
    FOR rec IN (
        SELECT delta_id, commit_scn, xid, seq_in_tx,
               table_name, operation, operation_code, status_code, info_text,
               sql_redo, sql_redo_assembled,
               replay_category, replay_allowed, fallback_reason
        FROM staging_ctl.delta_queue
        WHERE commit_scn > v_last_commit
        ORDER BY commit_scn, xid, seq_in_tx
    ) LOOP
        -- トランザクション境界の検出（xid または commit_scn の変化）
        IF v_cur_xid IS NULL
           OR rec.xid != v_cur_xid
           OR rec.commit_scn != v_cur_commit
        THEN
            finalize_tx;

            v_cur_xid    := rec.xid;
            v_cur_commit := rec.commit_scn;
            v_cur_rows   := 0;
            v_cur_review := 0;
            v_cur_failed := FALSE;
            -- ★G4: 冪等性チェック
            v_cur_skip   := already_applied(rec.xid, rec.commit_scn);
            IF v_cur_skip THEN
                v_skipped_tx := v_skipped_tx + 1;
            END IF;
        END IF;

        IF v_cur_skip OR v_cur_failed THEN
            CONTINUE;
        END IF;

        -- ★Phase2: replay_allowed='N' のイベントは手動調査キューへ送る
        IF NVL(rec.replay_allowed, 'N') != 'Y' THEN
            log_to_review_queue(
                rec.delta_id, rec.commit_scn, rec.xid,
                rec.table_name, rec.operation,
                rec.operation_code, rec.status_code, rec.info_text,
                rec.replay_category, rec.fallback_reason,
                rec.sql_redo_assembled
            );
            v_cur_review  := v_cur_review + 1;
            v_review_events := v_review_events + 1;
            CONTINUE;
        END IF;

        -- replay_allowed='Y': STAGING_SCHEMA へ適用
        -- sql_redo_assembled (CSF連結済みCLOB) を優先し、なければ sql_redo を使用
        v_sql := NVL(
            DBMS_LOB.SUBSTR(rec.sql_redo_assembled, 32767, 1),
            rec.sql_redo
        );

        -- SRC_SCHEMA → STAGING_SCHEMA 置換
        v_sql := REPLACE(v_sql, '"SRC_SCHEMA"', '"STAGING_SCHEMA"');
        v_sql := REPLACE(v_sql, 'SRC_SCHEMA.',  'STAGING_SCHEMA.');

        -- LogMiner の SQL_REDO 末尾セミコロンを除去（EXECUTE IMMEDIATE は不可）
        v_sql := RTRIM(v_sql);
        IF SUBSTR(v_sql, -1) = ';' THEN
            v_sql := SUBSTR(v_sql, 1, LENGTH(v_sql) - 1);
        END IF;

        BEGIN
            EXECUTE IMMEDIATE v_sql;
            v_cur_rows := v_cur_rows + 1;
        EXCEPTION WHEN OTHERS THEN
            v_cur_failed := TRUE;
            v_err_msg := 'delta_id=' || rec.delta_id || ' ' || SUBSTR(SQLERRM, 1, 3900);
            DBMS_OUTPUT.PUT_LINE(
                'WARN tx_fail xid=' || rec.xid ||
                ' commit_scn=' || rec.commit_scn ||
                ' table=' || rec.table_name ||
                ' op=' || rec.operation ||
                ' err=' || v_err_msg);
        END;
    END LOOP;

    finalize_tx;

    -- ★再開点更新: last_applied_commit_scn を「適用しきった最大commit_scn」に
    IF v_max_commit > v_last_commit THEN
        UPDATE staging_ctl.delta_apply_state
        SET last_applied_commit_scn =
                (SELECT NVL(MIN(commit_scn) - 1, v_max_commit)
                 FROM staging_ctl.apply_ledger
                 WHERE status = 'FAILED' AND commit_scn > v_last_commit),
            applied_tx_count  = applied_tx_count + v_applied_tx,
            applied_row_count = applied_row_count + v_applied_rows,
            failed_tx_count   = failed_tx_count + v_failed_tx,
            last_run_at       = SYSTIMESTAMP
        WHERE run_name = p_run_name;
        COMMIT;
    END IF;

    DBMS_OUTPUT.PUT_LINE(
        'delta_apply: applied_tx=' || v_applied_tx ||
        ' rows=' || v_applied_rows ||
        ' skipped_tx=' || v_skipped_tx ||
        ' failed_tx=' || v_failed_tx ||
        ' review_events=' || v_review_events ||
        ' max_commit_scn=' || v_max_commit);

EXCEPTION WHEN OTHERS THEN
    v_err_msg := SUBSTR(SQLERRM, 1, 4000);
    BEGIN ROLLBACK; EXCEPTION WHEN OTHERS THEN NULL; END;
    DBMS_OUTPUT.PUT_LINE('delta_apply FATAL: ' || v_err_msg);
    RAISE;
END delta_apply;
/
SHOW ERRORS PROCEDURE SYS.delta_apply;

PROMPT SYS.delta_apply (Phase2: replay_allowed check + manual review routing) created on oracle-tgt.
EXIT;
