#!/usr/bin/env bash
# オフライン搬送を模擬: oracle-src のダンプ・辞書ファイルを oracle-tgt に転送する
# 本番では SSD/NAS/共有ストレージで物理搬送するところを docker cp で代替
#
# 使い方:
#   bash scripts/02_transfer_dumps.sh

set -euo pipefail

SRC_CONTAINER="oracle-src"
TGT_CONTAINER="oracle-tgt"
DATA_PUMP_DIR_PATH="/opt/oracle/admin/XE/dpdump"
REDO_RECV_DIR="/opt/oracle/redo_from_src"
LOCAL_TMP="/tmp/datapump_transfer"

mkdir -p "${LOCAL_TMP}"

echo "=== ダンプファイルを oracle-src から取得 ==="
docker exec "${SRC_CONTAINER}" ls "${DATA_PUMP_DIR_PATH}"/src_export_*.dmp 2>/dev/null | while read -r f; do
    fname=$(basename "$f")
    echo "  コピー中: ${fname}"
    docker cp "${SRC_CONTAINER}:${f}" "${LOCAL_TMP}/${fname}"
done

echo "=== LogMiner 辞書ファイルを取得 ==="
docker cp "${SRC_CONTAINER}:${DATA_PUMP_DIR_PATH}/dict.ora" "${LOCAL_TMP}/dict.ora"

echo "=== oracle-tgt にダンプファイルを配置 ==="
docker exec "${TGT_CONTAINER}" mkdir -p "${DATA_PUMP_DIR_PATH}"
docker exec "${TGT_CONTAINER}" mkdir -p "${REDO_RECV_DIR}"

for f in "${LOCAL_TMP}"/src_export_*.dmp; do
    fname=$(basename "$f")
    echo "  転送中: ${fname}"
    docker cp "${f}" "${TGT_CONTAINER}:${DATA_PUMP_DIR_PATH}/${fname}"
done

echo "=== dict.ora を oracle-tgt に配置 ==="
docker cp "${LOCAL_TMP}/dict.ora" "${TGT_CONTAINER}:${REDO_RECV_DIR}/dict.ora"

echo "=== 完了 ==="
echo "次のステップ: bash scripts/03_datapump_import.sh"
