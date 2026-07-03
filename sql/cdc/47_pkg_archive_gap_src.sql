-- アーカイブログ連番欠落チェック: SYS.archive_gap_check プロシージャ (oracle-src 用)
-- CDC再開に必要なアーカイブログの連番欠落・削除欠落を検知する。
--
-- 背景:
--   差分抽出(delta_extract)は START_LOGMNR(STARTSCN=>mine_start_scn) でREDOを採掘する。
--   mine_start_scn を含むアーカイブログが削除されていると、その区間を再採掘できず
--   サイレントデータ欠落になる（「10日でarchive消滅しCDC再開不能」実体験 参照）。
--   本プロシージャは以下の2種類の欠落を検知する:
--     1. 削除欠落（重大）: mine_start_scn 以降のログが deleted='YES' または STATUS!='A'
--     2. 連番欠番（予兆）: THREAD#単位で SEQUENCE# が飛んでいる
--
-- 出力（DBMS_OUTPUT）:
--   サマリ行（機械可読1行）:
--     ARCHIVE_GAP: needed_scn=<LW> missing_needed=<n> seq_gaps_total=<n>
--                  seq_gaps_in_needed=<n> oldest_avail_scn=<scn> status=<OK|WARN|CRIT>
--   p_verbose='Y' のとき追加で欠番 SEQUENCE# の一覧・削除済みログ明細を出力する。
--
-- 実行コンテキスト:
--   SYS AS SYSDBA で CDB$ROOT から実行（V$ARCHIVED_LOG は CDB 共通）。
--   delta_extract_state は XEPDB1 にあるため ALTER SESSION SET CONTAINER で切り替え。
--
-- 実行ユーザー: SYS AS SYSDBA / 実行対象: oracle-src CDB$ROOT → XEPDB1
-- Oracle 12c 互換 / 冪等（CREATE OR REPLACE）

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA

CREATE OR REPLACE PROCEDURE SYS.archive_gap_check(
    p_run_name IN VARCHAR2 DEFAULT 'delta_run_01',
    p_verbose  IN VARCHAR2 DEFAULT 'N'
)
    AUTHID CURRENT_USER
AS
    -- 内部変数
    v_mine_start_scn    NUMBER := 0;   -- LW: CDC再開に必要な最古SCN
    v_oldest_avail_scn  NUMBER := 0;   -- 現存ログの最古 FIRST_CHANGE#
    v_max_next_change   NUMBER := 0;   -- 現存ログの最新 NEXT_CHANGE#（カバー上限）

    v_missing_needed    NUMBER := 0;   -- 必要範囲内で削除済みのログ本数
    v_seq_gaps_total    NUMBER := 0;   -- THREAD#全体の連番欠番数（合計）
    v_seq_gaps_in_need  NUMBER := 0;   -- 必要範囲に掛かる連番欠番数

    v_status            VARCHAR2(4) := 'OK';
    v_container         VARCHAR2(30) := 'CDB$ROOT';

    -- 欠番行の詳細格納用
    TYPE t_gap_rec IS RECORD (
        thread_no    NUMBER,
        gap_from_seq NUMBER,   -- gap 直前の SEQUENCE#（この次から欠番）
        gap_to_seq   NUMBER,   -- gap 直後の SEQUENCE#（ここから存在）
        gap_count    NUMBER,   -- 欠番の本数
        in_needed    VARCHAR2(1)  -- Y=必要範囲に掛かる
    );
    TYPE t_gap_tab IS TABLE OF t_gap_rec INDEX BY PLS_INTEGER;
    v_gaps t_gap_tab;
    v_gap_idx PLS_INTEGER := 0;

    -- 削除済みログ詳細格納用
    TYPE t_del_rec IS RECORD (
        thread_no   NUMBER,
        sequence_no NUMBER,
        first_scn   NUMBER,
        next_scn    NUMBER,
        del_flag    VARCHAR2(3),
        stat_code   VARCHAR2(1)
    );
    TYPE t_del_tab IS TABLE OF t_del_rec INDEX BY PLS_INTEGER;
    v_dels t_del_tab;
    v_del_idx PLS_INTEGER := 0;

    PROCEDURE go_to(p_container IN VARCHAR2) IS
    BEGIN
        IF v_container != p_container THEN
            EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = ' || p_container;
            v_container := p_container;
        END IF;
    END go_to;

