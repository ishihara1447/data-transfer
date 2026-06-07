-- 差分抽出方式: SYS.delta_apply プロシージャ (oracle-tgt 用) ★Phase1: COMMIT_SCN版
-- 搬送されてきた staging_ctl.delta_queue の未適用Txを STAGING_SCHEMA に適用する。
--
-- ★Phase1 改修点（docs/phase1-commit-scn-redesign.md）:
--   G4: apply_ledger でトランザクション単位の冪等性を担保
--   - 適用順序を commit_scn, xid, seq_in_tx 順に変更
--   - トランザクション境界（xid 変化）で COMMIT し部分適用を防ぐ
--   - last_applied_commit_scn で再開点を管理
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
    v_sql            VARCHAR2(4000);
    v_applied_tx     NUMBER := 0;   -- 適用したTx数
    v_applied_rows   NUMBER := 0;   -- 適用した行数
    v_failed_tx      NUMBER := 0;   -- 失敗Tx数
    v_skipped_tx     NUMBER := 0;   -- 冪等スキップTx数
    v_err_msg        VARCHAR2(4000);
    v_max_commit     NUMBER := 0;

    -- 現在処理中のトランザクション状態
    v_cur_xid        VARCHAR2(40)  := NULL;
    v_cur_commit     NUMBER        := NULL;
    v_cur_rows       NUMBER        := 0;
    v_cur_failed     BOOLEAN       := FALSE;
    v_cur_skip       BOOLEAN       := FALSE;

    -- (xid, commit_scn) が既に適用済みか
    FUNCTION already_applied(p_xid VARCHAR2, p_commit NUMBER) RETURN BOOLEAN IS
        v_cnt NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_cnt FROM staging_ctl.apply_ledger
        WHERE xid = p_xid AND commit_scn = p_commit AND status = 'APPLIED';
        RETURN v_cnt > 0;
    END already_applied;

    -- 1トランザクション分を確定する（COMMIT + 台帳記録）
    PROCEDURE finalize_tx IS
    BEGIN
        IF v_cur_xid IS NULL OR v_cur_skip THEN
            RETURN;  -- 処理対象なし or スキップ済み
        END IF;

        IF v_cur_failed THEN
            -- 失敗Txはロールバックし、台帳に FAILED 記録（再実行で再試行可）
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
            -- 成功: 台帳に APPLIED 記録してから COMMIT（同一Tx内で原子的に）
            -- MERGE で記録（前回 FAILED 記録があれば APPLIED に更新。PK重複回避）
            MERGE INTO staging_ctl.apply_ledger l
            USING (SELECT v_cur_xid AS xid, v_cur_commit AS commit_scn FROM DUAL) s
            ON (l.xid = s.xid AND l.commit_scn = s.commit_scn)
            WHEN MATCHED THEN
                UPDATE SET status = 'APPLIED', change_count = v_cur_rows,
                           applied_at = SYSTIMESTAMP, error_message = NULL
            WHEN NOT MATCHED THEN
                INSERT (xid, commit_scn, change_count, status)
                VALUES (v_cur_xid, v_cur_commit, v_cur_rows, 'APPLIED');
            COMMIT;
            v_applied_tx  := v_applied_tx + 1;
            v_applied_rows := v_applied_rows + v_cur_rows;
            IF v_cur_commit > v_max_commit THEN
                v_max_commit := v_cur_commit;
            END IF;
        END IF;
    END finalize_tx;

BEGIN
    SELECT last_applied_commit_scn INTO v_last_commit
    FROM staging_ctl.delta_apply_state WHERE run_name = p_run_name;

    -- 未適用差分を commit_scn, xid, seq_in_tx 順に処理
    -- （トランザクション境界でグルーピングして適用）
    FOR rec IN (
        SELECT delta_id, commit_scn, xid, seq_in_tx,
               table_name, operation, sql_redo
        FROM staging_ctl.delta_queue
        WHERE commit_scn > v_last_commit
        ORDER BY commit_scn, xid, seq_in_tx
    ) LOOP
        -- トランザクション境界の検出（xid または commit_scn の変化）
        IF v_cur_xid IS NULL
           OR rec.xid != v_cur_xid
           OR rec.commit_scn != v_cur_commit
        THEN
            -- 直前のTxを確定
            finalize_tx;

            -- 新しいTxの開始
            v_cur_xid    := rec.xid;
            v_cur_commit := rec.commit_scn;
            v_cur_rows   := 0;
            v_cur_failed := FALSE;
            -- ★G4: 冪等性チェック。既適用ならこのTxはスキップ
            v_cur_skip   := already_applied(rec.xid, rec.commit_scn);
            IF v_cur_skip THEN
                v_skipped_tx := v_skipped_tx + 1;
            END IF;
        END IF;

        -- スキップ対象Tx・失敗確定済みTxはこれ以上処理しない
        IF v_cur_skip OR v_cur_failed THEN
            CONTINUE;
        END IF;

        -- SRC_SCHEMA → STAGING_SCHEMA 置換
        v_sql := rec.sql_redo;
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
            -- このTxは失敗確定。残りの操作はスキップし、finalize で ROLLBACK。
            v_cur_failed := TRUE;
            v_err_msg := 'delta_id=' || rec.delta_id || ' ' || SUBSTR(SQLERRM, 1, 3900);
            DBMS_OUTPUT.PUT_LINE(
                'WARN tx_fail xid=' || rec.xid ||
                ' commit_scn=' || rec.commit_scn ||
                ' err=' || v_err_msg);
        END;
    END LOOP;

    -- 最後のTxを確定
    finalize_tx;

    -- ★再開点更新: last_applied_commit_scn を「適用しきった最大commit_scn」に
    --   失敗Txがあった場合、その commit_scn は超えないようにする（再試行のため）
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

        -- FAILED が無い場合は上の MIN が NULL→v_max_commit になり正しく進む
        -- FAILED がある場合は最小の失敗commit_scn-1 で止まる（その手前まで確定）
        COMMIT;
    END IF;

    DBMS_OUTPUT.PUT_LINE(
        'delta_apply: applied_tx=' || v_applied_tx ||
        ' rows=' || v_applied_rows ||
        ' skipped_tx=' || v_skipped_tx ||
        ' failed_tx=' || v_failed_tx ||
        ' max_commit_scn=' || v_max_commit);

EXCEPTION WHEN OTHERS THEN
    v_err_msg := SUBSTR(SQLERRM, 1, 4000);
    BEGIN ROLLBACK; EXCEPTION WHEN OTHERS THEN NULL; END;
    DBMS_OUTPUT.PUT_LINE('delta_apply FATAL: ' || v_err_msg);
    RAISE;
END delta_apply;
/
SHOW ERRORS PROCEDURE SYS.delta_apply;

PROMPT SYS.delta_apply (COMMIT_SCN/ledger version) created on oracle-tgt.
EXIT;
