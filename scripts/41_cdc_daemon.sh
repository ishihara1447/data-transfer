#!/usr/bin/env bash
# 継続CDCデーモン: scripts/40_cdc_cycle.sh を一定間隔で繰り返し実行
# 「LogMiner差分を継続供給しTARGETをほぼリアルタイム変換」を実現する常駐ループ。
#
# ★LOB再同期サイクル統合（docs/delta-extract-design.md 11.6）:
#   scripts/43_lob_resync_cycle.sh を ops_config の設定に基づいて周期起動する。
#   - lob_resync_interval_cycles (既定6): N サイクルに1回 43 を起動
#   - lob_resync_pending_threshold (既定500): PENDING件数がこれを超えたら即起動
#   40_cdc_cycle.sh 自体は変更しない。
#
# 使い方:
#   bash scripts/41_cdc_daemon.sh [間隔秒] [最大反復回数(0=無限)]
#   例: bash scripts/41_cdc_daemon.sh 10 0     # 10秒間隔で無限
#       bash scripts/41_cdc_daemon.sh 5 12     # 5秒間隔で12回（検証用）
#   間隔秒を省略すると ops_config.cdc_interval_sec を使用（運用者が61で変更可）。
#
# 停止: Ctrl-C もしくは max_iter 到達。

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="oracle-src"
TGT="oracle-tgt"

# ops_config から1キーの整数値を取得（既定値はフォールバック）
cfg_int() { # key fallback
  local v
  v=$(docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT param_value FROM cdc_schema.ops_config WHERE param_key='$1';
EOF" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
  echo "${v:-$2}"
}

# ops_config から CDC 間隔を取得（引数優先・なければ設定値・最後に10秒）
cfg_interval() {
  cfg_int cdc_interval_sec 10
}

INTERVAL="${1:-$(cfg_interval)}"
MAX_ITER="${2:-0}"

echo "=============================================="
echo " 継続CDCデーモン 起動 (間隔=${INTERVAL}s, 最大反復=${MAX_ITER:-∞})"
echo "=============================================="

trap 'echo ""; echo "デーモン停止"; exit 0' INT TERM

i=0
lob_cycle_count=0  # 最後に LOB再同期を起動してからのサイクル数

while true; do
    i=$((i+1))
    bash ${ROOT}/scripts/40_cdc_cycle.sh

    # ---- LOB再同期サイクル起動判定（11.6）----
    # ops_config から設定を読む（ops_config が無い環境用にフォールバック値を設定）
    LOB_INTERVAL=$(cfg_int lob_resync_interval_cycles 6)
    LOB_THRESHOLD=$(cfg_int lob_resync_pending_threshold 500)
    lob_cycle_count=$((lob_cycle_count + 1))

    # PENDING 件数チェック（tgt の lob_resync_target）
    LOB_PENDING=0
    LOB_PENDING=$(docker exec -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT COUNT(*) FROM staging_ctl.lob_resync_target WHERE resync_status='PENDING';
SQLEOF" 2>/dev/null | grep -oE '[0-9]+' | tail -1) || true
    LOB_PENDING="${LOB_PENDING:-0}"

    # 起動条件: 周期に達した OR PENDING件数が閾値超
    RUN_LOB=0
    if [ "${lob_cycle_count}" -ge "${LOB_INTERVAL}" ]; then
        RUN_LOB=1
        lob_cycle_count=0
    elif [ "${LOB_PENDING}" -ge "${LOB_THRESHOLD}" ]; then
        echo "  LOB PENDING=${LOB_PENDING} >= threshold=${LOB_THRESHOLD}: 即時起動"
        RUN_LOB=1
        lob_cycle_count=0
    fi

    if [ "${RUN_LOB}" -eq 1 ]; then
        echo "  [LOB再同期] サイクル起動 (cycle_count=${i}, pending=${LOB_PENDING})"
        bash ${ROOT}/scripts/43_lob_resync_cycle.sh || true
    fi
    # ---- LOB再同期判定ここまで ----

    if [ "${MAX_ITER}" -ne 0 ] && [ "${i}" -ge "${MAX_ITER}" ]; then
        echo "最大反復 ${MAX_ITER} 到達。停止。"
        break
    fi
    sleep "${INTERVAL}"
done
