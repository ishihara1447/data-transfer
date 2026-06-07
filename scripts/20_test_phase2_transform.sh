#!/usr/bin/env bash
# Phase 2 PoC テスト: STAGING→TARGET 変換層の E2E 検証（INITIAL モード）
# 設計: docs/phase2-transform-design.md
#
# 検証内容:
#   実スキーマ（data-generator 由来の現実的構造）に対し、変換層フレームワーク
#   （transform_catalog 駆動 + pkg_transform_util + pkg_transform）が
#   決定論的に STAGING を TARGET に変換することを E2E で確認する。
#
# シナリオ:
#   0. STAGING を決定論的シードで満たす（エッジケース込み）
#   1. pkg_transform.transform_all(INITIAL) 実行
#   2. 第1段階検証（件数）: STAGING 件数 = TARGET 件数
#   3. 第2段階検証（内容）: 各変換ロジックの正しさを個別アサート
#       - net_amount = total - tax
#       - lead_time_days = delivery - order（NULL時はNULL）
#       - 不正 status → 'UNKNOWN'
#       - phone 正規化（数字のみ）
#       - is_active フラグ（ACTIVE→Y, それ以外→N）
#       - full_name = last || ' ' || first / display_name 会社優先
#       - FK 整合（orders.customer_id 全件が customers に存在）
#   4. 冪等性: INITIAL 再実行で件数不変・重複なし
#
# 注意: SET SERVEROUTPUT は ALTER SESSION SET CONTAINER の後に置く（バッファリセット対策）

set -uo pipefail

TGT="oracle-tgt"

run_sql() {
  docker exec -u oracle ${TGT} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
$1
SQLEOF" 2>&1
}

echo "=============================================="
echo " Phase 2 PoC: 変換層 E2E テスト（INITIAL）"
echo "=============================================="

# ----------------------------------------------------------------
# Step 0: STAGING 決定論シード（エッジケース込み）
#   customers 5件: ACTIVE/SUSPENDED/CLOSED, 会社あり/なし, 電話ハイフン有無
#   orders 8件   : 正常 status 各種 + 不正 status 'WEIRD' + delivery NULL
# ----------------------------------------------------------------
echo ""
echo "[0] STAGING を決定論シードで満たす"
run_sql "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
DELETE FROM target_schema.orders;
DELETE FROM target_schema.customers;
DELETE FROM staging_schema.orders;
DELETE FROM staging_schema.customers;

-- customers
INSERT INTO staging_schema.customers(customer_id,customer_code,company_name,last_name,first_name,email,phone,region_id,credit_limit,status,created_at,updated_at) VALUES
 (1,'C001','Acme Corp','Tanaka','Taro','t.tanaka@acme.example','03-1234-5678',1,1000000,'ACTIVE',TIMESTAMP '2025-01-15 10:00:00',TIMESTAMP '2025-01-15 10:00:00');
INSERT INTO staging_schema.customers(customer_id,customer_code,company_name,last_name,first_name,email,phone,region_id,credit_limit,status,created_at,updated_at) VALUES
 (2,'C002',NULL,'Suzuki','Hanako','h.suzuki@example.com','090 1111 2222',2,500000,'SUSPENDED',TIMESTAMP '2025-02-20 14:30:00',TIMESTAMP '2025-02-20 14:30:00');
INSERT INTO staging_schema.customers(customer_id,customer_code,company_name,last_name,first_name,email,phone,region_id,credit_limit,status,created_at,updated_at) VALUES
 (3,'C003','Beta LLC','Yamada','Jiro','j.yamada@beta.example','(075)999-0000',1,0,'CLOSED',TIMESTAMP '2025-03-10 09:15:00',TIMESTAMP '2025-03-10 09:15:00');
INSERT INTO staging_schema.customers(customer_id,customer_code,company_name,last_name,first_name,email,phone,region_id,credit_limit,status,created_at,updated_at) VALUES
 (4,'C004',NULL,'Sato','Yumi','y.sato@example.com',NULL,3,250000,'ACTIVE',TIMESTAMP '2025-04-01 00:00:00',TIMESTAMP '2025-04-01 00:00:00');
INSERT INTO staging_schema.customers(customer_id,customer_code,company_name,last_name,first_name,email,phone,region_id,credit_limit,status,created_at,updated_at) VALUES
 (5,'C005','Gamma Inc','Ito','Ken','k.ito@gamma.example','08000001111',2,750000,'ACTIVE',TIMESTAMP '2025-05-05 18:45:00',TIMESTAMP '2025-05-05 18:45:00');

-- orders（customer_id は上記 1..5 を参照）
INSERT INTO staging_schema.orders(order_id,order_no,customer_id,shipping_region_id,status,order_date,ship_date,delivery_date,total_amount,tax_amount,created_at,updated_at) VALUES
 (101,'ORD101',1,1,'CONFIRMED',DATE '2025-06-01',DATE '2025-06-02',DATE '2025-06-05',11000,1000,SYSTIMESTAMP,SYSTIMESTAMP);
