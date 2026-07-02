#!/usr/bin/env bash
# LOBテーブル差分反映: 周期的ターゲット再同期サイクル
# docs/delta-extract-design.md セクション11 の設計に基づく。
#
# 処理フロー（1サイクル）:
#   Step0: lob_resync_build_targets で review_queue → lob_resync_target に集約
#   Step1: tgt の lob_resync_target(PENDING) を expdp → docker cp → src に impdp（tgt→src搬送）
#   Step2: src で SYS.lob_resync_export_rows（件数確認）
#   Step3: src の SRC_SCHEMA.CUSTOMERS/ORDERS を PKリスト指定で expdp → docker cp → tgt シャドウ表に impdp（src→tgt搬送）
#   Step4: tgt で SYS.lob_resync_merge（シャドウ表 → STAGING_SCHEMA MERGE）
#
# 特徴:
#   - 冪等: 再実行しても二重適用しない（lob_resync_target の UNIQUE 制約・resync_status 管理）
#   - 役割分離: 移行ロジックはすべて PL/SQL（このスクリプトは搬送・起動のみ）
#   - 06_transfer_delta_datapump.sh の搬送パターンを往復適用
#
# 使い方:
#   bash scripts/43_lob_resync_cycle.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="oracle-src"
TGT="oracle-tgt"
HOST_TMP="/tmp/lob_resync_transfer"
LOG_PREFIX="lob_resync"
TS=$(date +%Y%m%d_%H%M%S)

mkdir -p "${HOST_TMP}"

# パスワード読み込み
TGT_PASS="stagingctl1"
SRC_PASS=$(grep '^CDC_SCHEMA_PASS=' "${ROOT}/.env" | cut -d= -f2)
if [[ -z "${SRC_PASS}" ]]; then
    SRC_PASS="cdcpass1"
fi

echo "=============================================="
echo " LOB再同期サイクル開始 (${TS})"
echo "=============================================="

# ---- ヘルパー関数: sqlplus 数値出力の取り出し ----
num() { grep -oE '[0-9]+' | tail -1; }

# ----------------------------------------------------------------
# Step0: tgt で lob_resync_build_targets を実行
#   delta_manual_review_queue の PENDING LOB行 → lob_resync_target に集約
# ----------------------------------------------------------------
echo "[Step0] oracle-tgt: lob_resync_build_targets（review_queue → resync_target 集約）"
docker exec -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED
BEGIN SYS.lob_resync_build_targets; END;
/
SQLEOF" 2>&1

