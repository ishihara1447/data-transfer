#!/usr/bin/env bash
# 受け入れ試験: 変換PL/SQL自動生成器(pkg_codegen) の正しさを実証
#
# 「手書きの既存変換と等価なコードをメタデータから生成できる」ことを合格条件とする。
# 流れ: コア/生成器デプロイ → サンプルマッピング投入 → 生成・デプロイ →
#       既存テスト(20/21/31/42)を生成コードで全実行 → 集約判定
#
# 前提: oracle-src/oracle-tgt 稼働。SRCに実データ(customers/orders/regions)あり。

set -uo pipefail
ROOT="/home/ishihara1447/projects/data-transfer"
SRC="oracle-src"; TGT="oracle-tgt"

echo "=================================================="
echo " 受け入れ試験: 変換PL/SQL 自動生成器 (pkg_codegen)"
echo "=================================================="

# ---- Step 0: 冪等化（テスト残留行 9000000+ を SRC から除去） ----
echo "[0] SRC テスト残留行クリーンアップ"
docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
DELETE FROM src_schema.orders WHERE order_id>=9000000;
DELETE FROM src_schema.customers WHERE customer_id>=9000000;
COMMIT;
EOF" >/dev/null 2>&1
echo "    完了"

# ---- Step 1: コア + 生成器 + マッピングをデプロイ ----
echo "[1] デプロイ: 40(setup) 41(util) 42(core) 70(mapping) 71(codegen) 72(seed mapping)"
DEPLOY_OK=1
for f in 40_phase2_setup_tgt 41_pkg_transform_util 42_pkg_transform 70_codegen_mapping 71_pkg_codegen 72_seed_mapping_example; do
  docker cp ${ROOT}/sql/transform/${f}.sql ${TGT}:/tmp/${f}.sql >/dev/null
  R=$(docker exec -u oracle ${TGT} bash -c "sqlplus -S /nolog @/tmp/${f}.sql" 2>&1 | grep -iE "(ORA-|PLS-|SP2-|Errors for)" | head -3)
  if [ -n "$R" ]; then echo "    [ERR] ${f}: $R"; DEPLOY_OK=0; fi
done
[ "${DEPLOY_OK}" = "1" ] && echo "    全デプロイOK"

# ---- Step 2: 生成 + デプロイ ----
echo "[2] pkg_codegen で変換PL/SQL生成 + デプロイ"
GEN_OUT=$(bash ${ROOT}/scripts/70_generate_transform.sh 2>&1)
GEN_STATUS=$(echo "${GEN_OUT}" | grep -oE "pkg_transform_gen status=[A-Z]+" | cut -d= -f2)
echo "    pkg_transform_gen: ${GEN_STATUS:-不明}"
echo "${GEN_OUT}" | grep -E "catalog:" | sed 's/^/    /'

# ---- Step 3: 生成コードで既存テスト群を実行 ----
echo ""
echo "[3] 生成された変換コードで受け入れテスト実行"
declare -A RC
run_test() {  # name script
  printf "    %-42s ... " "$2"
  if bash ${ROOT}/scripts/$2 >/tmp/codegen_$3.log 2>&1; then echo "PASS"; RC[$3]=0; else echo "FAIL"; RC[$3]=1; fi
}
run_test "LIGHT(customers/orders)"        "20_test_phase2_transform.sh"  t20
run_test "PASS_THROUGH/DELTA/削除/enriched" "21_test_phase2_mechanism.sh"  t21
run_test "統合E2E(HEAVY実volume)"          "31_test_integrated_e2e.sh"    t31
run_test "DELETE伝播(派生表)"              "42_test_delete_e2e.sh"        t42

# ---- 集約判定 ----
echo ""
echo "=================================================="
FAIL=0
for k in t20 t21 t31 t42; do [ "${RC[$k]:-1}" != "0" ] && FAIL=1; done
if [ "${GEN_STATUS}" = "VALID" ] && [ "${FAIL}" = "0" ]; then
  echo " [PASS] 自動生成器: メタデータから等価な変換PL/SQLを生成し全テスト通過"
  echo "        → DDL＋対応関係の入力だけで変換層を構築できることを実証"
else
  echo " [FAIL] 受け入れ未達（pkg_gen=${GEN_STATUS} / 各テスト: t20=${RC[t20]:-?} t21=${RC[t21]:-?} t31=${RC[t31]:-?} t42=${RC[t42]:-?}）"
  echo "        詳細ログ: /tmp/codegen_t*.log"
  exit 1
fi
echo "=================================================="
