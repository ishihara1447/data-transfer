#!/usr/bin/env bash
# 継続CDC 1サイクル: delta_extract → (未搬送あれば)DataPump搬送+delta_apply → transform DELTA
# 設計: 最終ゴール（初期ダンプ後、LogMiner差分の継続供給でニアリアルタイム変換）
#
# 特徴:
#   - delta_extract はオンラインREDOを採掘するため強制ログスイッチ不要（検証済）
#   - 未搬送差分(src delta_id > tgt 取込済 delta_id)が無ければ搬送をスキップ
#   - 各サイクルは冪等。デーモン(41)から短間隔で繰り返し呼ばれる想定
#   - 1行サマリを標準出力（タイムスタンプ・各段の件数）
#
# 戻り値: 常に0（デーモンが落ちないよう個別失敗はサマリに記録）

set -uo pipefail
ROOT="/home/ishihara1447/projects/data-transfer"
SRC="oracle-src"; TGT="oracle-tgt"; RUN="delta_run_01"
TS=$(date '+%H:%M:%S')

num() { grep -oE '[0-9]+' | tail -1; }

# ---- 1. delta_extract（src・オンラインREDO採掘）----
EX=$(docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF ECHO OFF
BEGIN SYS.delta_extract('${RUN}'); END;
/
EOF" 2>&1 | grep -oE 'extracted=[0-9]+' | cut -d= -f2)
EX=${EX:-0}

# ---- 2. 未搬送判定（src delta_queue MAX vs tgt staging_ctl.delta_queue MAX）----
SRCMAX=$(docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT NVL(MAX(delta_id),0) FROM cdc_schema.delta_queue;
EOF" 2>/dev/null | num)
TGTMAX=$(docker exec -u oracle ${TGT} bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT NVL(MAX(delta_id),0) FROM staging_ctl.delta_queue;
EOF" 2>/dev/null | num)
SRCMAX=${SRCMAX:-0}; TGTMAX=${TGTMAX:-0}

APPLIED="-"
if [ "${SRCMAX}" -gt "${TGTMAX}" ]; then
    # ---- 搬送 + delta_apply（scripts/06）----
    bash ${ROOT}/scripts/06_transfer_delta_datapump.sh > /tmp/cdc_cycle_xfer.log 2>&1 || true
    APPLIED=$(grep -oE 'applied_tx=[0-9]+ rows=[0-9]+' /tmp/cdc_cycle_xfer.log | tail -1 | grep -oE 'rows=[0-9]+' | cut -d= -f2)
    APPLIED=${APPLIED:-0}
fi

# ---- 3. transform DELTA（tgt）----
TR=$(docker exec -u oracle ${TGT} bash -c "sqlplus -S '/ as sysdba' <<'EOF'
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF ECHO OFF
BEGIN log_schema.pkg_transform.transform_all('CDC_DELTA_${RANDOM}','DELTA',10000,'Y'); END;
/
EOF" 2>&1 | grep -oE 'status=SUCCESS|FAILED|ORA-[0-9]+' | head -1)
TR=${TR:-NONE}

echo "[${TS}] extracted=${EX} pending=$((SRCMAX-TGTMAX)) applied_rows=${APPLIED} transform=${TR}"
