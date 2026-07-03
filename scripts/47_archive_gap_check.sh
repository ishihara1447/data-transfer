#!/usr/bin/env bash
# アーカイブログ連番欠落チェック（起動・終了コード判定スクリプト）
# ロジックは SYS.archive_gap_check (sql/cdc/47_pkg_archive_gap_src.sql) に実装済み。
# このスクリプトは oracle-src で PL/SQL を実行し、サマリ行を標準出力する。
#
# 使い方:
#   bash scripts/47_archive_gap_check.sh                   # 標準チェック（非冗長）
#   bash scripts/47_archive_gap_check.sh --verbose         # 欠番詳細・削除済み明細も出力
#   bash scripts/47_archive_gap_check.sh --run delta_run_01 --verbose
#
# 終了コード:
#   0: OK または WARN（警告あり・CDC再開は可能）
#   2: CRIT（CDC再開不能の可能性・要即時対応）
#   1: 実行エラー（sqlplus 異常・接続失敗等）
#
# ログ出力:
#   logs/ 配下に archive_gap_check_<YYYYMMDD_HHMMSS>.log を保存する。

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="oracle-src"
RUN_NAME="delta_run_01"
VERBOSE="N"

# ---- 引数解析 ----------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose|-v) VERBOSE="Y"; shift ;;
        --run)        RUN_NAME="${2:-delta_run_01}"; shift 2 ;;
        --container)  CONTAINER="${2:-oracle-src}";  shift 2 ;;
        --help|-h)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "不明な引数: $1 (--verbose / --run <名前> / --container <名前>)" >&2; exit 1 ;;
    esac
done

# ---- ログディレクトリ --------------------------------------------------------
mkdir -p "${ROOT}/logs"
LOG_FILE="${ROOT}/logs/archive_gap_check_$(date '+%Y%m%d_%H%M%S').log"

# ---- PL/SQL 実行 ------------------------------------------------------------
# SET SERVEROUTPUT ON は ALTER SESSION SET CONTAINER より後（既知のハマりどころ）。
# archive_gap_check は CDB$ROOT で実行する（V$ARCHIVED_LOG は CDB共通、
# XEPDB1 切り替えは PL/SQL 内で行う）。
RAW=$(docker exec -u oracle "${CONTAINER}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 500
SET SERVEROUTPUT ON SIZE UNLIMITED
EXEC SYS.archive_gap_check(p_run_name => '${RUN_NAME}', p_verbose => '${VERBOSE}')
EXIT;
SQLEOF" 2>&1)

SQLPLUS_RC=$?

# ---- ログ保存 ---------------------------------------------------------------
{
    echo "=== archive_gap_check: $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo "container=${CONTAINER} run=${RUN_NAME} verbose=${VERBOSE}"
    echo "${RAW}"
} >> "${LOG_FILE}" 2>&1

# ---- サマリ行の抽出（grep で拾う） ------------------------------------------
SUMMARY=$(echo "${RAW}" | grep -E '^ARCHIVE_GAP:' | head -1)

if [ -z "${SUMMARY}" ] || [ "${SQLPLUS_RC}" -ne 0 ]; then
    echo "ERROR: archive_gap_check の実行に失敗しました（sqlplus RC=${SQLPLUS_RC}）" >&2
    echo "${RAW}" >&2
    echo "ログ: ${LOG_FILE}" >&2
    exit 1
fi

# ---- 標準出力（サマリ行 + verbose の場合は詳細行も） -----------------------
echo "${SUMMARY}"
if [ "${VERBOSE}" = "Y" ]; then
    echo "${RAW}" | grep -E '^(SEQ_GAP:|DELETED_LOG:|--- )'
fi

# ---- status フィールドを抽出して終了コード判定 ------------------------------
STATUS=$(echo "${SUMMARY}" | grep -oE 'status=(OK|WARN|CRIT)' | cut -d= -f2)

case "${STATUS}" in
    OK|WARN)
        # OK: 問題なし / WARN: 範囲外に欠番あるが CDC 再開は可能
        echo "ログ: ${LOG_FILE}"
        exit 0
        ;;
    CRIT)
        # CRIT: CDC再開不能の可能性。要即時対応。
        echo "CRIT: CDC再開に必要なアーカイブログが欠落または削除されています。要即時確認。" >&2
        echo "  詳細: bash scripts/47_archive_gap_check.sh --verbose" >&2
        echo "ログ: ${LOG_FILE}"
        exit 2
        ;;
    *)
        echo "ERROR: status フィールドを取得できませんでした: ${SUMMARY}" >&2
        echo "ログ: ${LOG_FILE}"
        exit 1
        ;;
esac
