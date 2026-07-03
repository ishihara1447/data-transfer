#!/usr/bin/env bash
# アーカイブログ連番欠落チェック E2Eテスト
# 実DBに対して archive_gap_check の動作を検証する（非破壊・冪等）。
#
# テスト項目:
#   1. 正常系: 現状の V$ARCHIVED_LOG で status=OK または WARN を返すこと
#   2. サマリ行フォーマット確認: 各フィールドが数値として取れること
#   3. CRIT検知系（非破壊）: mine_start_scn を人為的に未来SCN（現存最新より大）に
#      設定 → oldest_avail_scn > mine_start_scn となり CRIT を検知することを確認。
#      テスト後、元の mine_start_scn に必ず復元する（delta_extract_state を保護）。
#   4. verbose モード: 詳細出力が得られること
#
# 前提: oracle-src コンテナが healthy で起動していること。
#       SYS.archive_gap_check が作成済みであること。
#
# 使い方:
#   bash scripts/48_test_archive_gap.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="oracle-src"
RUN_NAME="delta_run_01"

PASS=0
FAIL=0
WARN_COUNT=0

c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_r(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_b(){ printf '\033[36m%s\033[0m\n' "$*"; }

pass(){ PASS=$((PASS+1)); c_g "  PASS: $*"; }
fail(){ FAIL=$((FAIL+1)); c_r "  FAIL: $*"; }
warn(){ WARN_COUNT=$((WARN_COUNT+1)); c_y "  WARN: $*"; }

# PL/SQL を実行してサマリ行を返すヘルパ
run_gap_check(){
    local verbose="${1:-N}"
    docker exec -u oracle "${CONTAINER}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 500
SET SERVEROUTPUT ON SIZE UNLIMITED
EXEC SYS.archive_gap_check(p_run_name => '${RUN_NAME}', p_verbose => '${verbose}')
EXIT;
SQLEOF" 2>&1
}

# mine_start_scn を指定値に一時変更するヘルパ（テスト専用）
set_mine_start_scn(){
    local new_scn="$1"
    docker exec -u oracle "${CONTAINER}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM cdc_schema.delta_extract_state WHERE run_name = '${RUN_NAME}';
    IF v_cnt > 0 THEN
        UPDATE cdc_schema.delta_extract_state SET mine_start_scn = ${new_scn} WHERE run_name = '${RUN_NAME}';
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('SET_MINE_START_SCN=' || ${new_scn});
    ELSE
        DBMS_OUTPUT.PUT_LINE('SET_MINE_START_SCN=NO_ROW');
    END IF;
END;
/
EXIT;
SQLEOF" 2>&1
}

# 現在の mine_start_scn と、現存ログの最大 NEXT_CHANGE# を取得するヘルパ
get_scn_info(){
    docker exec -u oracle "${CONTAINER}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 200
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'MINE_START_SCN=' || mine_start_scn FROM cdc_schema.delta_extract_state WHERE run_name = '${RUN_NAME}';
ALTER SESSION SET CONTAINER = CDB\$ROOT;
SELECT 'OLDEST_AVAIL_SCN=' || NVL(MIN(first_change#),0) FROM v\$archived_log WHERE dest_id=1 AND deleted='NO' AND status='A';
SELECT 'MAX_NEXT_CHANGE=' || NVL(MAX(next_change#),0) FROM v\$archived_log WHERE dest_id=1 AND deleted='NO' AND status='A';
EXIT;
SQLEOF" 2>&1
}

echo
c_b "===== archive_gap_check E2Eテスト ====="
echo "対象コンテナ: ${CONTAINER} / run_name: ${RUN_NAME}"
echo

# ---- テスト0: archive_gap_check プロシージャの存在確認 ----------------------
c_b "--- テスト0: プロシージャ存在確認 ---"
PROC_EXISTS=$(docker exec -u oracle "${CONTAINER}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT 'PROC_EXISTS=' || COUNT(*) FROM dba_procedures WHERE owner='SYS' AND object_name='ARCHIVE_GAP_CHECK' AND object_type='PROCEDURE';
EXIT;
SQLEOF" 2>&1 | grep -oE 'PROC_EXISTS=[0-9]+' | cut -d= -f2)

if [ "${PROC_EXISTS:-0}" -ge 1 ]; then
    pass "SYS.archive_gap_check が存在する"
else
    fail "SYS.archive_gap_check が存在しない（先に sql/cdc/47_pkg_archive_gap_src.sql を実行してください）"
    echo
    c_r "===== テスト中断（プロシージャ未デプロイ）====="
    exit 1
fi

# ---- SCN情報を取得 -----------------------------------------------------------
SCN_INFO=$(get_scn_info)
ORIG_MINE_START=$(echo "${SCN_INFO}" | grep -oE 'MINE_START_SCN=[0-9]+' | cut -d= -f2)
OLDEST_AVAIL=$(echo "${SCN_INFO}" | grep -oE 'OLDEST_AVAIL_SCN=[0-9]+' | cut -d= -f2)
MAX_NEXT=$(echo "${SCN_INFO}" | grep -oE 'MAX_NEXT_CHANGE=[0-9]+' | cut -d= -f2)

echo "現在の mine_start_scn (LW): ${ORIG_MINE_START:-不明}"
echo "現存ログ最古 FIRST_CHANGE#: ${OLDEST_AVAIL:-不明}"
echo "現存ログ最新 NEXT_CHANGE#:  ${MAX_NEXT:-不明}"
echo

# ---- テスト1: 正常系チェック ------------------------------------------------
c_b "--- テスト1: 正常系（現状のV\$ARCHIVED_LOGでの動作確認）---"
RAW1=$(run_gap_check N)
SUMMARY1=$(echo "${RAW1}" | grep -E '^ARCHIVE_GAP:' | head -1)
echo "  サマリ行: ${SUMMARY1}"

if [ -z "${SUMMARY1}" ]; then
    fail "サマリ行が出力されなかった"
    echo "  生出力:"
    echo "${RAW1}" | head -20
else
    # status 確認（OK または WARN を想定。CRIT は実環境依存なので許容）
    STATUS1=$(echo "${SUMMARY1}" | grep -oE 'status=(OK|WARN|CRIT)' | cut -d= -f2)
    case "${STATUS1}" in
        OK)   pass "status=OK（連番欠落なし・必要ログ保持済み）" ;;
        WARN) pass "status=WARN（範囲外に欠番あり・CDC再開は可能）"; warn "WARNING: seq_gaps_total > 0" ;;
        CRIT) warn "status=CRIT（現状の実環境でCRITが返った。アーカイブログの保持状況を確認してください）" ;;
        *)    fail "status フィールドが期待値 (OK/WARN/CRIT) 以外: '${STATUS1}'" ;;
    esac
fi

# ---- テスト2: フォーマット確認（各フィールドが数値として取れること） ---------
c_b "--- テスト2: サマリ行フォーマット確認 ---"
if [ -n "${SUMMARY1}" ]; then
    # 各フィールドを抽出して数値確認
    F_NEEDED=$(echo "${SUMMARY1}" | grep -oE 'needed_scn=[0-9]+' | cut -d= -f2)
    F_MISSING=$(echo "${SUMMARY1}" | grep -oE 'missing_needed=[0-9]+' | cut -d= -f2)
    F_GAPS_TOT=$(echo "${SUMMARY1}" | grep -oE 'seq_gaps_total=[0-9]+' | cut -d= -f2)
    F_GAPS_IN=$(echo "${SUMMARY1}" | grep -oE 'seq_gaps_in_needed=[0-9]+' | cut -d= -f2)
    F_OLDEST=$(echo "${SUMMARY1}" | grep -oE 'oldest_avail_scn=[0-9]+' | cut -d= -f2)
    F_STATUS=$(echo "${SUMMARY1}" | grep -oE 'status=(OK|WARN|CRIT)' | cut -d= -f2)

    ALL_OK=true
    for label_val in \
        "needed_scn:${F_NEEDED:-}" \
        "missing_needed:${F_MISSING:-}" \
        "seq_gaps_total:${F_GAPS_TOT:-}" \
        "seq_gaps_in_needed:${F_GAPS_IN:-}" \
        "oldest_avail_scn:${F_OLDEST:-}"
    do
        label="${label_val%%:*}"
        val="${label_val##*:}"
        if [[ "${val}" =~ ^[0-9]+$ ]]; then
            echo "  ${label}=${val} ... 数値OK"
        else
            fail "  ${label} が数値でない: '${val}'"
            ALL_OK=false
        fi
    done
    if [ -n "${F_STATUS}" ]; then
        echo "  status=${F_STATUS} ... 文字列OK"
    else
        fail "  status フィールドが取得できない"
        ALL_OK=false
    fi
    "${ALL_OK}" && pass "全フィールドが期待フォーマットで取得できた"
else
    fail "サマリ行なし（テスト1が失敗しているため skip）"
fi

# ---- テスト3: verbose モード確認 --------------------------------------------
c_b "--- テスト3: verbose モード確認 ---"
RAW3=$(run_gap_check Y)
SUMMARY3=$(echo "${RAW3}" | grep -E '^ARCHIVE_GAP:' | head -1)
if [ -n "${SUMMARY3}" ]; then
    pass "verbose=Y でもサマリ行が出力された"
    # verbose 特有のセクション行（SEQ_GAP_DETAILヘッダ等）の存在確認
    if echo "${RAW3}" | grep -qE '^---'; then
        pass "verbose=Y で詳細セクションヘッダ (---) が出力された"
    else
        fail "verbose=Y で詳細セクションヘッダが出力されなかった"
    fi
else
    fail "verbose=Y でサマリ行が出力されなかった"
fi

# ---- テスト4: CRIT検知系（非破壊シミュレーション）--------------------------
c_b "--- テスト4: CRIT検知シミュレーション（mine_start_scn を一時変更）---"
echo "  【注意】delta_extract_state.mine_start_scn を一時変更してテスト後に復元します。"

if [ -z "${ORIG_MINE_START:-}" ] || [ -z "${OLDEST_AVAIL:-}" ]; then
    fail "SCN情報が取得できなかったためテスト4をスキップ"
elif [ "${OLDEST_AVAIL:-0}" -le 1 ]; then
    warn "現存ログが取得できなかったためテスト4をスキップ"
else
    # oldest_avail_scn より小さい値を mine_start_scn に設定
    # → oldest_avail_scn(現存最古) > mine_start_scn(LW) となり CRIT を検知するはず
    # これは「archiveが消えてLWが古い日付を指している」状況の再現（非破壊・値変更のみ）
    FAKE_SCN=$(( ${OLDEST_AVAIL} - 1 ))
    echo "  一時設定する mine_start_scn (fake): ${FAKE_SCN}"
    echo "  （現存最古 FIRST_CHANGE# ${OLDEST_AVAIL} より 1 小さい値）"
    echo "  （oldest_avail_scn(${OLDEST_AVAIL}) > mine_start_scn(${FAKE_SCN}) → CRIT条件）"

    # テスト用に mine_start_scn を一時変更
    SET_RESULT=$(set_mine_start_scn "${FAKE_SCN}")
    if echo "${SET_RESULT}" | grep -q "SET_MINE_START_SCN=${FAKE_SCN}"; then
        echo "  mine_start_scn を ${FAKE_SCN} に設定"

        # CRIT を検知するか確認
        RAW4=$(run_gap_check N)
        SUMMARY4=$(echo "${RAW4}" | grep -E '^ARCHIVE_GAP:' | head -1)
        STATUS4=$(echo "${SUMMARY4}" | grep -oE 'status=(OK|WARN|CRIT)' | cut -d= -f2)
        NEEDED4=$(echo "${SUMMARY4}" | grep -oE 'needed_scn=[0-9]+' | cut -d= -f2)
        echo "  サマリ行: ${SUMMARY4}"

        if [ "${STATUS4}" = "CRIT" ]; then
            pass "CRIT が正しく検知された（oldest_avail_scn=${OLDEST_AVAIL} > needed_scn=${NEEDED4}）"
        else
            fail "CRIT が検知されなかった (status=${STATUS4}): サマリ=${SUMMARY4}"
        fi

        # ---- 必ず元の mine_start_scn に復元 ----------------------------------
        echo "  mine_start_scn を元の値 ${ORIG_MINE_START} に復元中..."
        RESTORE_RESULT=$(set_mine_start_scn "${ORIG_MINE_START}")
        if echo "${RESTORE_RESULT}" | grep -q "SET_MINE_START_SCN=${ORIG_MINE_START}"; then
            pass "mine_start_scn を ${ORIG_MINE_START} に復元完了"
        else
            fail "【重大】mine_start_scn の復元に失敗: ${RESTORE_RESULT}"
            echo "  手動で復元してください:"
            echo "  UPDATE cdc_schema.delta_extract_state SET mine_start_scn = ${ORIG_MINE_START} WHERE run_name = '${RUN_NAME}';"
        fi
    else
        warn "mine_start_scn の変更に失敗（delta_extract_state が存在しない可能性）。テスト4をスキップ"
        echo "  変更結果: ${SET_RESULT}"
    fi
fi

# ---- テスト5: 47_archive_gap_check.sh スクリプト経由の実行確認 --------------
c_b "--- テスト5: 47_archive_gap_check.sh スクリプト経由の実行確認 ---"
if [ -f "${ROOT}/scripts/47_archive_gap_check.sh" ]; then
    SCRIPT_OUT=$(bash "${ROOT}/scripts/47_archive_gap_check.sh" --run "${RUN_NAME}" 2>&1)
    SCRIPT_RC=$?
    SCRIPT_SUMMARY=$(echo "${SCRIPT_OUT}" | grep -E '^ARCHIVE_GAP:' | head -1)
    echo "  スクリプト出力（抜粋）: ${SCRIPT_SUMMARY}"
    echo "  終了コード: ${SCRIPT_RC}"

    if [ -n "${SCRIPT_SUMMARY}" ]; then
        pass "スクリプト経由でサマリ行が取得できた"
    else
        fail "スクリプト経由でサマリ行が取得できなかった"
        echo "  全出力: ${SCRIPT_OUT}"
    fi

    # 終了コードの確認（OK/WARN=0, CRIT=2, エラー=1）
    SCRIPT_STATUS=$(echo "${SCRIPT_SUMMARY}" | grep -oE 'status=(OK|WARN|CRIT)' | cut -d= -f2)
    case "${SCRIPT_STATUS}" in
        OK|WARN) [ "${SCRIPT_RC}" -eq 0 ] && pass "終了コード 0 が正しく返った (status=${SCRIPT_STATUS})" \
                                          || fail "終了コードが 0 でない: ${SCRIPT_RC} (status=${SCRIPT_STATUS})" ;;
        CRIT)    [ "${SCRIPT_RC}" -eq 2 ] && pass "終了コード 2 が正しく返った (status=CRIT)" \
                                          || fail "終了コードが 2 でない: ${SCRIPT_RC} (status=CRIT)" ;;
        *)       fail "スクリプト status が不明: '${SCRIPT_STATUS}'" ;;
    esac
else
    fail "scripts/47_archive_gap_check.sh が見つかりません"
fi

# ---- 結果サマリ -------------------------------------------------------------
echo
c_b "===== テスト結果 ====="
echo "  PASS: ${PASS} / FAIL: ${FAIL} / WARN: ${WARN_COUNT}"
if [ "${FAIL}" -eq 0 ]; then
    c_g "  全テスト PASS"
    exit 0
else
    c_r "  FAIL が ${FAIL} 件あります。上記メッセージを確認してください。"
    exit 1
fi
