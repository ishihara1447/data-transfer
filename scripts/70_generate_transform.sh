#!/usr/bin/env bash
# 変換PL/SQL 自動生成ドライバ
# pkg_codegen.generate_all を実行し、生成された SQL（pkg_transform_gen + catalog登録）を
# ホストの generated/ に書き出し、任意で oracle-tgt にデプロイする。
#
# 使い方:
#   bash scripts/70_generate_transform.sh           # 生成 + デプロイ
#   bash scripts/70_generate_transform.sh --no-deploy  # 生成のみ
#
# 前提: 40(setup)/41(util)/42(core)/70(mapping tables)/71(pkg_codegen) デプロイ済み、
#       マッピング(72 等)投入済み。

set -uo pipefail
ROOT="/home/ishihara1447/projects/data-transfer"
TGT="oracle-tgt"
GEN_DIR="${ROOT}/generated"
GEN_FILE="${GEN_DIR}/pkg_transform_gen.sql"
DEPLOY=1
[ "${1:-}" = "--no-deploy" ] && DEPLOY=0
mkdir -p "${GEN_DIR}"

echo "=============================================="
echo " 変換PL/SQL 自動生成 (pkg_codegen)"
echo "=============================================="

# ---- 生成: DBMS_OUTPUT を stdout で受けてファイル化 ----
# 注意: SET SERVEROUTPUT は ALTER SESSION SET CONTAINER の後（バッファリセット対策）
echo "[1] generate -> ${GEN_FILE}"
docker exec -u oracle ${TGT} bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 LINESIZE 4000 FEEDBACK OFF ECHO OFF HEADING OFF VERIFY OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED
BEGIN log_schema.pkg_codegen.generate_all; END;
/
EXIT;
EOF" 2>/dev/null > "${GEN_FILE}"

# 先頭/末尾の空行を除去
sed -i '/^[[:space:]]*$/{/CREATE\|MERGE\|INSERT\|END\|BEGIN/!d}' "${GEN_FILE}" 2>/dev/null || true
LINES=$(wc -l < "${GEN_FILE}")
echo "    生成行数: ${LINES}"
if ! grep -q "CREATE OR REPLACE PACKAGE BODY log_schema.pkg_transform_gen" "${GEN_FILE}"; then
    echo "    ERROR: 生成物にパッケージ本体が見当たりません。中身を確認してください。"
    head -20 "${GEN_FILE}"
    exit 1
fi
echo "    先頭プレビュー:"
head -8 "${GEN_FILE}" | sed 's/^/      /'

# ---- デプロイ ----
if [ "${DEPLOY}" -eq 1 ]; then
    echo ""
    echo "[2] deploy -> oracle-tgt XEPDB1"
    docker cp "${GEN_FILE}" "${TGT}:/tmp/pkg_transform_gen.sql" >/dev/null
    docker exec -u oracle ${TGT} bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
@/tmp/pkg_transform_gen.sql
SHOW ERRORS PACKAGE BODY LOG_SCHEMA.PKG_TRANSFORM_GEN
EXIT;
EOF" 2>&1 | grep -iE "(Package|Package body|created|ORA-|PLS-|[0-9]+/[0-9]+|No errors|MERGE|rows merged)" | head -25
    echo ""
    echo "[3] 検証: pkg_transform_gen / transform_catalog 状態"
    docker exec -u oracle ${TGT} bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 120
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'pkg_transform_gen status='||status FROM dba_objects WHERE owner='LOG_SCHEMA' AND object_name='PKG_TRANSFORM_GEN' AND object_type='PACKAGE BODY';
SELECT 'catalog: '||tgt_table_name||' '||transform_class||' -> '||NVL(proc_name,'(passthrough)') FROM log_schema.transform_catalog ORDER BY sort_order;
EOF" 2>&1
else
    echo "    （--no-deploy のためデプロイはスキップ）"
fi
echo "=============================================="
echo " 完了"
echo "=============================================="
