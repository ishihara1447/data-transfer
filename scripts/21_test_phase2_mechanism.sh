#!/usr/bin/env bash
# Phase 2 機構テスト: PASS_THROUGH / DELTA増分 / 削除伝播
# 設計: docs/phase2-transform-design.md 3章(3分類)/5章(DELTA)/6章(削除)
#
# 検証内容:
#   1. INITIAL: regions(PASS_THROUGH 1:1) + customers/orders(LIGHT) を全量変換
#   2. DELTA増分: スナップショット窓 (last, snap] で「変更行のみ」MERGE
#   3. 削除伝播: STAGING から消えた PK が TARGET からも消える
#   4. 冪等性: DELTA 再実行で変化なし
#
# 注意:
#   - 各フェーズ間に sleep を入れ updated_at の時刻分離を保証する
#   - transform_all INITIAL は TARGET 全削除するため本テストは専用データで隔離実行

set -uo pipefail
TGT="oracle-tgt"

run_sql() {
  docker exec -u oracle ${TGT} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
$1
SQLEOF" 2>&1
}
transform() {  # $1=run_name $2=mode
  run_sql "
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF ECHO OFF
BEGIN log_schema.pkg_transform.transform_all('$1','$2',10000,'Y'); END;
/
EXIT;
" | grep -E "transform_all|ORA-|FAILED" || true
}

PASS=1
chk() { if [ "$2" = "$3" ]; then echo "  [OK] $1 = $3"; else echo "  [NG] $1 期待'$2' 実際'$3'"; PASS=0; fi; }

echo "=============================================="
echo " Phase 2 機構テスト: PASS_THROUGH / DELTA / 削除伝播"
echo "=============================================="

# ----------------------------------------------------------------
# Step 0: 専用データで初期化（STAGING/TARGET 全クリア + state リセット）
#   created_at/updated_at を過去固定（2020-01-01）→ INITIAL の snap より前
# ----------------------------------------------------------------
echo ""
echo "[0] STAGING/TARGET クリア & 初期シード（過去タイムスタンプ）"
run_sql "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
DELETE FROM target_schema.orders;
DELETE FROM target_schema.customers;
DELETE FROM target_schema.regions;
DELETE FROM staging_schema.orders;
DELETE FROM staging_schema.customers;
DELETE FROM staging_schema.regions;
UPDATE log_schema.transform_state SET last_transform_at = TIMESTAMP '1970-01-01 00:00:00';

-- regions (PASS_THROUGH): 3件
INSERT INTO staging_schema.regions(region_id,region_code,region_name,parent_region_id,display_order,is_active,created_at,updated_at) VALUES (901,'R901','East',NULL,1,1,TIMESTAMP '2020-01-01 00:00:00',TIMESTAMP '2020-01-01 00:00:00');
INSERT INTO staging_schema.regions(region_id,region_code,region_name,parent_region_id,display_order,is_active,created_at,updated_at) VALUES (902,'R902','West',NULL,2,1,TIMESTAMP '2020-01-01 00:00:00',TIMESTAMP '2020-01-01 00:00:00');
INSERT INTO staging_schema.regions(region_id,region_code,region_name,parent_region_id,display_order,is_active,created_at,updated_at) VALUES (903,'R903','North',NULL,3,1,TIMESTAMP '2020-01-01 00:00:00',TIMESTAMP '2020-01-01 00:00:00');

-- customers (LIGHT): 3件
INSERT INTO staging_schema.customers(customer_id,customer_code,company_name,last_name,first_name,email,phone,region_id,credit_limit,status,created_at,updated_at) VALUES (901,'C901','Acme','Aoki','Ichiro','a@x.example','03-1-1',901,100,'ACTIVE',TIMESTAMP '2020-01-01 00:00:00',TIMESTAMP '2020-01-01 00:00:00');
INSERT INTO staging_schema.customers(customer_id,customer_code,company_name,last_name,first_name,email,phone,region_id,credit_limit,status,created_at,updated_at) VALUES (902,'C902',NULL,'Baba','Jiro','b@x.example','03-2-2',902,200,'ACTIVE',TIMESTAMP '2020-01-01 00:00:00',TIMESTAMP '2020-01-01 00:00:00');
INSERT INTO staging_schema.customers(customer_id,customer_code,company_name,last_name,first_name,email,phone,region_id,credit_limit,status,created_at,updated_at) VALUES (903,'C903',NULL,'Chiba','Saburo','c@x.example','03-3-3',903,300,'SUSPENDED',TIMESTAMP '2020-01-01 00:00:00',TIMESTAMP '2020-01-01 00:00:00');

