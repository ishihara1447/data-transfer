#!/usr/bin/env bash
# 統合 E2E: 三分割アーキの ①初期ロード → ②差分同期 → ③変換 を一気通貫で検証
# 設計: docs/migration-strategy.md / phase1-commit-scn-redesign.md / phase2-transform-design.md
#
# パイプライン:
#   [A] G1 初期ロード(FLASHBACK_SCN) → STAGING 全量 → transform INITIAL → TARGET 全量
#   [B] SRC で DML → delta_extract(全テーブル) → Data Pump 搬送 → delta_apply → STAGING 更新
#       → transform DELTA → TARGET 反映
#
# 既存スクリプトを再利用:
#   scripts/30_initial_load_flashback.sh （①）
#   scripts/06_transfer_delta_datapump.sh（②搬送+適用）

set -uo pipefail
ROOT="/home/ishihara1447/projects/data-transfer"
SRC="oracle-src"; TGT="oracle-tgt"
RUN_NAME="delta_run_01"

src_sql() { docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
$1
SQLEOF" 2>&1; }
tgt_sql() { docker exec -u oracle ${TGT} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
$1
SQLEOF" 2>&1; }
transform() { tgt_sql "
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF ECHO OFF
BEGIN log_schema.pkg_transform.transform_all('$1','$2',10000,'Y'); END;
/
EXIT;" | grep -E "transform_all|ORA-|FAILED" || true; }

PASS=1
chk() { if [ "$2" = "$3" ]; then echo "  [OK] $1 = $3"; else echo "  [NG] $1 期待'$2' 実際'$3'"; PASS=0; fi; }
g() { echo "$1" | grep -E "^$2=" | head -1 | cut -d= -f2-; }

echo "=================================================="
echo " 統合 E2E: 初期ロード → 差分 → 変換 貫通"
echo "=================================================="

# ==================================================================
# [0] 冪等化: SRC からテスト専用行(9000001)を除去（G1 baseline に混入させない）
# ==================================================================
echo ""
echo "### [0] SRC テスト行クリーンアップ（冪等化）###"
src_sql "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
DELETE FROM src_schema.orders WHERE order_id=9000001;
DELETE FROM src_schema.customers WHERE customer_id=9000001;
-- 更新検証を堅牢化: 最小 customer の credit を既知 baseline 値(100000)へ戻す
UPDATE src_schema.customers SET credit_limit=100000
 WHERE customer_id=(SELECT MIN(customer_id) FROM src_schema.customers);
COMMIT;
EXIT;" >/dev/null
echo "  cust/ord 9000001 を SRC から除去 + 最小cust credit を baseline=100000 にリセット"

# ==================================================================
# [A] 初期ロード + INITIAL 変換
# ==================================================================
echo ""
echo "### [A] ① 初期ロード(FLASHBACK_SCN) ###"
bash ${ROOT}/scripts/30_initial_load_flashback.sh > /tmp/e2e_g1.log 2>&1
if ! grep -q "\[PASS\] G1" /tmp/e2e_g1.log; then
  echo "  [NG] G1 初期ロード失敗（/tmp/e2e_g1.log 参照）"; tail -5 /tmp/e2e_g1.log; exit 1
fi
BASELINE=$(cat /tmp/initial_load/last_baseline_scn.txt)
echo "  G1 完了 baseline=${BASELINE}"

echo ""
echo "  tgt 差分機構を baseline にリセット（T3等の残骸を除去）"
tgt_sql "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
DELETE FROM staging_ctl.delta_queue;
DELETE FROM staging_ctl.apply_ledger;
UPDATE staging_ctl.delta_apply_state SET last_applied_commit_scn=${BASELINE} WHERE run_name='${RUN_NAME}';
UPDATE log_schema.transform_state SET last_transform_at=TIMESTAMP '1970-01-01 00:00:00';
COMMIT;
EXIT;" >/dev/null

echo ""
echo "### [A] ③ INITIAL 変換（実volume: cust 29451 / ord 33590）###"
transform "E2E_INITIAL" "INITIAL"
VA=$(tgt_sql "
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 100 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'reg='||COUNT(*) FROM target_schema.regions;
SELECT 'cust='||COUNT(*) FROM target_schema.customers;
SELECT 'ord='||COUNT(*) FROM target_schema.orders;
SELECT 'ord_unknown='||COUNT(*) FROM target_schema.orders WHERE order_status='UNKNOWN';
SELECT 'fk_orphan='||COUNT(*) FROM target_schema.orders o WHERE NOT EXISTS (SELECT 1 FROM target_schema.customers c WHERE c.customer_id=o.customer_id);
EXIT;" | grep -E '=')
echo "${VA}"
chk "TARGET regions=10"        "10"    "$(g "${VA}" reg)"
chk "TARGET customers=29451"   "29451" "$(g "${VA}" cust)"
chk "TARGET orders=33590"      "33590" "$(g "${VA}" ord)"
chk "order_status UNKNOWN=0"   "0"     "$(g "${VA}" ord_unknown)"
chk "FK孤児=0"                 "0"     "$(g "${VA}" fk_orphan)"

# ==================================================================
# [B] 差分同期 + DELTA 変換
# ==================================================================
echo ""
echo "### [B] ② SRC で DML（baseline 後の変更）###"
# 既存最小 customer_id を取得（更新対象）
MINC=$(src_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT MIN(customer_id) FROM src_schema.customers;
EXIT;" | grep -oE '[0-9]+' | tail -1)
echo "  更新対象 既存 customer_id=${MINC}"
# 既存 region(参照用) を取得
AREG=$(src_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT MIN(region_id) FROM src_schema.regions;
EXIT;" | grep -oE '[0-9]+' | tail -1)

src_sql "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
-- 新規顧客（LOBはNULL）
INSERT INTO src_schema.customers(customer_id,customer_code,company_name,last_name,first_name,email,phone,region_id,credit_limit,status,created_at,updated_at)
VALUES (9000001,'E2E0001',NULL,'E2ELast','E2EFirst','e2e0001@example.com','03-9-9',${AREG},555000,'ACTIVE',SYSTIMESTAMP,SYSTIMESTAMP);
-- 既存顧客の更新（credit_limit を固有値へ）
UPDATE src_schema.customers SET credit_limit=123456, updated_at=SYSTIMESTAMP WHERE customer_id=${MINC};
-- 新規注文（新規顧客に紐づく。LOBはNULL）
INSERT INTO src_schema.orders(order_id,order_no,customer_id,shipping_region_id,status,order_date,ship_date,delivery_date,total_amount,tax_amount,created_at,updated_at)
VALUES (9000001,'OE2E0001',9000001,${AREG},'SHIPPED',DATE '2026-06-07',DATE '2026-06-08',DATE '2026-06-11',10000,800,SYSTIMESTAMP,SYSTIMESTAMP);
COMMIT;
EXIT;" >/dev/null
echo "  新規cust 9000001 / cust ${MINC} 更新(credit=123456) / 新規ord 9000001 を SRC にコミット"

# ログスイッチ（アーカイブ確実化）
src_sql "ALTER SYSTEM SWITCH LOGFILE;" >/dev/null

echo ""
echo "### [B] ② delta_extract（baseline 超の差分のみ）###"
# delta_extract は CDB$ROOT で実行する（proc 内部で XEPDB1 へ切替）。コンテナ切替しない。
src_sql "
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF ECHO OFF
BEGIN SYS.delta_extract('${RUN_NAME}'); END;
/
EXIT;" | grep -E "delta_extract|ORA-" || true
VQ=$(src_sql "
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 100 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT table_name||'_'||operation||'='||COUNT(*) FROM cdc_schema.delta_queue GROUP BY table_name||'_'||operation ORDER BY 1;
EXIT;" | grep -E '=')
echo "  抽出された差分:"
echo "${VQ}" | sed 's/^/    /'

echo ""
echo "### [B] ② Data Pump 搬送 + delta_apply ###"
bash ${ROOT}/scripts/06_transfer_delta_datapump.sh > /tmp/e2e_xfer.log 2>&1 || true
grep -E "delta_apply:" /tmp/e2e_xfer.log | sed 's/^/    /' || echo "    (delta_apply 出力なし - ログ確認)"

echo ""
echo "  STAGING 反映確認"
VS=$(tgt_sql "
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 100 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'stg_newcust='||COUNT(*) FROM staging_schema.customers WHERE customer_id=9000001;
SELECT 'stg_updcust_credit='||NVL(TO_CHAR(MAX(credit_limit)),'NA') FROM staging_schema.customers WHERE customer_id=${MINC};
SELECT 'stg_neword='||COUNT(*) FROM staging_schema.orders WHERE order_id=9000001;
EXIT;" | grep -E '=')
echo "${VS}"
chk "STAGING 新規顧客反映"   "1"      "$(g "${VS}" stg_newcust)"
chk "STAGING 既存顧客更新"   "123456" "$(g "${VS}" stg_updcust_credit)"
chk "STAGING 新規注文反映"   "1"      "$(g "${VS}" stg_neword)"

echo ""
echo "### [B] ③ DELTA 変換 → TARGET 反映 ###"
transform "E2E_DELTA" "DELTA"
VT=$(tgt_sql "
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 120 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'tgt_newcust_name='||NVL(MAX(full_name),'MISSING') FROM target_schema.customers WHERE customer_id=9000001;
SELECT 'tgt_newcust_active='||NVL(MAX(is_active),'NA') FROM target_schema.customers WHERE customer_id=9000001;
SELECT 'tgt_updcust_credit='||NVL(TO_CHAR(MAX(credit_limit)),'NA') FROM target_schema.customers WHERE customer_id=${MINC};
SELECT 'tgt_neword_status='||NVL(MAX(order_status),'MISSING') FROM target_schema.orders WHERE order_id=9000001;
SELECT 'tgt_neword_net='||NVL(TO_CHAR(MAX(net_amount)),'NA') FROM target_schema.orders WHERE order_id=9000001;
SELECT 'tgt_cust_total='||COUNT(*) FROM target_schema.customers;
SELECT 'tgt_ord_total='||COUNT(*) FROM target_schema.orders;
EXIT;" | grep -E '=')
echo "${VT}"
chk "新規顧客 full_name"        "E2ELast E2EFirst" "$(g "${VT}" tgt_newcust_name)"
chk "新規顧客 is_active(ACTIVE)" "Y"               "$(g "${VT}" tgt_newcust_active)"
chk "既存顧客 credit 反映"      "123456"           "$(g "${VT}" tgt_updcust_credit)"
chk "新規注文 status"           "SHIPPED"          "$(g "${VT}" tgt_neword_status)"
chk "新規注文 net(10000-800)"   "9200"             "$(g "${VT}" tgt_neword_net)"
chk "TARGET customers 29452"    "29452"            "$(g "${VT}" tgt_cust_total)"
chk "TARGET orders 33591"       "33591"            "$(g "${VT}" tgt_ord_total)"

echo ""
echo "=================================================="
if [ "${PASS}" = "1" ]; then
  echo " [PASS] 統合 E2E: ①初期ロード→②差分→③変換 完全貫通"
else
  echo " [FAIL] 統合 E2E: 上記 NG 参照"
fi
echo "=================================================="
[ "${PASS}" = "1" ]
