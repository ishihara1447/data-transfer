#!/usr/bin/env bash
# 継続CDCデーモン: scripts/40_cdc_cycle.sh を一定間隔で繰り返し実行
# 「LogMiner差分を継続供給しTARGETをほぼリアルタイム変換」を実現する常駐ループ。
#
# 使い方:
#   bash scripts/41_cdc_daemon.sh [間隔秒] [最大反復回数(0=無限)]
#   例: bash scripts/41_cdc_daemon.sh 10 0     # 10秒間隔で無限
#       bash scripts/41_cdc_daemon.sh 5 12     # 5秒間隔で12回（検証用）
#
# 停止: Ctrl-C もしくは max_iter 到達。

set -uo pipefail
ROOT="/home/ishihara1447/projects/data-transfer"
INTERVAL="${1:-10}"
MAX_ITER="${2:-0}"

echo "=============================================="
echo " 継続CDCデーモン 起動 (間隔=${INTERVAL}s, 最大反復=${MAX_ITER:-∞})"
echo "=============================================="

trap 'echo ""; echo "デーモン停止"; exit 0' INT TERM

i=0
while true; do
    i=$((i+1))
    bash ${ROOT}/scripts/40_cdc_cycle.sh
    if [ "${MAX_ITER}" -ne 0 ] && [ "${i}" -ge "${MAX_ITER}" ]; then
        echo "最大反復 ${MAX_ITER} 到達。停止。"
        break
    fi
    sleep "${INTERVAL}"
done