-- orders (LIGHT): 3件
INSERT INTO staging_schema.orders(order_id,order_no,customer_id,shipping_region_id,status,order_date,ship_date,delivery_date,total_amount,tax_amount,created_at,updated_at) VALUES (9101,'O9101',901,901,'CONFIRMED',DATE '2020-01-01',NULL,NULL,1100,100,TIMESTAMP '2020-01-01 00:00:00',TIMESTAMP '2020-01-01 00:00:00');
INSERT INTO staging_schema.orders(order_id,order_no,customer_id,shipping_region_id,status,order_date,ship_date,delivery_date,total_amount,tax_amount,created_at,updated_at) VALUES (9102,'O9102',902,902,'DELIVERED',DATE '2020-01-01',DATE '2020-01-02',DATE '2020-01-05',2200,200,TIMESTAMP '2020-01-01 00:00:00',TIMESTAMP '2020-01-01 00:00:00');
INSERT INTO staging_schema.orders(order_id,order_no,customer_id,shipping_region_id,status,order_date,ship_date,delivery_date,total_amount,tax_amount,created_at,updated_at) VALUES (9103,'O9103',903,903,'PENDING',DATE '2020-01-01',NULL,NULL,3300,300,TIMESTAMP '2020-01-01 00:00:00',TIMESTAMP '2020-01-01 00:00:00');
COMMIT;
EXIT;
" >/dev/null
echo "    regions=3, customers=3, orders=3 投入"

