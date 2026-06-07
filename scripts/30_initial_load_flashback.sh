#!/usr/bin/env bash
# G1: FLASHBACK_SCN 初期ロード → baseline → delta 接続
# 設計: docs/gap-analysis.md G1 / docs/phase2-transform-design.md（①と②の接続）
#
# 三分割アーキの ①初期ロード を確立し、②差分抽出の起点(baseline_scn)に接続する。
#
# 手順:
#   1. oracle-src で baseline_scn を採番（現在SCN）
#   2. expdp FLASHBACK_SCN=baseline で SRC_SCHEMA の対象表を整合点固定エクスポート
#   3. ダンプを oracle-src → oracle-tgt へ物理搬送
#   4. impdp で STAGING_SCHEMA にロード（remap_schema, content=DATA_ONLY, TRUNCATE）
#   5. oracle-src の delta_extract_state を baseline に設定
#        → last_extracted_commit_scn = baseline / mine_start_scn = baseline
#        → 以後 delta_extract は baseline 超のコミットのみ抽出（初期ロードとの重複なし）
#   6. 検証: STAGING 件数 = SRC の baseline 時点件数（FLASHBACK QUERY で照合）
#
# 対象表: REGIONS / CUSTOMERS / ORDERS（cdc_table_catalog と整合）
# 注意: STAGING は SRC 完全ミラー（LOB含む）。Data Pump は LOB もロードする。

set -euo pipefail

SRC="oracle-src"
TGT="oracle-tgt"
HOST_TMP="/tmp/initial_load"
DMP_FILE="initial_$(date +%Y%m%d_%H%M%S).dmp"
TABLES="SRC_SCHEMA.REGIONS,SRC_SCHEMA.CUSTOMERS,SRC_SCHEMA.ORDERS"
RUN_NAME="delta_run_01"

mkdir -p "${HOST_TMP}"

echo "=============================================="
echo " G1: FLASHBACK_SCN 初期ロード"
echo "=============================================="

