#!/usr/bin/env bash
# 差分 Data Pump 搬送: oracle-src の delta_queue を
# ダンプファイル化 → 物理搬送（docker cp）→ oracle-tgt にロード
#
# 本番のオフライン制約を模擬: テーブル間の直接コピーはせず
# 必ず Data Pump ダンプ「ファイル」を経由する。
#
# --- 搬送進捗の管理方式について ---
# 二回目以降の実行で impdp が PK(delta_id) 重複エラーになる問題を防ぐため、
# 「まだ搬送していない delta_id のみ」を expdp の QUERY 句で絞り込む。
#
# 進捗管理方式の選択: (b) tgt 側の実データを正とする方式を採用する
#   (a) 搬送進捗テーブル/列を src 側に持つ方式は、src/tgt の状態が二重管理に
#       なり、搬送途中でスクリプトが中断した場合に不整合が生じるリスクがある。
#   (b) 搬送前に oracle-tgt の staging_ctl.delta_queue の MAX(delta_id) を
#       sqlplus で問い合わせ、その値を超える delta_id だけ src から export する。
#       tgt 側の実データ自体が「到達済み delta_id」の唯一の真実となるため、
#       二重管理が不要で冪等性が自然に保証される。
#       初回（tgt が空）は MAX=NULL となるが、その場合は 0 として扱い
#       全件エクスポートする（WHERE delta_id > 0 は全件に相当する）。
#       ただし、delta_id が 1 始まりである前提（seq_delta_queue START WITH 1）。
#
# 使い方:
#   bash scripts/06_transfer_delta_datapump.sh

set -euo pipefail

SRC="oracle-src"
TGT="oracle-tgt"
DMP_DIR="/opt/oracle/admin/XE/dpdump"   # 両コンテナの DATA_PUMP_DIR 実体
DMP_FILE="delta_$(date +%Y%m%d_%H%M%S).dmp"
LOG_PREFIX="delta_xfer"
HOST_TMP="/tmp/delta_transfer"

mkdir -p "${HOST_TMP}"

echo "=============================================="
echo " 差分 Data Pump 搬送"
echo "=============================================="

# ----------------------------------------------------------------
# Step 0: oracle-tgt の staging_ctl.delta_queue から
#         搬送済み最大 delta_id を取得する（進捗基準値）
#   tgt 側で staging_ctl ユーザーとして接続し MAX(delta_id) を問い合わせる。
#   テーブルが空またはまだ存在しない場合は 0 を返す（= 全件対象）。
# ----------------------------------------------------------------
echo "[0/4] oracle-tgt: 搬送済み最大 delta_id を確認"

TGT_PASS="stagingctl1"

