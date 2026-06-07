#!/usr/bin/env bash
# 移行ダッシュボード自動更新デーモン
# scripts/50 を一定間隔で再生成し続ける。HTML には meta refresh を埋め込むため、
# ブラウザで開きっぱなしにすると自動的に最新状態へ更新される。
#
# 使い方:
#   bash scripts/51_dashboard_daemon.sh [更新間隔秒] [最大反復(0=無限)] [出力HTML]
#   例: bash scripts/51_dashboard_daemon.sh 10 0       # 10秒ごとに無限更新
#       bash scripts/51_dashboard_daemon.sh 5 12       # 5秒ごと12回（検証用）
#
# 停止: Ctrl-C もしくは max_iter 到達

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTERVAL="${1:-10}"
MAX_ITER="${2:-0}"
OUT="${3:-${ROOT}/out/migration_dashboard.html}"

echo "ダッシュボード自動更新デーモン起動 (間隔=${INTERVAL}s, 最大=${MAX_ITER:-∞})"
echo "  出力: ${OUT}"
echo "  ブラウザで上記HTMLを開くと ${INTERVAL}s ごとに自動更新されます"
trap 'echo ""; echo "停止"; exit 0' INT TERM

i=0
while true; do
    i=$((i+1))
    bash "${ROOT}/scripts/50_migration_dashboard.sh" "${OUT}" "${INTERVAL}" >/dev/null 2>&1 \
        && echo "[$(date '+%H:%M:%S')] 更新 #${i}" \
        || echo "[$(date '+%H:%M:%S')] 更新失敗 #${i}"
    if [ "${MAX_ITER}" -ne 0 ] && [ "${i}" -ge "${MAX_ITER}" ]; then break; fi
    sleep "${INTERVAL}"
done
echo "完了（${i}回更新）"