# ----------------------------------------------------------------
# Step 1: INITIAL 変換
# ----------------------------------------------------------------
echo ""
echo "[1] transform_all(INITIAL) — 3分類すべて全量変換"
transform "MECH_INITIAL" "INITIAL"
V=$(run_sql "
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 100 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'reg_tgt=' || COUNT(*) FROM target_schema.regions;
SELECT 'cust_tgt=' || COUNT(*) FROM target_schema.customers;
SELECT 'ord_tgt=' || COUNT(*) FROM target_schema.orders;
SELECT 'reg901_name=' || region_name FROM target_schema.regions WHERE region_id=901;
EXIT;
" | grep -E '=')
echo "${V}"
g() { echo "${V}" | grep -E "^$1=" | head -1 | cut -d= -f2-; }
chk "PASS_THROUGH regions 1:1 (3)" "3" "$(g reg_tgt)"
chk "customers (3)"                "3" "$(g cust_tgt)"
chk "orders (3)"                   "3" "$(g ord_tgt)"
chk "regions 内容コピー(901)"      "East" "$(g reg901_name)"

# ----------------------------------------------------------------
# Step 2: DELTA増分（変更行のみ処理されること）
#   - 新規 region 904
#   - customer 901 を UPDATE（credit_limit 変更 + updated_at=NOW）
#   - 新規 order 9104
#   既存の未変更行は updated_at が過去のまま → 窓外 → 再処理されない
# ----------------------------------------------------------------
echo ""
echo "[2] DELTA増分: region追加 / customer更新 / order追加（変更行のみ）"
sleep 2   # INITIAL の snap との時刻分離
run_sql "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
INSERT INTO staging_schema.regions(region_id,region_code,region_name,parent_region_id,display_order,is_active,created_at,updated_at) VALUES (904,'R904','South',NULL,4,1,SYSTIMESTAMP,SYSTIMESTAMP);
UPDATE staging_schema.customers SET credit_limit=9999, status='CLOSED', updated_at=SYSTIMESTAMP WHERE customer_id=901;
INSERT INTO staging_schema.orders(order_id,order_no,customer_id,shipping_region_id,status,order_date,ship_date,delivery_date,total_amount,tax_amount,created_at,updated_at) VALUES (9104,'O9104',902,902,'SHIPPED',DATE '2020-02-01',DATE '2020-02-02',NULL,5500,500,SYSTIMESTAMP,SYSTIMESTAMP);
COMMIT;
EXIT;
" >/dev/null
transform "MECH_DELTA1" "DELTA"
V=$(run_sql "
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 100 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'reg_tgt=' || COUNT(*) FROM target_schema.regions;
SELECT 'cust_tgt=' || COUNT(*) FROM target_schema.customers;
SELECT 'ord_tgt=' || COUNT(*) FROM target_schema.orders;
SELECT 'reg904=' || NVL(MAX(region_name),'MISSING') FROM target_schema.regions WHERE region_id=904;
SELECT 'cust901_credit=' || NVL(TO_CHAR(MAX(credit_limit)),'MISSING') FROM target_schema.customers WHERE customer_id=901;
SELECT 'cust901_active=' || NVL(MAX(is_active),'MISSING') FROM target_schema.customers WHERE customer_id=901;
SELECT 'ord9104=' || NVL(MAX(order_status),'MISSING') FROM target_schema.orders WHERE order_id=9104;
EXIT;
" | grep -E '=')
echo "${V}"
chk "regions 4件に増加"            "4" "$(g reg_tgt)"
chk "customers 3件のまま(更新)"    "3" "$(g cust_tgt)"
chk "orders 4件に増加"             "4" "$(g ord_tgt)"
chk "新規region904反映"            "South" "$(g reg904)"
chk "customer901更新(credit)"      "9999" "$(g cust901_credit)"
chk "customer901更新(CLOSED→N)"    "N" "$(g cust901_active)"
chk "新規order9104反映"            "SHIPPED" "$(g ord9104)"

# ----------------------------------------------------------------
# Step 3: 削除伝播（STAGING から消した PK が TARGET からも消える）
#   - region 903 を STAGING から削除
#   - order 9103 を STAGING から削除
# ----------------------------------------------------------------
echo ""
echo "[3] 削除伝播: STAGING から region903 / order9103 を削除"
sleep 2
run_sql "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
DELETE FROM staging_schema.regions WHERE region_id=903;
DELETE FROM staging_schema.orders WHERE order_id=9103;
COMMIT;
EXIT;
" >/dev/null
transform "MECH_DELTA2" "DELTA"
V=$(run_sql "
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 100 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'reg_tgt=' || COUNT(*) FROM target_schema.regions;
SELECT 'ord_tgt=' || COUNT(*) FROM target_schema.orders;
SELECT 'reg903=' || COUNT(*) FROM target_schema.regions WHERE region_id=903;
SELECT 'ord9103=' || COUNT(*) FROM target_schema.orders WHERE order_id=9103;
EXIT;
" | grep -E '=')
echo "${V}"
chk "regions 3件に減少(削除伝播)"  "3" "$(g reg_tgt)"
chk "orders 3件に減少(削除伝播)"   "3" "$(g ord_tgt)"
chk "region903 TARGET から消滅"    "0" "$(g reg903)"
chk "order9103 TARGET から消滅"    "0" "$(g ord9103)"

# ----------------------------------------------------------------
# Step 4: 冪等性（DELTA 再実行で変化なし）
# ----------------------------------------------------------------
echo ""
echo "[4] 冪等性: DELTA 再実行で件数不変"
sleep 2
transform "MECH_DELTA3" "DELTA"
V=$(run_sql "
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 100 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'reg_tgt=' || COUNT(*) FROM target_schema.regions;
SELECT 'cust_tgt=' || COUNT(*) FROM target_schema.customers;
SELECT 'ord_tgt=' || COUNT(*) FROM target_schema.orders;
EXIT;
" | grep -E '=')
echo "${V}"
chk "再実行 regions=3"   "3" "$(g reg_tgt)"
chk "再実行 customers=3" "3" "$(g cust_tgt)"
chk "再実行 orders=3"    "3" "$(g ord_tgt)"

echo ""
if [ "${PASS}" = "1" ]; then
  echo "  [PASS] Phase2 機構: PASS_THROUGH / DELTA増分 / 削除伝播 すべて動作"
else
  echo "  [FAIL] Phase2 機構: 上記 NG 参照"; exit 1
fi
echo "=============================================="
echo " Phase 2 機構テスト完了"
echo "=============================================="
