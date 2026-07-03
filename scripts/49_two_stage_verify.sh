#!/usr/bin/env bash
# 二段階検証スクリプト: 形式検証 (段階1) + 内容検証 (段階2a/2b)
#
# 段階1 (structural):
#   SRC / STAGING / TARGET 各テーブルの行数を取得し突き合わせ。
#   対象: regions, customers, orders (SRC↔STAGING), order_enriched (STG.orders件数と比較)
#
# 段階2a (content - hash):
#   SRC 側: SYS.verify_content_src (oracle-src) を実行し CONTENT_SRC 行を取得。
#   STG 側: SYS.verify_content_stg (oracle-tgt) を実行し CONTENT_STG 行を取得。
#   各テーブルの rows / scalar_hash / lob_len_sum / lob_head_hash を突き合わせる。
#   役割分離: 値の算出は各 DB の PL/SQL、突き合わせはこのシェル。
#
# 段階2b (content - business aggregates):
#   TGT 側: SYS.verify_business_aggregates (oracle-tgt) を実行し BIZAGG 行を取得。
#   各チェックの PASS/FAIL を表示する。
#
# 終了コード:
#   0 = 全チェック PASS
#   2 = 1件以上 FAIL
#   1 = 実行エラー (sqlplus 接続失敗等)
#
# アーキテクチャ上の注意:
#   SRC(oracle-src) と STAGING(oracle-tgt) は別 DB・オフラインのため直接 JOIN 不可。
#   data-generator が継続 DML 中のため、SRC と STAGING は「追いつき途中」では不一致になり得る。
#   段階2a が FAIL でも CDC サイクルが追いつけば PASS になる。判断は運用側で行うこと。
#
# 使い方:
#   bash scripts/49_two_stage_verify.sh [--verbose]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="oracle-src"
TGT="oracle-tgt"
VERBOSE="N"
[ "${1:-}" = "--verbose" ] && VERBOSE="Y"

FAIL_COUNT=0
PASS_COUNT=0
WARN_COUNT=0