INSERT INTO staging_schema.orders(order_id,order_no,customer_id,shipping_region_id,status,order_date,ship_date,delivery_date,total_amount,tax_amount,created_at,updated_at) VALUES
 (102,'ORD102',1,1,'DELIVERED',DATE '2025-06-03',DATE '2025-06-04',DATE '2025-06-10',22000,2000,SYSTIMESTAMP,SYSTIMESTAMP);
INSERT INTO staging_schema.orders(order_id,order_no,customer_id,shipping_region_id,status,order_date,ship_date,delivery_date,total_amount,tax_amount,created_at,updated_at) VALUES
 (103,'ORD103',2,2,'PENDING',DATE '2025-06-05',NULL,NULL,5500,500,SYSTIMESTAMP,SYSTIMESTAMP);
INSERT INTO staging_schema.orders(order_id,order_no,customer_id,shipping_region_id,status,order_date,ship_date,delivery_date,total_amount,tax_amount,created_at,updated_at) VALUES
 (104,'ORD104',3,1,'CANCELLED',DATE '2025-06-06',NULL,NULL,3300,300,SYSTIMESTAMP,SYSTIMESTAMP);
INSERT INTO staging_schema.orders(order_id,order_no,customer_id,shipping_region_id,status,order_date,ship_date,delivery_date,total_amount,tax_amount,created_at,updated_at) VALUES
 (105,'ORD105',4,3,'SHIPPED',DATE '2025-06-07',DATE '2025-06-08',NULL,16500,1500,SYSTIMESTAMP,SYSTIMESTAMP);
INSERT INTO staging_schema.orders(order_id,order_no,customer_id,shipping_region_id,status,order_date,ship_date,delivery_date,total_amount,tax_amount,created_at,updated_at) VALUES
 (106,'ORD106',5,2,'RETURNED',DATE '2025-06-08',DATE '2025-06-09',DATE '2025-06-15',44000,4000,SYSTIMESTAMP,SYSTIMESTAMP);
INSERT INTO staging_schema.orders(order_id,order_no,customer_id,shipping_region_id,status,order_date,ship_date,delivery_date,total_amount,tax_amount,created_at,updated_at) VALUES
 (107,'ORD107',5,2,'WEIRD',DATE '2025-06-09',NULL,NULL,7700,700,SYSTIMESTAMP,SYSTIMESTAMP);
INSERT INTO staging_schema.orders(order_id,order_no,customer_id,shipping_region_id,status,order_date,ship_date,delivery_date,total_amount,tax_amount,created_at,updated_at) VALUES
 (108,'ORD108',2,2,'CONFIRMED',DATE '2025-06-10',DATE '2025-06-11',DATE '2025-06-12',9900,900,SYSTIMESTAMP,SYSTIMESTAMP);
COMMIT;
EXIT;
" >/dev/null
echo "    customers=5, orders=8 を投入（不正status 'WEIRD'・delivery NULL・電話各形式を含む）"

# ----------------------------------------------------------------
# Step 1: transform_all(INITIAL)
# ----------------------------------------------------------------
echo ""
echo "[1] pkg_transform.transform_all(INITIAL) 実行"
run_sql "
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF ECHO OFF
BEGIN log_schema.pkg_transform.transform_all('TRANSFORM_INITIAL_POC','INITIAL',10000); END;
/
EXIT;
" | grep -E "transform_all|ORA-|FAILED" || true

