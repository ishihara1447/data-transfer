#!/usr/bin/env bash
# DELETE 継続運用 E2E: SRC削除 → delta_extract → delta_apply(SQL_REDO replay) →
#   STAGING削除 → transform DELTA 削除伝播 → TARGET(通常表 orders + 派生表 order_enriched)削除
#
# 検証:
#   1. SRC に test order 投入 → CDCサイクルで TARGET.orders / order_enriched に出現
#   2. SRC で test order を DELETE → CDCサイクルで STAGING / TARGET 両方から消滅
#      （特に派生表 order_enriched は delete_src_table=ORDERS 経由で削除伝播）

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="oracle-src"; TGT="oracle-tgt"
OID=9200001

src_sql() { docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'EOF'
$1
EOF" 2>&1; }
tgt_sql() { docker exec -u oracle ${TGT} bash -c "sqlplus -S '/ as sysdba' <<'EOF'
$1
EOF" 2>&1; }
PASS=1
chk() { if [ "$2" = "$3" ]; then echo "  [OK] $1 = $3"; else echo "  [NG] $1 期待'$2' 実際'$3'"; PASS=0; fi; }
num() { grep -oE '[0-9]+' | tail -1; }
tgt_cnt() { tgt_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT (SELECT COUNT(*) FROM $1 WHERE $2)||'' FROM DUAL;" | num; }

echo "=============================================="
echo " DELETE 継続運用 E2E（order_id=${OID}）"
echo "=============================================="

# 既存顧客・地域を参照に使う
MINC=$(src_sql "SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT MIN(customer_id) FROM src_schema.customers;" | num)
AREG=$(src_sql "SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT MIN(region_id) FROM src_schema.regions;" | num)

echo ""
echo "[0] クリーンアップ + test order 投入（customer=${MINC}, region=${AREG}）"
src_sql "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
DELETE FROM src_schema.orders WHERE order_id=${OID};
INSERT INTO src_schema.orders(order_id,order_no,customer_id,shipping_region_id,status,order_date,ship_date,delivery_date,total_amount,tax_amount,shipping_address,notes,created_at,updated_at)
VALUES (${OID},'ODEL${OID}',${MINC},${AREG},'CONFIRMED',DATE '2026-06-07',NULL,NULL,30000,2400,NULL,'delete-test',SYSTIMESTAMP,SYSTIMESTAMP);
COMMIT;" >/dev/null

echo ""
echo "[1] CDCサイクル（投入を TARGET へ反映）"
bash ${ROOT}/scripts/40_cdc_cycle.sh

O1=$(tgt_cnt "target_schema.orders" "order_id=${OID}")
E1=$(tgt_cnt "target_schema.order_enriched" "order_id=${OID}")
S1=$(tgt_cnt "staging_schema.orders" "order_id=${OID}")
echo "  STAGING.orders=${S1} TARGET.orders=${O1} order_enriched=${E1}"
chk "投入後 STAGING.orders"        "1" "${S1}"
chk "投入後 TARGET.orders"         "1" "${O1}"
chk "投入後 order_enriched(派生)"  "1" "${E1}"

echo ""
echo "[2] SRC で test order を DELETE"
src_sql "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
DELETE FROM src_schema.orders WHERE order_id=${OID};
COMMIT;" >/dev/null

echo ""
echo "[3] CDCサイクル（削除を伝播）"
bash ${ROOT}/scripts/40_cdc_cycle.sh

O2=$(tgt_cnt "target_schema.orders" "order_id=${OID}")
E2=$(tgt_cnt "target_schema.order_enriched" "order_id=${OID}")
S2=$(tgt_cnt "staging_schema.orders" "order_id=${OID}")
echo "  STAGING.orders=${S2} TARGET.orders=${O2} order_enriched=${E2}"
chk "削除後 STAGING.orders 消滅"        "0" "${S2}"
chk "削除後 TARGET.orders 消滅"         "0" "${O2}"
chk "削除後 order_enriched 削除伝播"    "0" "${E2}"

echo ""
if [ "${PASS}" = "1" ]; then
  echo "  [PASS] DELETE 継続運用: SRC削除→STAGING削除→TARGET(通常+派生)削除伝播 完全動作"
else
  echo "  [FAIL] DELETE 継続運用: 上記 NG 参照"; exit 1
fi
echo "=============================================="