LAST_DELTA_ID=$(docker exec -u oracle "${TGT}" bash -c \
  "sqlplus -S staging_ctl/${TGT_PASS}@//localhost:1521/XEPDB1 <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT NVL(MAX(delta_id), 0) FROM staging_ctl.delta_queue;
EXIT;
SQLEOF" 2>/dev/null | grep -oE '[0-9]+' | tail -1)

# sqlplus が接続失敗した場合や出力が空の場合は 0 で継続する
if [[ -z "${LAST_DELTA_ID}" ]]; then
    echo "  警告: tgt の delta_id 取得に失敗。初回実行と見なし 0 を使用します。"
    LAST_DELTA_ID=0
fi

echo "  搬送済み最大 delta_id: ${LAST_DELTA_ID}"

# ----------------------------------------------------------------
# Step 1: oracle-src で delta_queue をダンプファイル化
#   PDB(XEPDB1) 接続が必要なため parfile を使用
#   userid のパスワード特殊文字を避けるため OS認証 + 動的サービス
#   QUERY 句で delta_id > LAST_DELTA_ID の行のみを export する。
# ----------------------------------------------------------------
echo "[1/4] oracle-src: expdp で delta_queue をエクスポート (delta_id > ${LAST_DELTA_ID})"

# cdc_schema で接続（特殊文字なしパスワード = 認証エラー回避）
# DATAPUMP_EXP_FULL_DATABASE 権限を付与済み
SRC_PASS=$(grep '^CDC_SCHEMA_PASS=' /home/ishihara1447/projects/data-transfer/.env | cut -d= -f2)

cat > "${HOST_TMP}/expdp_delta.par" << EOF
userid=cdc_schema/${SRC_PASS}@//localhost:1521/XEPDB1
tables=CDC_SCHEMA.DELTA_QUEUE
query=CDC_SCHEMA.DELTA_QUEUE:"WHERE delta_id > ${LAST_DELTA_ID}"
dumpfile=${DMP_FILE}
logfile=${LOG_PREFIX}_export.log
directory=DATA_PUMP_DIR
reuse_dumpfiles=YES
EOF

docker cp "${HOST_TMP}/expdp_delta.par" "${SRC}:/tmp/expdp_delta.par"
docker exec -u oracle "${SRC}" bash -c "expdp parfile=/tmp/expdp_delta.par" 2>&1 \
    | grep -E "(Export:|Master|Completed|ORA-|exported|rows)" | head -15

# ----------------------------------------------------------------
# Step 2: ダンプファイルを物理搬送（src → ホスト → tgt）
#   PDB の DATA_PUMP_DIR は GUID サブディレクトリ配下にあるため
#   実ファイルパスを find で動的に解決する
# ----------------------------------------------------------------
echo "[2/4] ダンプファイルを oracle-src → oracle-tgt に搬送"
SRC_DMP_PATH=$(docker exec "${SRC}" bash -c "find /opt/oracle/admin/XE/dpdump -name '${DMP_FILE}' 2>/dev/null | head -1")
if [[ -z "${SRC_DMP_PATH}" ]]; then
    echo "ERROR: ダンプファイルが見つかりません: ${DMP_FILE}"
    exit 1
fi
echo "  src 実パス: ${SRC_DMP_PATH}"
docker cp "${SRC}:${SRC_DMP_PATH}" "${HOST_TMP}/${DMP_FILE}"
# ホスト側で全読み取り権限を付与してから tgt に配置（oracle ユーザーが読めるように）
chmod 644 "${HOST_TMP}/${DMP_FILE}"

# tgt 側の DATA_PUMP_DIR 実体ディレクトリを解決（GUID配下）
TGT_DMP_DIR=$(docker exec "${TGT}" bash -c "ls -d /opt/oracle/admin/XE/dpdump/*/ 2>/dev/null | head -1")
TGT_DMP_DIR="${TGT_DMP_DIR:-/opt/oracle/admin/XE/dpdump/}"
echo "  tgt 配置先: ${TGT_DMP_DIR}${DMP_FILE}"
docker cp "${HOST_TMP}/${DMP_FILE}" "${TGT}:${TGT_DMP_DIR}${DMP_FILE}"
# docker cp は root/UID1000 所有でコピーするため oracle ユーザーが読めるよう権限付与
docker exec "${TGT}" bash -c "chmod 644 '${TGT_DMP_DIR}${DMP_FILE}'" 2>/dev/null || true
echo "  搬送完了: ${DMP_FILE}"

# ----------------------------------------------------------------
# Step 3: oracle-tgt で staging_ctl.delta_queue にロード
#   remap_schema=CDC_SCHEMA:STAGING_CTL
#   table_exists_action=APPEND（既存テーブルに追記）
#   content=DATA_ONLY（テーブル定義は既存のものを使う）
#   QUERY で delta_id > LAST_DELTA_ID を絞り込んでいるため、
#   PK(delta_id) 重複は発生しない前提。
#   旧スクリプトにあった data_options=SKIP_CONSTRAINT_ERRORS は削除する。
#   SKIP_CONSTRAINT_ERRORS は重複エラーを握りつぶすため、
#   QUERY による事前フィルタが正しく機能しているかの検知ができなくなる。
#   エラーは明示的に検知して問題を可視化する方が運用上安全。
# ----------------------------------------------------------------
echo "[3/4] oracle-tgt: impdp で staging_ctl.delta_queue にロード (APPEND)"

# staging_ctl で接続（DATAPUMP_IMP_FULL_DATABASE 権限付与済み）
# TGT_PASS は Step 0 で既に設定済み

cat > "${HOST_TMP}/impdp_delta.par" << EOF
userid=staging_ctl/${TGT_PASS}@//localhost:1521/XEPDB1
tables=CDC_SCHEMA.DELTA_QUEUE
remap_schema=CDC_SCHEMA:STAGING_CTL
dumpfile=${DMP_FILE}
logfile=${LOG_PREFIX}_import.log
directory=DATA_PUMP_DIR
content=DATA_ONLY
table_exists_action=APPEND
EOF

docker cp "${HOST_TMP}/impdp_delta.par" "${TGT}:/tmp/impdp_delta.par"
docker exec -u oracle "${TGT}" bash -c "impdp parfile=/tmp/impdp_delta.par" 2>&1 \
    | grep -E "(Import:|Master|Completed|ORA-|imported|rows)" | head -15

# ----------------------------------------------------------------
# Step 4: oracle-tgt で差分を STAGING_SCHEMA に適用
# ----------------------------------------------------------------
echo "[4/4] oracle-tgt: SYS.delta_apply で STAGING_SCHEMA に適用"
docker exec -u oracle "${TGT}" bash -c \
  "sqlplus -S '/ as sysdba' <<'SQLEOF'
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED
BEGIN SYS.delta_apply('delta_run_01'); END;
/
SQLEOF" 2>&1

echo "=============================================="
echo " 完了"
echo "=============================================="