# ----------------------------------------------------------------
# Step 2 + 3: 検証（単一トークンで出力しパースしやすく）
# ----------------------------------------------------------------
echo ""
echo "[2/3] 検証"
V=$(run_sql "
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 120 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
-- 件数
SELECT 'cust_src=' || (SELECT COUNT(*) FROM staging_schema.customers) FROM DUAL;
SELECT 'cust_tgt=' || (SELECT COUNT(*) FROM target_schema.customers) FROM DUAL;
SELECT 'ord_src='  || (SELECT COUNT(*) FROM staging_schema.orders)    FROM DUAL;
SELECT 'ord_tgt='  || (SELECT COUNT(*) FROM target_schema.orders)     FROM DUAL;
-- net_amount: 全件 total-tax と一致するか（不一致件数=0 が正）
SELECT 'net_mismatch=' || COUNT(*) FROM target_schema.orders
  WHERE net_amount != total_amount - tax_amount;
-- lead_time: order 101 は 2025-06-05 - 2025-06-01 = 4
SELECT 'lead101=' || NVL(TO_CHAR(lead_time_days),'NULL') FROM target_schema.orders WHERE order_id=101;
-- lead_time NULL: order 103 は delivery NULL → NULL
SELECT 'lead103=' || NVL(TO_CHAR(lead_time_days),'NULL') FROM target_schema.orders WHERE order_id=103;
-- 不正 status: order 107 'WEIRD' → 'UNKNOWN'
SELECT 'status107=' || order_status FROM target_schema.orders WHERE order_id=107;
-- 正常 status は保持: order 101 'CONFIRMED'
SELECT 'status101=' || order_status FROM target_schema.orders WHERE order_id=101;
-- phone 正規化: cust1 '03-1234-5678' → '0312345678'
SELECT 'phone1=' || phone_normalized FROM target_schema.customers WHERE customer_id=1;
-- phone NULL: cust4 NULL → NULL
SELECT 'phone4=' || NVL(phone_normalized,'NULL') FROM target_schema.customers WHERE customer_id=4;
-- is_active: cust1 ACTIVE→Y, cust2 SUSPENDED→N, cust3 CLOSED→N
SELECT 'active1=' || is_active FROM target_schema.customers WHERE customer_id=1;
SELECT 'active2=' || is_active FROM target_schema.customers WHERE customer_id=2;
SELECT 'active3=' || is_active FROM target_schema.customers WHERE customer_id=3;
-- full_name: cust1 'Tanaka Taro'
SELECT 'fullname1=' || full_name FROM target_schema.customers WHERE customer_id=1;
-- display_name: cust1 会社あり→'Acme Corp', cust2 会社なし→'Suzuki Hanako'
SELECT 'display1=' || display_name FROM target_schema.customers WHERE customer_id=1;
SELECT 'display2=' || display_name FROM target_schema.customers WHERE customer_id=2;
-- created_date: cust1 TIMESTAMP→DATE
SELECT 'created1=' || TO_CHAR(created_date,'YYYY-MM-DD') FROM target_schema.customers WHERE customer_id=1;
-- FK整合: target orders で customers に存在しない customer_id があれば NG
SELECT 'fk_orphan=' || COUNT(*) FROM target_schema.orders o
  WHERE NOT EXISTS (SELECT 1 FROM target_schema.customers c WHERE c.customer_id=o.customer_id);
EXIT;
" | grep -E '=')
echo "${V}"

# 値抽出ヘルパ（値に空白を含む場合があるので cut で = 以降を全取得）
g() { echo "${V}" | grep -E "^$1=" | head -1 | cut -d= -f2-; }

echo ""
PASS=1
chk() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  [OK] $1 = $3"; else echo "  [NG] $1 期待'$2' 実際'$3'"; PASS=0; fi
}
chk "件数 customers (src=tgt)" "$(g cust_src)" "$(g cust_tgt)"
chk "件数 orders (src=tgt)"    "$(g ord_src)"  "$(g ord_tgt)"
chk "net_amount 不一致0"       "0"             "$(g net_mismatch)"
chk "lead_time_days(101)=4"    "4"             "$(g lead101)"
chk "lead_time_days(103)=NULL" "NULL"          "$(g lead103)"
chk "不正status(107)→UNKNOWN"  "UNKNOWN"       "$(g status107)"
chk "正常status(101)保持"      "CONFIRMED"     "$(g status101)"
chk "phone正規化(1)"           "0312345678"    "$(g phone1)"
chk "phone NULL(4)"            "NULL"          "$(g phone4)"
chk "is_active(1)ACTIVE→Y"     "Y"             "$(g active1)"
chk "is_active(2)SUSPENDED→N"  "N"             "$(g active2)"
chk "is_active(3)CLOSED→N"     "N"             "$(g active3)"
chk "full_name(1)"             "Tanaka Taro"   "$(g fullname1)"
chk "display_name(1)会社優先"  "Acme Corp"     "$(g display1)"
chk "display_name(2)個人名"    "Suzuki Hanako" "$(g display2)"
chk "created_date(1)TS→DATE"   "2025-01-15"    "$(g created1)"
chk "FK孤児0"                  "0"             "$(g fk_orphan)"

# ----------------------------------------------------------------
# Step 4: 冪等性（INITIAL 再実行で件数不変）
# ----------------------------------------------------------------
echo ""
echo "[4] 冪等性: INITIAL 再実行 → 件数不変・重複なし"
run_sql "
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF ECHO OFF
BEGIN log_schema.pkg_transform.transform_all('TRANSFORM_INITIAL_POC_2','INITIAL',10000); END;
/
EXIT;
" | grep -E "transform_all|ORA-" || true
V2=$(run_sql "
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 80 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'cust_tgt2=' || COUNT(*) FROM target_schema.customers;
SELECT 'ord_tgt2=' || COUNT(*) FROM target_schema.orders;
EXIT;
" | grep -E '=')
echo "${V2}"
CUST2=$(echo "${V2}" | grep -oE 'cust_tgt2=[0-9]+' | cut -d= -f2)
ORD2=$(echo "${V2}" | grep -oE 'ord_tgt2=[0-9]+' | cut -d= -f2)
chk "再実行後 customers=5" "5" "${CUST2:-?}"
chk "再実行後 orders=8"    "8" "${ORD2:-?}"

echo ""
if [ "${PASS}" = "1" ]; then
  echo "  [PASS] Phase2 PoC: 変換層フレームワークが決定論的に E2E 貫通（G5/G6 枠組み実証）"
else
  echo "  [FAIL] Phase2 PoC: 上記 NG 参照"
  exit 1
fi
echo "=============================================="
echo " Phase 2 PoC テスト完了"
echo "=============================================="
