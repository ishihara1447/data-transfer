#!/usr/bin/env bash
# DataPump export (oracle-src コンテナ内で実行)
# 用途: 現時点の SCN を基準に SRC_SCHEMA 全体をエクスポートし
#       ダンプファイルを生成する（本番ではこれを物理媒体で搬送）
#
# 使い方:
#   bash scripts/01_datapump_export.sh
#
# 出力:
#   oracle-src コンテナの DATA_PUMP_DIR に src_export_NN.dmp が生成される
#   取得 SCN は /tmp/export_scn.txt にも記録される

set -euo pipefail

CONTAINER="oracle-src"
DUMPFILE_PREFIX="src_export"
PARALLEL=2           # XE の CPU 制限に合わせて 2 に設定（本番は 8 以上）
DATA_PUMP_DIR_PATH="/opt/oracle/admin/XE/dpdump"

echo "=== Step 1: 現在の SCN を取得 ==="
SNAPSHOT_SCN=$(docker exec -u oracle "${CONTAINER}" bash -c \
  "sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT CURRENT_SCN FROM V\$DATABASE;
EXIT;
EOF" | grep -E '^[0-9]+$' | tail -1)

echo "Snapshot SCN: ${SNAPSHOT_SCN}"
echo "${SNAPSHOT_SCN}" > /tmp/export_scn.txt

echo "=== Step 2: LogMiner 用 flat-file 辞書を生成 ==="
docker exec -u oracle "${CONTAINER}" bash -c \
  "sqlplus -S '/ as sysdba' <<'EOF'
SET SERVEROUTPUT ON
ALTER SESSION SET CONTAINER = XEPDB1;
BEGIN
    DBMS_LOGMNR_D.BUILD(
        dictionary_filename => 'dict.ora',
        dictionary_location => 'DATA_PUMP_DIR',
        OPTIONS             => DBMS_LOGMNR_D.STORE_IN_FLAT_FILE
    );
    DBMS_OUTPUT.PUT_LINE('dict.ora generated.');
END;
/
EXIT;
EOF"

echo "=== Step 3: DataPump export (FLASHBACK_SCN=${SNAPSHOT_SCN}) ==="
docker exec -u oracle "${CONTAINER}" bash -c \
  "expdp '/ as sysdba' \
     schemas=SRC_SCHEMA \
     flashback_scn=${SNAPSHOT_SCN} \
     parallel=${PARALLEL} \
     compression=ALL \
     dumpfile=${DUMPFILE_PREFIX}_%U.dmp \
     logfile=${DUMPFILE_PREFIX}_export.log \
     directory=DATA_PUMP_DIR"

echo "=== 完了 ==="
echo "SCN     : ${SNAPSHOT_SCN}"
echo "Dumpfile: ${CONTAINER}:${DATA_PUMP_DIR_PATH}/${DUMPFILE_PREFIX}_*.dmp"
echo "Dict    : ${CONTAINER}:${DATA_PUMP_DIR_PATH}/dict.ora"
echo ""
echo "次のステップ: bash scripts/02_transfer_dumps.sh"