# ---- 色定義 ----------------------------------------------------------------
c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_r(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_b(){ printf '\033[36m%s\033[0m\n' "$*"; }
c_p(){ printf '\033[35m%s\033[0m\n' "$*"; }

# ---- 判定ヘルパー ----------------------------------------------------------
check_eq() {
    local label="$1" a="$2" b="$3" note="${4:-}"
    if [ "${a}" = "${b}" ]; then
        c_g "  PASS  ${label}: ${a} = ${b}${note:+ ($note)}"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        c_r "  FAIL  ${label}: ${a} != ${b}${note:+ ($note)}"
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
}

check_pass_fail() {
    local result="$1" label="$2" detail="$3"
    if [ "${result}" = "PASS" ]; then
        c_g "  PASS  ${label}: ${detail}"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        c_r "  FAIL  ${label}: ${detail}"
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
}

# ---- sqlplus 実行ヘルパー -------------------------------------------------
# parse_kv: KEY=VALUE 形式の行を連想配列風に返す（変数名に格納）
# 使用例: parse_kv "${raw}" "SRC_REGIONS" → 変数 KV_SRC_REGIONS に値が入る
# shellで連想配列を使わず grep で値を取り出す方式にする（bash 3.x 互換）
get_kv() {
    local raw="$1" key="$2"
    echo "${raw}" | grep -oE "${key}=[^ ]+" | head -1 | cut -d= -f2
}

echo
c_b "=================================================================="
c_b " 二段階検証 (Two-Stage Verification)"
c_b " 実行時刻: $(date '+%Y-%m-%d %H:%M:%S')"
c_b "=================================================================="
echo

# ================================================================
# 段階1: 形式検証 (Structural) - 行数突き合わせ
# ================================================================
c_b "-- 段階1: 形式検証 (行数突き合わせ) --"
echo "  ※ SRC と STAGING は別 DB。CDC が追いついていない場合は一時的に不一致になり得る。"
echo

# SRC 行数取得（oracle-src）
SRC_RAW=$(docker exec -u oracle "${SRC}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 200
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'SRC_REGIONS='||COUNT(*)   FROM src_schema.regions;
SELECT 'SRC_CUSTOMERS='||COUNT(*) FROM src_schema.customers;
SELECT 'SRC_ORDERS='||COUNT(*)    FROM src_schema.orders;
EXIT;
SQLEOF" 2>/dev/null)

# STG/TGT 行数取得（oracle-tgt）- verify_row_counts_tgt を使う
# ★ SET SERVEROUTPUT ON は ALTER SESSION SET CONTAINER の後に置く（CDB/PDB 切替でリセットされる）
TGT_ROW_RAW=$(docker exec -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 300
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED
EXEC SYS.verify_row_counts_tgt(p_verbose => 'N')
EXIT;
SQLEOF" 2>/dev/null)

# SRC 行数をパース（先頭タブ対策: grep -oE で数字のみ抽出）
SRC_REGIONS=$(get_kv "${SRC_RAW}"  "SRC_REGIONS")
SRC_CUSTOMERS=$(get_kv "${SRC_RAW}" "SRC_CUSTOMERS")
SRC_ORDERS=$(get_kv "${SRC_RAW}"   "SRC_ORDERS")

# ROWCOUNT_TGT 行のパース例: "ROWCOUNT_TGT: table=REGIONS stg=10 tgt=10 match=Y"
parse_rowcount() {
    local raw="$1" table="$2" field="$3"
    echo "${raw}" | grep "table=${table} " | grep -oE "${field}=[^ ]+" | head -1 | cut -d= -f2
}

STG_REGIONS=$(parse_rowcount "${TGT_ROW_RAW}" "REGIONS"       "stg")
TGT_REGIONS=$(parse_rowcount "${TGT_ROW_RAW}" "REGIONS"       "tgt")
STG_CUSTOMERS=$(parse_rowcount "${TGT_ROW_RAW}" "CUSTOMERS"   "stg")
TGT_CUSTOMERS=$(parse_rowcount "${TGT_ROW_RAW}" "CUSTOMERS"   "tgt")
STG_ORDERS=$(parse_rowcount "${TGT_ROW_RAW}" "ORDERS"         "stg")
TGT_ORDERS=$(parse_rowcount "${TGT_ROW_RAW}" "ORDERS"         "tgt")
STG_ORDERS_FOR_ENR=$(parse_rowcount "${TGT_ROW_RAW}" "ORDER_ENRICHED" "stg")
TGT_ORDER_ENR=$(parse_rowcount "${TGT_ROW_RAW}" "ORDER_ENRICHED" "tgt")

# デフォルト値
SRC_REGIONS="${SRC_REGIONS:-0}"
SRC_CUSTOMERS="${SRC_CUSTOMERS:-0}"
SRC_ORDERS="${SRC_ORDERS:-0}"
STG_REGIONS="${STG_REGIONS:-0}"
TGT_REGIONS="${TGT_REGIONS:-0}"
STG_CUSTOMERS="${STG_CUSTOMERS:-0}"
TGT_CUSTOMERS="${TGT_CUSTOMERS:-0}"
STG_ORDERS="${STG_ORDERS:-0}"
TGT_ORDERS="${TGT_ORDERS:-0}"
STG_ORDERS_FOR_ENR="${STG_ORDERS_FOR_ENR:-0}"
TGT_ORDER_ENR="${TGT_ORDER_ENR:-0}"

echo "  テーブル           SRC      STAGING  TARGET"
echo "  ---------------  -------  -------  -------"
printf "  %-16s %8s %8s %8s\n" "REGIONS"       "${SRC_REGIONS}"   "${STG_REGIONS}"   "${TGT_REGIONS}"
printf "  %-16s %8s %8s %8s\n" "CUSTOMERS"     "${SRC_CUSTOMERS}" "${STG_CUSTOMERS}" "${TGT_CUSTOMERS}"
printf "  %-16s %8s %8s %8s\n" "ORDERS"        "${SRC_ORDERS}"    "${STG_ORDERS}"    "${TGT_ORDERS}"
printf "  %-16s %8s %8s %8s\n" "ORDER_ENRICHED" "-"              "${STG_ORDERS_FOR_ENR}" "${TGT_ORDER_ENR}"
echo

echo "  [SRC = STAGING チェック (CDC ミラー一致確認)]"
check_eq "SRC=STG regions"       "${SRC_REGIONS}"   "${STG_REGIONS}"   "CDC lag で一時的不一致あり得る"
check_eq "SRC=STG customers"     "${SRC_CUSTOMERS}" "${STG_CUSTOMERS}" "CDC lag で一時的不一致あり得る"
check_eq "SRC=STG orders"        "${SRC_ORDERS}"    "${STG_ORDERS}"    "CDC lag で一時的不一致あり得る"
echo
echo "  [STAGING = TARGET チェック (変換一致確認)]"
check_eq "STG=TGT regions"       "${STG_REGIONS}"   "${TGT_REGIONS}"
check_eq "STG=TGT customers"     "${STG_CUSTOMERS}" "${TGT_CUSTOMERS}"
check_eq "STG=TGT orders"        "${STG_ORDERS}"    "${TGT_ORDERS}"
check_eq "STG.orders=TGT.order_enriched" "${STG_ORDERS_FOR_ENR}" "${TGT_ORDER_ENR}" "HEAVY 変換は 1行→1行"
echo

# ================================================================
# 段階2a: 内容検証 - ハッシュ照合 (SRC↔STAGING 別 DB)
# ================================================================
c_b "-- 段階2a: 内容検証 (ハッシュ照合・SRC↔STAGING) --"
echo "  ※ scalar_hash=行内容ハッシュの SUM（順序非依存）"
echo "  ※ LOB 検証は先頭 2000byte/char のみ（完全一致保証ではない）"
echo

# SRC ハッシュ取得
# ★ SET SERVEROUTPUT ON は ALTER SESSION SET CONTAINER の後に置く
SRC_HASH_RAW=$(docker exec -u oracle "${SRC}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 500
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED
EXEC SYS.verify_content_src(p_verbose => '${VERBOSE}')
EXIT;
SQLEOF" 2>/dev/null)

# STG ハッシュ取得
STG_HASH_RAW=$(docker exec -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 500
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED
EXEC SYS.verify_content_stg(p_verbose => '${VERBOSE}')
EXIT;
SQLEOF" 2>/dev/null)

if [ "${VERBOSE}" = "Y" ]; then
    echo "  [SRC raw output]"
    echo "${SRC_HASH_RAW}" | grep -E "^CONTENT_SRC:" | while read -r l; do echo "    ${l}"; done
    echo "  [STG raw output]"
    echo "${STG_HASH_RAW}" | grep -E "^CONTENT_STG:" | while read -r l; do echo "    ${l}"; done
    echo
fi

# CONTENT_SRC/STG 行のパース
# フォーマット: CONTENT_SRC: table=REGIONS rows=10 scalar_hash=12345 lob_len_sum=0 lob_head_hash=0
parse_content() {
    local raw="$1" prefix="$2" table="$3" field="$4"
    echo "${raw}" | grep "^${prefix}:" | grep "table=${table} " \
        | grep -oE "${field}=[^ ]+" | head -1 | cut -d= -f2
}

for tbl in REGIONS CUSTOMERS ORDERS; do
    src_rows=$(parse_content "${SRC_HASH_RAW}" "CONTENT_SRC" "${tbl}" "rows")
    stg_rows=$(parse_content "${STG_HASH_RAW}" "CONTENT_STG" "${tbl}" "rows")
    src_sh=$(parse_content "${SRC_HASH_RAW}" "CONTENT_SRC" "${tbl}" "scalar_hash")
    stg_sh=$(parse_content "${STG_HASH_RAW}" "CONTENT_STG" "${tbl}" "scalar_hash")
    src_ll=$(parse_content "${SRC_HASH_RAW}" "CONTENT_SRC" "${tbl}" "lob_len_sum")
    stg_ll=$(parse_content "${STG_HASH_RAW}" "CONTENT_STG" "${tbl}" "lob_len_sum")
    src_lh=$(parse_content "${SRC_HASH_RAW}" "CONTENT_SRC" "${tbl}" "lob_head_hash")
    stg_lh=$(parse_content "${STG_HASH_RAW}" "CONTENT_STG" "${tbl}" "lob_head_hash")

    src_rows="${src_rows:-0}"; stg_rows="${stg_rows:-0}"
    src_sh="${src_sh:-0}";     stg_sh="${stg_sh:-0}"
    src_ll="${src_ll:-0}";     stg_ll="${stg_ll:-0}"
    src_lh="${src_lh:-0}";     stg_lh="${stg_lh:-0}"

    echo "  [${tbl}]"
    check_eq "${tbl} rows"          "${src_rows}" "${stg_rows}" "CDC lag で一時的不一致あり得る"
    check_eq "${tbl} scalar_hash"   "${src_sh}"   "${stg_sh}"  "行内容ハッシュ合計"
    if [ "${tbl}" != "REGIONS" ]; then
        check_eq "${tbl} lob_len_sum"   "${src_ll}" "${stg_ll}" "LOB 総バイト数"
        check_eq "${tbl} lob_head_hash" "${src_lh}" "${stg_lh}" "LOB 先頭2000byte のみ・完全保証なし"
    fi
    echo
done

# ================================================================
# 段階2b: 業務集計 照合 (STAGING↔TARGET 同一 DB)
# ================================================================
c_b "-- 段階2b: 業務集計照合 (STAGING↔TARGET 業務不変量) --"
echo "  ※ 変換後の業務不変量を照合。変換ロジック (42_pkg_transform.sql) に基づく。"
echo

BIZAGG_RAW=$(docker exec -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 600
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED
EXEC SYS.verify_business_aggregates(p_verbose => '${VERBOSE}')
EXIT;
SQLEOF" 2>/dev/null)

# BIZAGG 行をパース: "BIZAGG: check=XXX result=PASS|FAIL detail=..."
while IFS= read -r line; do
    check_name=$(echo "${line}" | grep -oE 'check=[^ ]+' | cut -d= -f2)
    result=$(echo "${line}" | grep -oE 'result=(PASS|FAIL)' | cut -d= -f2)
    detail=$(echo "${line}" | sed 's/.*detail=//')
    [ -z "${check_name}" ] && continue
    check_pass_fail "${result:-FAIL}" "${check_name}" "${detail}"
done < <(echo "${BIZAGG_RAW}" | grep "^BIZAGG:")

# NOTE 行の表示
echo "${BIZAGG_RAW}" | grep "^NOTE:" | while IFS= read -r note; do
    c_y "  NOTE: ${note#NOTE: }"
done
echo

# ================================================================
# 全体サマリ
# ================================================================
c_b "=================================================================="
c_b " 全体サマリ"
c_b "=================================================================="
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "  総チェック数: ${TOTAL}"
c_g "  PASS: ${PASS_COUNT}"
if [ "${FAIL_COUNT}" -gt 0 ]; then
    c_r "  FAIL: ${FAIL_COUNT}"
else
    c_g "  FAIL: 0"
fi
echo

if [ "${FAIL_COUNT}" -eq 0 ] && [ "${PASS_COUNT}" -gt 0 ]; then
    c_g "  [結果] 全チェック PASS"
    echo
    exit 0
elif [ "${FAIL_COUNT}" -gt 0 ]; then
    c_r "  [結果] ${FAIL_COUNT} 件の FAIL あり"
    echo "  ヒント: CDC lag による一時的不一致の場合は scripts/40_cdc_cycle.sh を数サイクル実行後に再確認"
    echo
    exit 2
else
    c_y "  [結果] チェック結果が取得できませんでした (sqlplus 接続確認が必要)"
    echo
    exit 1
fi