BEGIN
    -- ───────────────────────────────────────────
    -- フェーズ1: XEPDB1 で mine_start_scn（LW）を取得
    -- ───────────────────────────────────────────
    go_to('XEPDB1');

    BEGIN
        EXECUTE IMMEDIATE
            'SELECT mine_start_scn FROM cdc_schema.delta_extract_state WHERE run_name = :1'
        INTO v_mine_start_scn
        USING p_run_name;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            v_mine_start_scn := 0;
    END;

    -- ───────────────────────────────────────────
    -- フェーズ2: CDB$ROOT で V$ARCHIVED_LOG を解析
    -- ───────────────────────────────────────────
    go_to('CDB$ROOT');

    -- 現存ログの最古 FIRST_CHANGE#（oldest_avail_scn）と最新 NEXT_CHANGE#（max_next_change）
    BEGIN
        SELECT NVL(MIN(first_change#), 0), NVL(MAX(next_change#), 0)
        INTO v_oldest_avail_scn, v_max_next_change
        FROM v$archived_log
        WHERE dest_id = 1
          AND deleted = 'NO'
          AND status  = 'A';
    EXCEPTION
        WHEN OTHERS THEN
            v_oldest_avail_scn  := 0;
            v_max_next_change   := 0;
    END;

    -- 削除欠落チェック（重大）:
    --   mine_start_scn 以降の範囲を含む（next_change# > mine_start_scn）ログのうち
    --   deleted='YES'、または STATUS!='A' （存在確認不可）の本数を数える。
    --   dest_id=1（主アーカイブ先）を対象とする。
    BEGIN
        SELECT COUNT(*)
        INTO v_missing_needed
        FROM v$archived_log
        WHERE dest_id = 1
          AND next_change# > v_mine_start_scn
          AND (deleted = 'YES' OR status != 'A');
    EXCEPTION
        WHEN OTHERS THEN
            v_missing_needed := 0;
    END;

    -- 連番欠番チェック（LAG 解析関数・12c 互換）:
    --   現存ログ（deleted='NO' AND status='A' AND dest_id=1）の SEQUENCE# を
    --   THREAD# 毎に順番に並べ、LAG で前の SEQUENCE# を取得。
    --   sequence# > prev_seq + 1 であれば欠番が存在する。
    --
    -- 補足: LAG の第3引数（default）に sequence# - 1 を渡す。
    --   これにより最初の行は prev_seq = sequence# - 1 となり、欠番なしと判定される。
    --   ただし、最初の行が sequence# = 1 でなく、その前に欠番があっても
    --   実際の欠番はログ保持開始前の話であり検知対象外（保持範囲外）。
    --
    -- seq_gaps_in_needed の判定:
    --   欠番ブロック（gap_from_seq+1 〜 gap_to_seq-1）に相当するアーカイブログが
    --   mine_start_scn 以降の範囲に掛かるかを判定する。
    --   欠番ブロックは実在しないため FIRST_CHANGE# / NEXT_CHANGE# が不明だが、
    --   直後に存在するアーカイブログ（gap_to_seq）の FIRST_CHANGE# を代替として使用する。
    --   gap_to_seq のログの FIRST_CHANGE# が mine_start_scn より小さいか等しい場合、
    --   欠番ブロックは必要範囲より前（安全）。
    --   gap_to_seq のログの FIRST_CHANGE# が mine_start_scn より大きい場合、
    --   欠番ブロックが必要範囲内（CRIT/WARN）。
    DECLARE
        CURSOR c_gaps IS
            SELECT
                thread#,
                sequence#                AS curr_seq,
                first_change#            AS curr_fc,
                LAG(sequence#, 1, sequence# - 1)
                    OVER (PARTITION BY thread# ORDER BY sequence#) AS prev_seq
            FROM v$archived_log
            WHERE dest_id = 1
              AND deleted  = 'NO'
              AND status   = 'A'
            ORDER BY thread#, sequence#;
        v_in_need VARCHAR2(1);
    BEGIN
        FOR rec IN c_gaps LOOP
            IF rec.curr_seq > rec.prev_seq + 1 THEN
                -- 欠番が存在: prev_seq+1 〜 curr_seq-1 が欠番
                v_gap_idx := v_gap_idx + 1;
                v_gaps(v_gap_idx).thread_no    := rec.thread#;
                v_gaps(v_gap_idx).gap_from_seq := rec.prev_seq;
                v_gaps(v_gap_idx).gap_to_seq   := rec.curr_seq;
                v_gaps(v_gap_idx).gap_count    := rec.curr_seq - rec.prev_seq - 1;

                -- 必要範囲への掛かり判定: gap 直後ログ(curr_seq)の FIRST_CHANGE# と LW を比較
                -- curr_fc > mine_start_scn の場合: 欠番ブロックは必要範囲に掛かる可能性あり
                -- curr_fc <= mine_start_scn の場合: 欠番ブロックは必要範囲より前（安全）
                IF rec.curr_fc > v_mine_start_scn THEN
                    v_in_need := 'Y';
                    v_seq_gaps_in_need := v_seq_gaps_in_need + (rec.curr_seq - rec.prev_seq - 1);
                ELSE
                    v_in_need := 'N';
                END IF;
                v_gaps(v_gap_idx).in_needed := v_in_need;
                v_seq_gaps_total := v_seq_gaps_total + (rec.curr_seq - rec.prev_seq - 1);
            END IF;
        END LOOP;
    END;

    -- p_verbose='Y' の場合: 削除済みログ明細を収集
    IF UPPER(p_verbose) = 'Y' THEN
        DECLARE
            CURSOR c_del IS
                SELECT thread#, sequence#, first_change#, next_change#, deleted, status
                FROM v$archived_log
                WHERE dest_id = 1
                  AND next_change# > v_mine_start_scn
                  AND (deleted = 'YES' OR status != 'A')
                ORDER BY thread#, sequence#;
        BEGIN
            FOR rec IN c_del LOOP
                v_del_idx := v_del_idx + 1;
                v_dels(v_del_idx).thread_no   := rec.thread#;
                v_dels(v_del_idx).sequence_no := rec.sequence#;
                v_dels(v_del_idx).first_scn   := rec.first_change#;
                v_dels(v_del_idx).next_scn    := rec.next_change#;
                v_dels(v_del_idx).del_flag    := rec.deleted;
                v_dels(v_del_idx).stat_code   := rec.status;
            END LOOP;
        END;
    END IF;

    -- ───────────────────────────────────────────
    -- フェーズ3: status 判定
    -- 優先順位: CRIT > WARN > OK
    --
    -- CRIT 条件（いずれか1つでも該当すれば CRIT）:
    --   (a) 必要範囲内で削除済みのログが存在する（missing_needed > 0）
    --   (b) 必要範囲内に連番欠番がある（seq_gaps_in_need > 0）
    --   (c) oldest_avail_scn > mine_start_scn:
    --         現存最古 FIRST_CHANGE# が LW より後 = LW を含むログが消えている
    --         例: archiveが10日で消え、LWが古い日付を指している場合
    --         ★正常状態: mine_start_scn >= oldest_avail_scn かつ
    --                    mine_start_scn <= max_next_change（オンラインREDO含む採掘範囲内）
    --         ★正常状態: mine_start_scn > max_next_change はオンラインREDOを採掘する
    --                    通常運用状態（アーカイブ化前のREDO。delta_extract の add_logfiles で追加済み）
    -- ───────────────────────────────────────────
    IF v_missing_needed > 0
        OR v_seq_gaps_in_need > 0
        OR (v_oldest_avail_scn > 0 AND v_mine_start_scn > 0
            AND v_oldest_avail_scn > v_mine_start_scn)
    THEN
        v_status := 'CRIT';
    ELSIF v_seq_gaps_total > 0 THEN
        v_status := 'WARN';
    ELSE
        v_status := 'OK';
    END IF;

    -- ───────────────────────────────────────────
    -- フェーズ4: DBMS_OUTPUT サマリ行（機械可読1行）
    -- 形式: ARCHIVE_GAP: needed_scn=<LW> missing_needed=<n> seq_gaps_total=<n>
    --                    seq_gaps_in_needed=<n> oldest_avail_scn=<scn> status=<OK|WARN|CRIT>
    -- ───────────────────────────────────────────
    DBMS_OUTPUT.PUT_LINE(
        'ARCHIVE_GAP:'
        || ' needed_scn='        || TO_CHAR(v_mine_start_scn)
        || ' missing_needed='    || TO_CHAR(v_missing_needed)
        || ' seq_gaps_total='    || TO_CHAR(v_seq_gaps_total)
        || ' seq_gaps_in_needed='|| TO_CHAR(v_seq_gaps_in_need)
        || ' oldest_avail_scn='  || TO_CHAR(v_oldest_avail_scn)
        || ' status='            || v_status
    );

    -- p_verbose='Y' の場合: 詳細情報を追加出力
    IF UPPER(p_verbose) = 'Y' THEN
        -- 欠番詳細
        IF v_gap_idx > 0 THEN
            DBMS_OUTPUT.PUT_LINE('--- SEQ_GAP DETAIL (total=' || v_gap_idx || ' gaps) ---');
            DECLARE
                i PLS_INTEGER := v_gaps.FIRST;
            BEGIN
                WHILE i IS NOT NULL LOOP
                    DBMS_OUTPUT.PUT_LINE(
                        'SEQ_GAP:'
                        || ' thread='    || TO_CHAR(v_gaps(i).thread_no)
                        || ' seq_range=' || TO_CHAR(v_gaps(i).gap_from_seq + 1)
                        || '-'           || TO_CHAR(v_gaps(i).gap_to_seq - 1)
                        || ' count='     || TO_CHAR(v_gaps(i).gap_count)
                        || ' in_needed=' || v_gaps(i).in_needed
                    );
                    i := v_gaps.NEXT(i);
                END LOOP;
            END;
        ELSE
            DBMS_OUTPUT.PUT_LINE('--- SEQ_GAP DETAIL: none ---');
        END IF;

        -- 削除済みログ明細（必要範囲内のみ）
        IF v_del_idx > 0 THEN
            DBMS_OUTPUT.PUT_LINE('--- DELETED_LOG DETAIL in needed range (total=' || v_del_idx || ') ---');
            DECLARE
                i PLS_INTEGER := v_dels.FIRST;
            BEGIN
                WHILE i IS NOT NULL LOOP
                    DBMS_OUTPUT.PUT_LINE(
                        'DELETED_LOG:'
                        || ' thread='    || TO_CHAR(v_dels(i).thread_no)
                        || ' seq='       || TO_CHAR(v_dels(i).sequence_no)
                        || ' scn_range=' || TO_CHAR(v_dels(i).first_scn)
                        || '-'           || TO_CHAR(v_dels(i).next_scn)
                        || ' deleted='   || v_dels(i).del_flag
                        || ' status='    || v_dels(i).stat_code
                    );
                    i := v_dels.NEXT(i);
                END LOOP;
            END;
        ELSE
            DBMS_OUTPUT.PUT_LINE('--- DELETED_LOG DETAIL in needed range: none ---');
        END IF;
    END IF;

    go_to('CDB$ROOT');

EXCEPTION
    WHEN OTHERS THEN
        DECLARE
            v_err_msg VARCHAR2(4000) := SUBSTR(SQLERRM, 1, 4000);
        BEGIN
            -- エラー時もサマリ行を出力（ダッシュボードが parse しやすいよう統一形式）
            DBMS_OUTPUT.PUT_LINE(
                'ARCHIVE_GAP:'
                || ' needed_scn='        || TO_CHAR(v_mine_start_scn)
                || ' missing_needed=-1'
                || ' seq_gaps_total=-1'
                || ' seq_gaps_in_needed=-1'
                || ' oldest_avail_scn='  || TO_CHAR(v_oldest_avail_scn)
                || ' status=CRIT'
            );
            DBMS_OUTPUT.PUT_LINE('ARCHIVE_GAP_ERROR: ' || v_err_msg);
            IF v_container != 'CDB$ROOT' THEN
                BEGIN go_to('CDB$ROOT'); EXCEPTION WHEN OTHERS THEN NULL; END;
            END IF;
            RAISE;
        END;
END archive_gap_check;
/
SHOW ERRORS PROCEDURE SYS.archive_gap_check;

PROMPT SYS.archive_gap_check created on oracle-src.
EXIT;
