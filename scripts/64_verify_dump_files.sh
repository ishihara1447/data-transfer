#!/usr/bin/env bash
# Phase 1: ダンプファイルの SHA-256 チェックサム検証
# 管理テーブル更新: DATAPUMP_FILE を VERIFIED へ遷移
#
# 使い方: bash scripts/64_verify_dump_files.sh
# 前提: 63_run_expdp.sh が完了し、DATAPUMP_FILE に CREATED レコードがあること

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/.env"

MCTL_USER="MIGRATION_CTL"
MCTL_PASS="${MIGRATION_CTL_PASS}"
MCTL_HOST="oracle-tgt"
MCTL_PORT="1521"
MCTL_SVC="XEPDB1"
SRC_HOST="oracle-src"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# oracle-tgt で MIGRATION_CTL として DML を実行
mctl_exec() {
    docker exec "${MCTL_HOST}" bash -c \
        "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${MCTL_PORT}/${MCTL_SVC} <<'SQLEOF'
SET FEEDBACK OFF SERVEROUTPUT ON SIZE UNLIMITED
$1
EXIT;
SQLEOF" 2>&1
}

# oracle-tgt で MIGRATION_CTL として純数値を返すクエリを実行
# SQLPlus の出力は先頭/末尾に空白が入るため tr で除去してから数値行を抽出する
mctl_query() {
    docker exec "${MCTL_HOST}" bash -c \
        "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${MCTL_PORT}/${MCTL_SVC} <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
$1
EXIT;
SQLEOF" 2>&1 | tr -d ' \t' | grep -E '^[0-9]+$' | tail -1
}

log "=== Phase 1 ダンプファイル検証開始 ==="

# /migfs 内の DUMP ファイルを全件処理（mapfile でパイプ stdin 問題を回避）
mapfile -t FLIST < <(docker exec "${SRC_HOST}" bash -c \
    "ls /migfs/exp_*.dmp 2>/dev/null" || true)

if [ "${#FLIST[@]}" -eq 0 ]; then
    log "[WARN] /migfs に exp_*.dmp が見つかりません。63_run_expdp.sh を先に実行してください。"
    exit 1
fi

VERIFIED_COUNT=0
WARN_COUNT=0

for FPATH in "${FLIST[@]}"; do
    [ -z "${FPATH}" ] && continue
    FNAME=$(basename "${FPATH}")
    FSIZE=$(docker exec "${SRC_HOST}" bash -c "stat -c %s ${FPATH}" 2>/dev/null || echo 0)
    SHA256=$(docker exec "${SRC_HOST}" bash -c "sha256sum ${FPATH} | cut -d' ' -f1" 2>/dev/null || echo "")

    if [ -z "${SHA256}" ]; then
        log "  [ERROR] ${FNAME}: SHA-256 計算失敗"
        WARN_COUNT=$((WARN_COUNT + 1))
        continue
    fi

    log "  ${FNAME}: size=${FSIZE} sha256=${SHA256}"

    # DATAPUMP_FILE テーブルから FILE_ID を検索（STATUS='CREATED' のもの）
    FILE_ID=$(mctl_query \
        "SELECT DATAPUMP_FILE_ID FROM DATAPUMP_FILE WHERE FILE_NAME='${FNAME}' AND STATUS='CREATED' AND ROWNUM=1;")

    if [ -z "${FILE_ID}" ] || [ "${FILE_ID}" = "0" ]; then
        log "  [WARN] DATAPUMP_FILE 未登録または既にVERIFIED: ${FNAME}"
        log "         (STATUS='CREATED' のレコードがありません。63_run_expdp.sh を先に実行してください)"
        WARN_COUNT=$((WARN_COUNT + 1))
        continue
    fi

    # PKG_MIG_ADMIN.VERIFY_DATAPUMP_FILE を呼び出して VERIFIED へ遷移
    mctl_exec "
BEGIN
    PKG_MIG_ADMIN.VERIFY_DATAPUMP_FILE(
        p_file_id         => ${FILE_ID},
        p_file_size_bytes => ${FSIZE},
        p_checksum_algo   => 'SHA256',
        p_checksum_value  => '${SHA256}'
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('VERIFIED: file_id=${FILE_ID} ${FNAME}');
END;
/" 2>&1 | grep -v '^$' || true

    log "  [OK] VERIFIED: ${FNAME} (FILE_ID=${FILE_ID})"
    VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
done

log ""
log "=== ダンプファイル検証完了 ==="
log "  VERIFIED: ${VERIFIED_COUNT} 件 / WARN: ${WARN_COUNT} 件"

if [ "${WARN_COUNT}" -gt 0 ]; then
    log "  [WARN] 未登録または検証スキップのファイルがあります。上記ログを確認してください。"
fi

log "次のステップ: bash scripts/65_run_impdp.sh"