# ----------------------------------------------------------------
# Step 1: baseline_scn 採番
# ----------------------------------------------------------------
echo ""
echo "[1] oracle-src: baseline_scn 採番"
BASELINE_SCN=$(docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT DBMS_FLASHBACK.GET_SYSTEM_CHANGE_NUMBER FROM DUAL;
EXIT;
SQLEOF" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
if [[ -z "${BASELINE_SCN}" ]]; then echo "ERROR: baseline_scn 採番失敗"; exit 1; fi
echo "  baseline_scn = ${BASELINE_SCN}"

# ----------------------------------------------------------------
# Step 2: expdp FLASHBACK_SCN（整合点固定）
# ----------------------------------------------------------------
echo ""
echo "[2] oracle-src: expdp FLASHBACK_SCN=${BASELINE_SCN}"
SRC_PASS=$(grep '^CDC_SCHEMA_PASS=' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"/.env | cut -d= -f2)
cat > "${HOST_TMP}/expdp_initial.par" << EOF
userid=cdc_schema/${SRC_PASS}@//localhost:1521/XEPDB1
tables=${TABLES}
flashback_scn=${BASELINE_SCN}
dumpfile=${DMP_FILE}
logfile=initial_export.log
directory=DATA_PUMP_DIR
reuse_dumpfiles=YES
EOF
docker cp "${HOST_TMP}/expdp_initial.par" "${SRC}:/tmp/expdp_initial.par" >/dev/null
docker exec -u oracle "${SRC}" bash -c "expdp parfile=/tmp/expdp_initial.par" 2>&1 \
    | grep -E "(Export:|Completed|ORA-|exported \")" | head -20

# ----------------------------------------------------------------
# Step 3: 物理搬送（src → ホスト → tgt）
# ----------------------------------------------------------------
echo ""
echo "[3] ダンプ搬送 oracle-src → oracle-tgt"
SRC_DMP_PATH=$(docker exec "${SRC}" bash -c "find /opt/oracle/admin/XE/dpdump -name '${DMP_FILE}' 2>/dev/null | head -1")
if [[ -z "${SRC_DMP_PATH}" ]]; then echo "ERROR: ダンプ未生成: ${DMP_FILE}"; exit 1; fi
docker cp "${SRC}:${SRC_DMP_PATH}" "${HOST_TMP}/${DMP_FILE}" >/dev/null
chmod 644 "${HOST_TMP}/${DMP_FILE}"
TGT_DMP_DIR=$(docker exec "${TGT}" bash -c "ls -d /opt/oracle/admin/XE/dpdump/*/ 2>/dev/null | head -1")
TGT_DMP_DIR="${TGT_DMP_DIR:-/opt/oracle/admin/XE/dpdump/}"
docker cp "${HOST_TMP}/${DMP_FILE}" "${TGT}:${TGT_DMP_DIR}${DMP_FILE}" >/dev/null
docker exec "${TGT}" bash -c "chmod 644 '${TGT_DMP_DIR}${DMP_FILE}'" 2>/dev/null || true
echo "  搬送完了: ${DMP_FILE}"

# ----------------------------------------------------------------
# Step 4: impdp → STAGING_SCHEMA（TRUNCATE で冪等）
# ----------------------------------------------------------------
echo ""
echo "[4] oracle-tgt: impdp → STAGING_SCHEMA（remap, DATA_ONLY, TRUNCATE）"
TGT_PASS="stagingctl1"
cat > "${HOST_TMP}/impdp_initial.par" << EOF
userid=staging_ctl/${TGT_PASS}@//localhost:1521/XEPDB1
tables=${TABLES}
remap_schema=SRC_SCHEMA:STAGING_SCHEMA
dumpfile=${DMP_FILE}
logfile=initial_import.log
directory=DATA_PUMP_DIR
content=DATA_ONLY
table_exists_action=TRUNCATE
EOF
docker cp "${HOST_TMP}/impdp_initial.par" "${TGT}:/tmp/impdp_initial.par" >/dev/null
docker exec -u oracle "${TGT}" bash -c "impdp parfile=/tmp/impdp_initial.par" 2>&1 \
    | grep -E "(Import:|Completed|ORA-|imported \")" | head -20

# ----------------------------------------------------------------
# Step 5: delta_extract_state を baseline に設定（①②の接続）
# ----------------------------------------------------------------
echo ""
echo "[5] oracle-src: delta_extract_state を baseline=${BASELINE_SCN} に設定"
docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<SQLEOF
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
MERGE INTO cdc_schema.delta_extract_state s
USING (SELECT '${RUN_NAME}' AS run_name FROM DUAL) d
ON (s.run_name = d.run_name)
WHEN MATCHED THEN UPDATE SET
   last_extracted_commit_scn = ${BASELINE_SCN},
   mine_start_scn = ${BASELINE_SCN},
   baseline_scn = ${BASELINE_SCN},
   status = 'IDLE'
WHEN NOT MATCHED THEN INSERT
   (run_name, last_extracted_commit_scn, mine_start_scn, baseline_scn, status)
   VALUES ('${RUN_NAME}', ${BASELINE_SCN}, ${BASELINE_SCN}, ${BASELINE_SCN}, 'IDLE');
DELETE FROM cdc_schema.delta_queue;
COMMIT;
EXIT;
SQLEOF" >/dev/null 2>&1
echo "  完了（以後 delta_extract は SCN > ${BASELINE_SCN} のコミットのみ抽出）"

# ----------------------------------------------------------------
# Step 5b: DDL凍結の基準スナップショット（G7。初期ロード時点を凍結基準に）
# ----------------------------------------------------------------
echo ""
echo "[5b] DDL凍結基準スナップショット（G7）"
bash "$(dirname "$0")/60_ddl_freeze.sh" snapshot >/dev/null 2>&1 && echo "  完了" || echo "  警告: snapshot失敗（60_ddl_freeze.sh）"

# ----------------------------------------------------------------
# Step 6: 検証 — STAGING 件数 = SRC の baseline 時点件数
# ----------------------------------------------------------------
echo ""
echo "[6] 検証: STAGING 件数 = SRC(baseline=${BASELINE_SCN}) 件数"
SRC_CNT=$(docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<SQLEOF
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 100
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'reg='||(SELECT COUNT(*) FROM src_schema.regions   AS OF SCN ${BASELINE_SCN})||
     ' cust='||(SELECT COUNT(*) FROM src_schema.customers AS OF SCN ${BASELINE_SCN})||
     ' ord='||(SELECT COUNT(*) FROM src_schema.orders     AS OF SCN ${BASELINE_SCN}) FROM DUAL;
EXIT;
SQLEOF" 2>/dev/null | grep -E 'reg=')
TGT_CNT=$(docker exec -u oracle ${TGT} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 100
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'reg='||(SELECT COUNT(*) FROM staging_schema.regions)||
     ' cust='||(SELECT COUNT(*) FROM staging_schema.customers)||
     ' ord='||(SELECT COUNT(*) FROM staging_schema.orders) FROM DUAL;
EXIT;
SQLEOF" 2>/dev/null | grep -E 'reg=')
echo "  SRC(baseline): ${SRC_CNT}"
echo "  STAGING      : ${TGT_CNT}"
if [ "${SRC_CNT}" = "${TGT_CNT}" ]; then
    echo ""
    echo "  [PASS] G1: 初期ロード件数一致・baseline 接続完了"
else
    echo ""
    echo "  [FAIL] G1: 件数不一致（SRC baseline vs STAGING）"
    exit 1
fi
echo "  baseline_scn=${BASELINE_SCN} を記録（後続の差分検証で使用）"
echo "${BASELINE_SCN}" > "${HOST_TMP}/last_baseline_scn.txt"
echo "=============================================="
echo " G1 完了"
echo "=============================================="