# PENDING 件数確認（0件なら後続スキップ）
PENDING_CNT=$(docker exec -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT COUNT(*) FROM staging_ctl.lob_resync_target WHERE resync_status='PENDING';
SQLEOF" 2>/dev/null | num)
PENDING_CNT="${PENDING_CNT:-0}"

echo "  PENDING 件数: ${PENDING_CNT}"

if [ "${PENDING_CNT}" -eq 0 ]; then
    echo "  PENDING なし。サイクル完了。"
    echo "=============================================="
    echo " LOB再同期サイクル完了（処理なし）"
    echo "=============================================="
    exit 0
fi

# ----------------------------------------------------------------
# Step1: tgt の lob_resync_target(PENDING) を expdp（tgt→src 搬送）
#   remap の関係上: tgt は staging_ctl で接続 → src 側で staging_ctl→cdc_schema にリマップ
#   ※ UNIQUE 制約があるため table_exists_action=TRUNCATE でリセットしてから impdp
# ----------------------------------------------------------------
echo "[Step1] oracle-tgt: lob_resync_target(PENDING) を expdp"
TGT_DMP_FILE="lob_target_${TS}.dmp"

cat > "${HOST_TMP}/expdp_lob_target.par" << EOF
userid=staging_ctl/${TGT_PASS}@//localhost:1521/XEPDB1
tables=STAGING_CTL.LOB_RESYNC_TARGET
query=STAGING_CTL.LOB_RESYNC_TARGET:"WHERE resync_status='PENDING'"
dumpfile=${TGT_DMP_FILE}
logfile=${LOG_PREFIX}_target_export.log
directory=DATA_PUMP_DIR
reuse_dumpfiles=YES
EOF

docker cp "${HOST_TMP}/expdp_lob_target.par" "${TGT}:/tmp/expdp_lob_target.par"
docker exec -u oracle "${TGT}" bash -c "expdp parfile=/tmp/expdp_lob_target.par" 2>&1 \
    | grep -E "(Export:|Master|Completed|ORA-|exported|rows)" | head -20 || true

echo "[Step1] ダンプファイルを tgt → src に搬送"

# tgt の DATA_PUMP_DIR 実パスを取得
TGT_DMP_DIR=$(docker exec -i -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT directory_path FROM dba_directories WHERE directory_name='DATA_PUMP_DIR';
SQLEOF" 2>/dev/null | tr -d '[:space:]')
TGT_DMP_DIR="${TGT_DMP_DIR:-/opt/oracle/admin/XE/dpdump}"

TGT_DMP_PATH=$(docker exec "${TGT}" bash -c "find ${TGT_DMP_DIR} -name '${TGT_DMP_FILE}' 2>/dev/null | head -1")
if [[ -z "${TGT_DMP_PATH}" ]]; then
    echo "ERROR: tgt ダンプファイルが見つかりません: ${TGT_DMP_FILE}"
    exit 1
fi
echo "  tgt 実パス: ${TGT_DMP_PATH}"

docker cp "${TGT}:${TGT_DMP_PATH}" "${HOST_TMP}/${TGT_DMP_FILE}"
chmod 644 "${HOST_TMP}/${TGT_DMP_FILE}"

# src の DATA_PUMP_DIR 実パスを取得して配置
SRC_DMP_DIR=$(docker exec -i -u oracle "${SRC}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT directory_path FROM dba_directories WHERE directory_name='DATA_PUMP_DIR';
SQLEOF" 2>/dev/null | tr -d '[:space:]')
SRC_DMP_DIR="${SRC_DMP_DIR:-/opt/oracle/admin/XE/dpdump}"

docker exec -u oracle "${SRC}" bash -c "mkdir -p '${SRC_DMP_DIR}'"
docker cp "${HOST_TMP}/${TGT_DMP_FILE}" "${SRC}:${SRC_DMP_DIR}/${TGT_DMP_FILE}"
docker exec "${SRC}" bash -c "chmod 644 '${SRC_DMP_DIR}/${TGT_DMP_FILE}'" 2>/dev/null || true

echo "[Step1] oracle-src: lob_resync_request に impdp（remap staging_ctl→cdc_schema）"
cat > "${HOST_TMP}/impdp_lob_request.par" << EOF
userid=cdc_schema/${SRC_PASS}@//localhost:1521/XEPDB1
tables=STAGING_CTL.LOB_RESYNC_TARGET
remap_schema=STAGING_CTL:CDC_SCHEMA
remap_table=LOB_RESYNC_TARGET:LOB_RESYNC_REQUEST
dumpfile=${TGT_DMP_FILE}
logfile=${LOG_PREFIX}_request_import.log
directory=DATA_PUMP_DIR
content=DATA_ONLY
table_exists_action=TRUNCATE
EOF

docker cp "${HOST_TMP}/impdp_lob_request.par" "${SRC}:/tmp/impdp_lob_request.par"
docker exec -u oracle "${SRC}" bash -c "impdp parfile=/tmp/impdp_lob_request.par" 2>&1 \
    | grep -E "(Import:|Master|Completed|ORA-|imported|rows)" | head -20 || true

# lob_resync_target の resync_status を PENDING → IN_TRANSIT に更新
echo "[Step1] oracle-tgt: resync_status を PENDING → IN_TRANSIT に更新"
INTRANSIT_CNT=$(docker exec -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
BEGIN
    UPDATE staging_ctl.lob_resync_target SET resync_status='IN_TRANSIT' WHERE resync_status='PENDING';
    COMMIT;
END;
/
SELECT COUNT(*) FROM staging_ctl.lob_resync_target WHERE resync_status='IN_TRANSIT';
SQLEOF" 2>/dev/null | grep -oE '[0-9]+' | tail -1) || true
INTRANSIT_CNT="${INTRANSIT_CNT:-0}"
echo "  IN_TRANSIT 件数: ${INTRANSIT_CNT}"

# ----------------------------------------------------------------
# Step2: src で lob_resync_export_rows（件数確認）
# ----------------------------------------------------------------
echo "[Step2] oracle-src: lob_resync_export_rows（件数確認）"
docker exec -u oracle "${SRC}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED
BEGIN SYS.lob_resync_export_rows; END;
/
SQLEOF" 2>&1

# リクエスト件数確認
REQ_CUST=$(docker exec -u oracle "${SRC}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT COUNT(*) FROM cdc_schema.lob_resync_request WHERE table_name='CUSTOMERS';
SQLEOF" 2>/dev/null | num)
REQ_ORD=$(docker exec -u oracle "${SRC}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT COUNT(*) FROM cdc_schema.lob_resync_request WHERE table_name='ORDERS';
SQLEOF" 2>/dev/null | num)
REQ_CUST="${REQ_CUST:-0}"; REQ_ORD="${REQ_ORD:-0}"
echo "  CUSTOMERS 要求: ${REQ_CUST} 件, ORDERS 要求: ${REQ_ORD} 件"

# ----------------------------------------------------------------
# Step3: src の SRC_SCHEMA をPKリスト指定で expdp → tgt シャドウ表に impdp（src→tgt搬送）
#   CUSTOMERS と ORDERS をそれぞれ別ダンプファイルでエクスポートする
# ----------------------------------------------------------------
echo "[Step3] oracle-src: SRC_SCHEMA から対象行を expdp（LOB本体込み）"

# --- Step3a: CUSTOMERS エクスポート ---
if [ "${REQ_CUST}" -gt 0 ]; then
    SRC_CUST_DMP="lob_rows_customers_${TS}.dmp"
    # expdp: SRC_SCHEMA.CUSTOMERS を PKリスト指定でエクスポート
    # remap は impdp 側で指定（expdp の remap_schema/remap_table は impdp のパラメータ）
    cat > "${HOST_TMP}/expdp_customers.par" << EOF
userid=cdc_schema/${SRC_PASS}@//localhost:1521/XEPDB1
tables=SRC_SCHEMA.CUSTOMERS
query=SRC_SCHEMA.CUSTOMERS:"WHERE customer_id IN (SELECT TO_NUMBER(pk_value) FROM cdc_schema.lob_resync_request WHERE table_name='CUSTOMERS')"
dumpfile=${SRC_CUST_DMP}
logfile=${LOG_PREFIX}_customers_export.log
directory=DATA_PUMP_DIR
reuse_dumpfiles=YES
EOF
    docker cp "${HOST_TMP}/expdp_customers.par" "${SRC}:/tmp/expdp_customers.par"
    docker exec -u oracle "${SRC}" bash -c "expdp parfile=/tmp/expdp_customers.par" 2>&1 \
        | grep -E "(Export:|Master|Completed|ORA-|exported|rows)" | head -20 || true

    # src → ホスト → tgt 搬送
    SRC_CUST_PATH=$(docker exec "${SRC}" bash -c "find ${SRC_DMP_DIR} -name '${SRC_CUST_DMP}' 2>/dev/null | head -1")
    if [[ -n "${SRC_CUST_PATH}" ]]; then
        docker cp "${SRC}:${SRC_CUST_PATH}" "${HOST_TMP}/${SRC_CUST_DMP}"
        chmod 644 "${HOST_TMP}/${SRC_CUST_DMP}"
        docker exec -u oracle "${TGT}" bash -c "mkdir -p '${TGT_DMP_DIR}'"
        docker cp "${HOST_TMP}/${SRC_CUST_DMP}" "${TGT}:${TGT_DMP_DIR}/${SRC_CUST_DMP}"
        docker exec "${TGT}" bash -c "chmod 644 '${TGT_DMP_DIR}/${SRC_CUST_DMP}'" 2>/dev/null || true
        echo "  CUSTOMERS ダンプ搬送完了: ${SRC_CUST_DMP}"

        # tgt に impdp（シャドウ表に TRUNCATE して取り込み）
        # remap_schema=SRC_SCHEMA:STAGING_CTL, remap_table=CUSTOMERS:LOB_RESYNC_STAGE_CUSTOMERS
        cat > "${HOST_TMP}/impdp_customers.par" << EOF
userid=staging_ctl/${TGT_PASS}@//localhost:1521/XEPDB1
tables=SRC_SCHEMA.CUSTOMERS
remap_schema=SRC_SCHEMA:STAGING_CTL
remap_table=CUSTOMERS:LOB_RESYNC_STAGE_CUSTOMERS
dumpfile=${SRC_CUST_DMP}
logfile=${LOG_PREFIX}_customers_import.log
directory=DATA_PUMP_DIR
content=DATA_ONLY
table_exists_action=TRUNCATE
EOF
        docker cp "${HOST_TMP}/impdp_customers.par" "${TGT}:/tmp/impdp_customers.par"
        docker exec -u oracle "${TGT}" bash -c "impdp parfile=/tmp/impdp_customers.par" 2>&1 \
            | grep -E "(Import:|Master|Completed|ORA-|imported|rows)" | head -20 || true
    else
        echo "  WARN: CUSTOMERS ダンプファイルが見つかりません（0行エクスポートの可能性）"
    fi
else
    echo "  CUSTOMERS 要求なし。スキップ。"
fi

# --- Step3b: ORDERS エクスポート ---
if [ "${REQ_ORD}" -gt 0 ]; then
    SRC_ORD_DMP="lob_rows_orders_${TS}.dmp"
    cat > "${HOST_TMP}/expdp_orders.par" << EOF
userid=cdc_schema/${SRC_PASS}@//localhost:1521/XEPDB1
tables=SRC_SCHEMA.ORDERS
query=SRC_SCHEMA.ORDERS:"WHERE order_id IN (SELECT TO_NUMBER(pk_value) FROM cdc_schema.lob_resync_request WHERE table_name='ORDERS')"
dumpfile=${SRC_ORD_DMP}
logfile=${LOG_PREFIX}_orders_export.log
directory=DATA_PUMP_DIR
reuse_dumpfiles=YES
EOF
    docker cp "${HOST_TMP}/expdp_orders.par" "${SRC}:/tmp/expdp_orders.par"
    docker exec -u oracle "${SRC}" bash -c "expdp parfile=/tmp/expdp_orders.par" 2>&1 \
        | grep -E "(Export:|Master|Completed|ORA-|exported|rows)" | head -20 || true

    # src → ホスト → tgt 搬送
    SRC_ORD_PATH=$(docker exec "${SRC}" bash -c "find ${SRC_DMP_DIR} -name '${SRC_ORD_DMP}' 2>/dev/null | head -1")
    if [[ -n "${SRC_ORD_PATH}" ]]; then
        docker cp "${SRC}:${SRC_ORD_PATH}" "${HOST_TMP}/${SRC_ORD_DMP}"
        chmod 644 "${HOST_TMP}/${SRC_ORD_DMP}"
        docker cp "${HOST_TMP}/${SRC_ORD_DMP}" "${TGT}:${TGT_DMP_DIR}/${SRC_ORD_DMP}"
        docker exec "${TGT}" bash -c "chmod 644 '${TGT_DMP_DIR}/${SRC_ORD_DMP}'" 2>/dev/null || true
        echo "  ORDERS ダンプ搬送完了: ${SRC_ORD_DMP}"

        # tgt に impdp（シャドウ表に TRUNCATE して取り込み）
        cat > "${HOST_TMP}/impdp_orders.par" << EOF
userid=staging_ctl/${TGT_PASS}@//localhost:1521/XEPDB1
tables=SRC_SCHEMA.ORDERS
remap_schema=SRC_SCHEMA:STAGING_CTL
remap_table=ORDERS:LOB_RESYNC_STAGE_ORDERS
dumpfile=${SRC_ORD_DMP}
logfile=${LOG_PREFIX}_orders_import.log
directory=DATA_PUMP_DIR
content=DATA_ONLY
table_exists_action=TRUNCATE
EOF
        docker cp "${HOST_TMP}/impdp_orders.par" "${TGT}:/tmp/impdp_orders.par"
        docker exec -u oracle "${TGT}" bash -c "impdp parfile=/tmp/impdp_orders.par" 2>&1 \
            | grep -E "(Import:|Master|Completed|ORA-|imported|rows)" | head -20 || true
    else
        echo "  WARN: ORDERS ダンプファイルが見つかりません（0行エクスポートの可能性）"
    fi
else
    echo "  ORDERS 要求なし。スキップ。"
fi

# ----------------------------------------------------------------
# Step4: tgt で lob_resync_merge（シャドウ表 → STAGING_SCHEMA MERGE）
# ----------------------------------------------------------------
echo "[Step4] oracle-tgt: lob_resync_merge（シャドウ表 → STAGING_SCHEMA MERGE）"
docker exec -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED
BEGIN SYS.lob_resync_merge; END;
/
SQLEOF" 2>&1

echo "=============================================="
echo " LOB再同期サイクル完了"
echo "=============================================="
