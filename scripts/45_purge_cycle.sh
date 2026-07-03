#!/usr/bin/env bash
# delta_queue パージサイクル
# 継続CDC運用での src/tgt delta_queue 無限増加を防ぐ。
#
# 処理フロー:
#   Step1: tgt から MAX(delta_id) と last_applied_commit_scn を照会
#   Step2: ops_config から delta_purge_enabled と delta_purge_retention_min を取得
#   Step3: tgt で SYS.delta_purge_tgt を実行（実削除 or dry_run）
#   Step4: src で SYS.delta_purge_src を実行（Step1 の2値を引数として渡す）
#
# 役割分離:
#   - DB 照会・値の受け渡し・プロシージャ起動: このシェルスクリプト
#   - パージ判定・削除・件数カウント・COMMIT/ROLLBACK: PL/SQL（45_/46_）
#   - tgt 側の2値を src PL/SQL に渡す（src PL/SQL は tgt に直接接続しない）
#
# 安全設計:
#   - ops_config.delta_purge_enabled='N'（デフォルト）の場合は dry_run のみ
#   - 'Y' に変更したときのみ実削除（bash scripts/61_ops_config.sh set delta_purge_enabled Y）
#   - tgt 値の取得に失敗した場合は安全のためスキップ
#
# 使い方:
#   bash scripts/45_purge_cycle.sh
#   bash scripts/45_purge_cycle.sh dry_run   # 強制 dry_run（ops_config 無視）

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="oracle-src"
TGT="oracle-tgt"
FORCE_DRY_RUN="${1:-}"  # 引数で "dry_run" を渡すと ops_config 設定に関わらず dry_run

TS=$(date '+%Y-%m-%d %H:%M:%S')
echo "=============================================="
echo " delta_queue パージサイクル 開始 (${TS})"
echo "=============================================="

# ---- ヘルパー関数: sqlplus 数値出力の取り出し ----
num() { grep -oE '[0-9]+' | tail -1; }

# ----------------------------------------------------------------
# Step1: tgt の MAX(delta_id) と last_applied_commit_scn を照会
#   これがパージの安全境界値となる。
#   tgt で照会できない場合はパージをスキップ（安全側に倒す）。
# ----------------------------------------------------------------
echo "[Step1] oracle-tgt: MAX(delta_id) と last_applied_commit_scn を照会"

TGT_MAX_DELTA_ID=$(docker exec -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT NVL(MAX(delta_id), 0) FROM staging_ctl.delta_queue;
SQLEOF" 2>/dev/null | num)
TGT_MAX_DELTA_ID="${TGT_MAX_DELTA_ID:-0}"

TGT_LAST_APPLIED_SCN=$(docker exec -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT NVL(last_applied_commit_scn, 0) FROM staging_ctl.delta_apply_state WHERE run_name='delta_run_01';
SQLEOF" 2>/dev/null | num)
TGT_LAST_APPLIED_SCN="${TGT_LAST_APPLIED_SCN:-0}"

echo "  tgt MAX(delta_id)=${TGT_MAX_DELTA_ID} last_applied_commit_scn=${TGT_LAST_APPLIED_SCN}"

if [ "${TGT_MAX_DELTA_ID}" -le 0 ] || [ "${TGT_LAST_APPLIED_SCN}" -le 0 ]; then
    echo "  WARN: tgt 値の取得に失敗またはデータなし。パージをスキップします。"
    echo "=============================================="
    echo " delta_queue パージサイクル スキップ"
    echo "=============================================="
    exit 0
fi

# ----------------------------------------------------------------
# Step2: ops_config から delta_purge_enabled と delta_purge_retention_min を取得
#   設定が存在しない場合はデフォルト値（enabled=N, retention=60分）を使用
# ----------------------------------------------------------------
echo "[Step2] oracle-src: ops_config からパージ設定を取得"

PURGE_ENABLED=$(docker exec -u oracle "${SRC}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT NVL(MAX(param_value), 'N') FROM cdc_schema.ops_config WHERE param_key='delta_purge_enabled';
SQLEOF" 2>/dev/null | grep -oE '[YN]' | tail -1)
PURGE_ENABLED="${PURGE_ENABLED:-N}"

RETENTION_MIN=$(docker exec -u oracle "${SRC}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT NVL(MAX(param_value), '60') FROM cdc_schema.ops_config WHERE param_key='delta_purge_retention_min';
SQLEOF" 2>/dev/null | num)
RETENTION_MIN="${RETENTION_MIN:-60}"

echo "  delta_purge_enabled=${PURGE_ENABLED} delta_purge_retention_min=${RETENTION_MIN}"

# dry_run 判定: ops_config が 'Y' かつ引数強制なしのときのみ実削除
if [ "${FORCE_DRY_RUN}" = "dry_run" ]; then
    DRY_RUN="Y"
    echo "  引数指定により強制 DRY_RUN"
elif [ "${PURGE_ENABLED}" = "Y" ]; then
    DRY_RUN="N"
    echo "  ops_config.delta_purge_enabled=Y: 実削除モード"
else
    DRY_RUN="Y"
    echo "  ops_config.delta_purge_enabled=N: DRY_RUN モード（削除しません）"
fi

# ----------------------------------------------------------------
# Step3: tgt で SYS.delta_purge_tgt を実行
# ----------------------------------------------------------------
echo "[Step3] oracle-tgt: SYS.delta_purge_tgt 実行 (dry_run=${DRY_RUN})"

docker exec -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED
BEGIN
    SYS.delta_purge_tgt(
        p_run_name      => 'delta_run_01',
        p_retention_min => ${RETENTION_MIN},
        p_dry_run       => '${DRY_RUN}'
    );
END;
/
SQLEOF" 2>&1 | grep -v "^$"

# ----------------------------------------------------------------
# Step4: src で SYS.delta_purge_src を実行
#   tgt の2値を引数として渡す（src PL/SQL は tgt に直接接続しない = 役割分離）
# ----------------------------------------------------------------
echo "[Step4] oracle-src: SYS.delta_purge_src 実行 (dry_run=${DRY_RUN})"

docker exec -u oracle "${SRC}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED
BEGIN
    SYS.delta_purge_src(
        p_tgt_max_delta_id      => ${TGT_MAX_DELTA_ID},
        p_tgt_last_applied_scn  => ${TGT_LAST_APPLIED_SCN},
        p_retention_min         => ${RETENTION_MIN},
        p_dry_run               => '${DRY_RUN}'
    );
END;
/
SQLEOF" 2>&1 | grep -v "^$"

echo "=============================================="
echo " delta_queue パージサイクル 完了 (dry_run=${DRY_RUN})"
echo "=============================================="
