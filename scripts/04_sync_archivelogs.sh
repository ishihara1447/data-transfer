#!/usr/bin/env bash
# archive log を oracle-src から oracle-tgt に同期する
# 本番では rsync / SCP / 共有ストレージ経由で定期搬送するところを docker cp で模擬
#
# 使い方（手動）:
#   bash scripts/04_sync_archivelogs.sh
#
# 使い方（定期実行）:
#   watch -n 60 bash scripts/04_sync_archivelogs.sh
#
# 前提:
#   - スナップショット SCN は /tmp/export_scn.txt に記録済み
#   - /tmp/last_synced_seq.txt に前回同期した最終シーケンス番号を保持

set -euo pipefail

SRC_CONTAINER="oracle-src"
TGT_CONTAINER="oracle-tgt"
REDO_RECV_DIR="/opt/oracle/redo_from_src"
LAST_SEQ_FILE="/tmp/last_synced_seq.txt"
SNAPSHOT_SCN_FILE="/tmp/export_scn.txt"

# 前回同期済みの最終シーケンス番号（初回は 0）
LAST_SEQ=0
if [[ -f "${LAST_SEQ_FILE}" ]]; then
    LAST_SEQ=$(cat "${LAST_SEQ_FILE}")
fi

# スナップショット SCN（archive log フィルタ用）
SNAPSHOT_SCN=0
if [[ -f "${SNAPSHOT_SCN_FILE}" ]]; then
    SNAPSHOT_SCN=$(cat "${SNAPSHOT_SCN_FILE}")
fi

echo "=== archive log 同期開始 (last_seq=${LAST_SEQ}, snapshot_scn=${SNAPSHOT_SCN}) ==="

# oracle-src で LAST_SEQ より新しい archive log のファイル一覧を取得
ARCH_LIST=$(docker exec -u oracle "${SRC_CONTAINER}" bash -c \
  "sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF LINESIZE 500
SELECT name || '|' || sequence# || '|' || first_change# || '|' || next_change#
FROM   v\$archived_log
WHERE  sequence# > ${LAST_SEQ}
  AND  next_change# > ${SNAPSHOT_SCN}
  AND  deleted    = 'NO'
  AND  standby_dest = 'NO'
ORDER  BY sequence#;
EXIT;
EOF" | grep -E '\|' || true)

if [[ -z "${ARCH_LIST}" ]]; then
    echo "新しい archive log なし（最終シーケンス: ${LAST_SEQ}）"
    exit 0
fi

# oracle-tgt に受信ディレクトリを確保
docker exec "${TGT_CONTAINER}" mkdir -p "${REDO_RECV_DIR}"

NEW_MAX_SEQ=${LAST_SEQ}
LOCAL_TMP="/tmp/arch_sync_$$"
mkdir -p "${LOCAL_TMP}"

while IFS='|' read -r ARCH_PATH SEQ FIRST_SCN NEXT_SCN; do
    ARCH_PATH=$(echo "${ARCH_PATH}" | tr -d ' ')
    SEQ=$(echo "${SEQ}" | tr -d ' ')
    FNAME=$(basename "${ARCH_PATH}")

    echo "  seq=${SEQ} scn=[${FIRST_SCN},${NEXT_SCN}] -> ${FNAME}"
    docker cp "${SRC_CONTAINER}:${ARCH_PATH}" "${LOCAL_TMP}/${FNAME}"
    docker cp "${LOCAL_TMP}/${FNAME}" "${TGT_CONTAINER}:${REDO_RECV_DIR}/${FNAME}"

    if [[ ${SEQ} -gt ${NEW_MAX_SEQ} ]]; then
        NEW_MAX_SEQ=${SEQ}
    fi
done <<< "${ARCH_LIST}"

rm -rf "${LOCAL_TMP}"

# 最終シーケンス番号を更新
echo "${NEW_MAX_SEQ}" > "${LAST_SEQ_FILE}"

echo "=== 完了: ${NEW_MAX_SEQ} まで同期済み ==="
echo "次のステップ: bash scripts/05_apply_delta_on_tgt.sh"
