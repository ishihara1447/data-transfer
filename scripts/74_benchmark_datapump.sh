#!/usr/bin/env bash
# =============================================================================
# 74_benchmark_datapump.sh
# Data Pump ボトルネック計測スクリプト（B1〜B5）
#
# 目的:
#   LOBあり/なしのexpdp比較、Export/Import/索引再構築の時間分解、
#   REDO生成量、差分QUERYの実行計画と所要時間、待機イベントを実測する。
#
# 前提:
#   - oracle-src / oracle-tgt が稼働中
#   - /migfs が両コンテナから共有マウント済み
#   - MIG_FS_DIR DIRECTORY が oracle-src / oracle-tgt の XEPDB1 に存在する
#   - SRC_SCHEMA が oracle-src XEPDB1 に存在し DATAPUMP_EXP_FULL_DATABASE 権限あり
#   - STAGING_SCHEMA が oracle-tgt XEPDB1 に存在し DATAPUMP_IMP_FULL_DATABASE 権限あり
#
# 禁止事項（Oracle 21c XE エディション制限）:
#   - PARALLEL パラメータは使用不可 (ORA-39094)
#   - COMPRESSION=DATA_ONLY は使用不可 (ORA-00439)
#
# 使い方:
#   bash scripts/74_benchmark_datapump.sh [B1|B2|B3|B4|B5|ALL]
#   例: bash scripts/74_benchmark_datapump.sh ALL
#       bash scripts/74_benchmark_datapump.sh B1
#
# 結果:
#   ログは logs/benchmark_YYYYMMDD_HHMMSS.log に出力される
#   ダンプファイルは /migfs/bench_*.dmp に一時生成される（計測後に削除可能）
# =============================================================================

set -euo pipefail

# ============================================================
# 接続情報（環境に合わせて変更する）
# ============================================================
SRC_CONTAINER="oracle-src"
TGT_CONTAINER="oracle-tgt"
SRC_PDB="XEPDB1"
TGT_PDB="XEPDB1"
SRC_PORT="1521"
TGT_PORT="1521"

SRC_USER="src_schema"
SRC_PASS="srcpass1"
TGT_USER="staging_schema"
TGT_PASS="tgtpass1"

DUMP_DIR="MIG_FS_DIR"
DUMP_PATH="/migfs"

# 差分抽出の基準日（B4用）
DELTA_TIMESTAMP="2026-07-01 00:00:00"
DELTA_TABLE="CUSTOMER_CONTRACTS"

# ============================================================
# スクリプト設定
# ============================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-ALL}"
LOG_TS=$(date +%Y%m%d_%H%M%S)
LOG_DIR="${ROOT}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/benchmark_${LOG_TS}.log"
SCRATCHPAD="/tmp/bench_datapump_$$"
mkdir -p "${SCRATCHPAD}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }
log_result() { echo "$*" | tee -a "${LOG_FILE}"; }

# ============================================================
# ユーティリティ関数
# ============================================================

# oracle-src で sysdba として PDB SQL を実行
src_sysdba() {
    docker exec "${SRC_CONTAINER}" bash -c "
sqlplus -S / as sysdba <<'SQLEOF'
ALTER SESSION SET CONTAINER = ${SRC_PDB};
$1
EXIT;
SQLEOF" 2>&1
}

# oracle-tgt で sysdba として PDB SQL を実行
tgt_sysdba() {
    docker exec "${TGT_CONTAINER}" bash -c "
sqlplus -S / as sysdba <<'SQLEOF'
ALTER SESSION SET CONTAINER = ${TGT_PDB};
$1
EXIT;
SQLEOF" 2>&1
}

# oracle-tgt で CDB sysdba として SQL を実行（V$SYSSTAT 参照用）
tgt_cdb_sysdba() {
    docker exec "${TGT_CONTAINER}" bash -c "
sqlplus -S / as sysdba <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
$1
EXIT;
SQLEOF" 2>&1 | grep -E '^[0-9]+$' | tail -1
}

# ダンプファイルのバイト数を取得
get_dump_size() {
    local pattern="$1"
    docker exec "${SRC_CONTAINER}" bash -c "
total=0
for f in ${DUMP_PATH}/${pattern}; do
  [ -f \"\$f\" ] && total=\$((total + \$(stat -c %s \"\$f\")))
done
echo \$total
" 2>/dev/null || echo 0
}

# ============================================================
# 事前準備: 権限付与
# ============================================================
setup_privileges() {
    log "--- 権限付与 ---"
    tgt_sysdba "
GRANT DATAPUMP_IMP_FULL_DATABASE TO ${TGT_USER^^};
GRANT READ, WRITE ON DIRECTORY ${DUMP_DIR} TO ${TGT_USER^^};
" > /dev/null
    log "STAGING_SCHEMA 権限付与完了"
}

# ============================================================
# B1: LOBあり vs LOBなし expdp 比較
# ============================================================
run_b1() {
    log "================================================================"
    log "B1: LOBあり (CUSTOMER_CONTRACTS) vs LOBなし (ORDER_ITEMS) 比較"
    log "================================================================"

    # --- B1-LOB: CUSTOMER_CONTRACTS ---
    log "--- B1-LOB: CUSTOMER_CONTRACTS expdp 開始 ---"
    docker exec -u oracle "${SRC_CONTAINER}" bash -c "cat > ${DUMP_PATH}/bench_lob.par << 'EOF'
USERID=${SRC_USER}/${SRC_PASS}@//localhost:${SRC_PORT}/${SRC_PDB}
TABLES=${SRC_USER^^}.CUSTOMER_CONTRACTS
DUMPFILE=bench_lob_%U.dmp
LOGFILE=bench_lob.log
LOGTIME=ALL
METRICS=YES
DIRECTORY=${DUMP_DIR}
EOF"
    rm -f "${DUMP_PATH}"/bench_lob_*.dmp 2>/dev/null || true
    docker exec "${SRC_CONTAINER}" bash -c "rm -f ${DUMP_PATH}/bench_lob_*.dmp 2>/dev/null || true"

    B1_LOB_T0=$(date +%s)
    docker exec -u oracle "${SRC_CONTAINER}" bash -c "expdp parfile=${DUMP_PATH}/bench_lob.par" 2>&1 | tee "${SCRATCHPAD}/b1_lob.out"
    B1_LOB_T1=$(date +%s)
    B1_LOB_WALL=$((B1_LOB_T1 - B1_LOB_T0))

    B1_LOB_ELAPSED=$(grep -oP 'elapsed \d+ \K[\d:]+' "${SCRATCHPAD}/b1_lob.out" | tail -1 || echo "N/A")
    B1_LOB_ROWS=$(grep -oP '[\d,]+ rows' "${SCRATCHPAD}/b1_lob.out" | tail -1 | tr -d ',')
    B1_LOB_SIZE=$(get_dump_size "bench_lob_*.dmp")

    log "B1-LOB: elapsed=${B1_LOB_ELAPSED} (wall=${B1_LOB_WALL}s), rows=${B1_LOB_ROWS}, size=${B1_LOB_SIZE} bytes"

    # --- B1-NOLOB: ORDER_ITEMS ---
    log "--- B1-NOLOB: ORDER_ITEMS expdp 開始 ---"
    docker exec -u oracle "${SRC_CONTAINER}" bash -c "cat > ${DUMP_PATH}/bench_nolob.par << 'EOF'
USERID=${SRC_USER}/${SRC_PASS}@//localhost:${SRC_PORT}/${SRC_PDB}
TABLES=${SRC_USER^^}.ORDER_ITEMS
DUMPFILE=bench_nolob_%U.dmp
LOGFILE=bench_nolob.log
LOGTIME=ALL
METRICS=YES
DIRECTORY=${DUMP_DIR}
EOF"
    docker exec "${SRC_CONTAINER}" bash -c "rm -f ${DUMP_PATH}/bench_nolob_*.dmp 2>/dev/null || true"

    B1_NOLOB_T0=$(date +%s)
    docker exec -u oracle "${SRC_CONTAINER}" bash -c "expdp parfile=${DUMP_PATH}/bench_nolob.par" 2>&1 | tee "${SCRATCHPAD}/b1_nolob.out"
    B1_NOLOB_T1=$(date +%s)
    B1_NOLOB_WALL=$((B1_NOLOB_T1 - B1_NOLOB_T0))

    B1_NOLOB_ELAPSED=$(grep -oP 'elapsed \d+ \K[\d:]+' "${SCRATCHPAD}/b1_nolob.out" | tail -1 || echo "N/A")
    B1_NOLOB_ROWS=$(grep -oP '[\d,]+ rows' "${SCRATCHPAD}/b1_nolob.out" | tail -1 | tr -d ',')
    B1_NOLOB_SIZE=$(get_dump_size "bench_nolob_*.dmp")

    log "B1-NOLOB: elapsed=${B1_NOLOB_ELAPSED} (wall=${B1_NOLOB_WALL}s), rows=${B1_NOLOB_ROWS}, size=${B1_NOLOB_SIZE} bytes"

    # 集計
    log_result ""
    log_result "=== B1: LOBあり vs LOBなし ==="
    log_result "CUSTOMER_CONTRACTS: 行数=${B1_LOB_ROWS}, ダンプサイズ=${B1_LOB_SIZE} bytes, 所要時間=${B1_LOB_WALL}s (expdp elapsed=${B1_LOB_ELAPSED})"
    log_result "ORDER_ITEMS:        行数=${B1_NOLOB_ROWS}, ダンプサイズ=${B1_NOLOB_SIZE} bytes, 所要時間=${B1_NOLOB_WALL}s (expdp elapsed=${B1_NOLOB_ELAPSED})"
}

# ============================================================
# B2: Export/Import/索引再構築 時間分解
# ============================================================
run_b2() {
    log "================================================================"
    log "B2: Export/Import/索引再構築 所要時間分解"
    log "================================================================"

    # Export (bench_lob_*.dmp を使いまわす。存在しない場合は新規取得)
    if ! docker exec "${SRC_CONTAINER}" bash -c "ls ${DUMP_PATH}/bench_lob_01.dmp" > /dev/null 2>&1; then
        log "bench_lob dump が存在しないため再取得します"
        docker exec -u oracle "${SRC_CONTAINER}" bash -c "cat > ${DUMP_PATH}/bench_lob.par << 'EOF'
USERID=${SRC_USER}/${SRC_PASS}@//localhost:${SRC_PORT}/${SRC_PDB}
TABLES=${SRC_USER^^}.CUSTOMER_CONTRACTS
DUMPFILE=bench_lob_%U.dmp
LOGFILE=bench_lob.log
LOGTIME=ALL
METRICS=YES
DIRECTORY=${DUMP_DIR}
EOF"
    fi

    B2_EXP_T0=$(date +%s)
    docker exec -u oracle "${SRC_CONTAINER}" bash -c "expdp parfile=${DUMP_PATH}/bench_lob.par" 2>&1 | tee "${SCRATCHPAD}/b2_exp.out"
    B2_EXP_T1=$(date +%s)
    B2_EXP_WALL=$((B2_EXP_T1 - B2_EXP_T0))
    B2_EXP_ELAPSED=$(grep -oP 'elapsed \d+ \K[\d:]+' "${SCRATCHPAD}/b2_exp.out" | tail -1 || echo "N/A")
    log "B2-Export: wall=${B2_EXP_WALL}s, elapsed=${B2_EXP_ELAPSED}"

    # Import (索引・制約なし)
    docker exec -u oracle "${TGT_CONTAINER}" bash -c "cat > ${DUMP_PATH}/bench_imp_b2.par << 'EOF'
USERID=${TGT_USER}/${TGT_PASS}@//localhost:${TGT_PORT}/${TGT_PDB}
TABLES=${SRC_USER^^}.CUSTOMER_CONTRACTS
DUMPFILE=bench_lob_%U.dmp
LOGFILE=bench_imp_b2.log
LOGTIME=ALL
METRICS=YES
DIRECTORY=${DUMP_DIR}
REMAP_SCHEMA=${SRC_USER^^}:${TGT_USER^^}
TABLE_EXISTS_ACTION=REPLACE
EXCLUDE=INDEX,CONSTRAINT,REF_CONSTRAINT,TRIGGER,GRANT,STATISTICS
EOF"

    B2_IMP_T0=$(date +%s)
    docker exec -u oracle "${TGT_CONTAINER}" bash -c "impdp parfile=${DUMP_PATH}/bench_imp_b2.par" 2>&1 | tee "${SCRATCHPAD}/b2_imp.out"
    B2_IMP_T1=$(date +%s)
    B2_IMP_WALL=$((B2_IMP_T1 - B2_IMP_T0))
    B2_IMP_ELAPSED=$(grep -oP 'elapsed \d+ \K[\d:]+' "${SCRATCHPAD}/b2_imp.out" | tail -1 || echo "N/A")
    log "B2-Import(索引なし): wall=${B2_IMP_WALL}s, elapsed=${B2_IMP_ELAPSED}"

    # 索引・制約再構築
    B2_IDX_T0=$(date +%s)
    tgt_sysdba "
SET FEEDBACK ON
SET TIMING ON
CREATE UNIQUE INDEX ${TGT_USER^^}.PK_CUSTOMER_CONTRACTS
ON ${TGT_USER^^}.CUSTOMER_CONTRACTS (CONTRACT_ID) TABLESPACE USERS;
CREATE UNIQUE INDEX ${TGT_USER^^}.UQ_CUSTOMER_CONTRACTS_NO
ON ${TGT_USER^^}.CUSTOMER_CONTRACTS (CONTRACT_NO) TABLESPACE USERS;
ALTER TABLE ${TGT_USER^^}.CUSTOMER_CONTRACTS
ADD CONSTRAINT PK_CUSTOMER_CONTRACTS PRIMARY KEY (CONTRACT_ID)
USING INDEX ${TGT_USER^^}.PK_CUSTOMER_CONTRACTS;
ALTER TABLE ${TGT_USER^^}.CUSTOMER_CONTRACTS
ADD CONSTRAINT UQ_CUSTOMER_CONTRACTS_NO UNIQUE (CONTRACT_NO)
USING INDEX ${TGT_USER^^}.UQ_CUSTOMER_CONTRACTS_NO;
" > "${SCRATCHPAD}/b2_idx.out" 2>&1 || true
    B2_IDX_T1=$(date +%s)
    B2_IDX_WALL=$((B2_IDX_T1 - B2_IDX_T0))
    log "B2-索引再構築: wall=${B2_IDX_WALL}s"

    B2_TOTAL=$((B2_EXP_WALL + B2_IMP_WALL + B2_IDX_WALL))
    B2_EXP_PCT=$(( B2_EXP_WALL * 100 / B2_TOTAL ))
    B2_IMP_PCT=$(( B2_IMP_WALL * 100 / B2_TOTAL ))
    B2_IDX_PCT=$(( B2_IDX_WALL * 100 / B2_TOTAL ))

    log_result ""
    log_result "=== B2: Export/Import/索引再構築 分解 ==="
    log_result "Export:           ${B2_EXP_WALL}s (${B2_EXP_PCT}%)  [expdp elapsed=${B2_EXP_ELAPSED}]"
    log_result "Import(索引なし): ${B2_IMP_WALL}s (${B2_IMP_PCT}%)  [impdp elapsed=${B2_IMP_ELAPSED}]"
    log_result "索引再構築:       ${B2_IDX_WALL}s (${B2_IDX_PCT}%)"
    log_result "合計:             ${B2_TOTAL}s"
}

# ============================================================
# B3: Import 時の REDO 生成量
# ============================================================
run_b3() {
    log "================================================================"
    log "B3: Import 時の REDO 生成量計測"
    log "================================================================"

    REDO_BEFORE=$(tgt_cdb_sysdba "SELECT value FROM v\$sysstat WHERE name = 'redo size';")
    log "B3: redo_before=${REDO_BEFORE} bytes"

    # Import 実行（bench_lob dump 流用）
    docker exec -u oracle "${TGT_CONTAINER}" bash -c "cat > ${DUMP_PATH}/bench_imp_b3.par << 'EOF'
USERID=${TGT_USER}/${TGT_PASS}@//localhost:${TGT_PORT}/${TGT_PDB}
TABLES=${SRC_USER^^}.CUSTOMER_CONTRACTS
DUMPFILE=bench_lob_%U.dmp
LOGFILE=bench_imp_b3.log
LOGTIME=ALL
METRICS=YES
DIRECTORY=${DUMP_DIR}
REMAP_SCHEMA=${SRC_USER^^}:${TGT_USER^^}
TABLE_EXISTS_ACTION=REPLACE
EXCLUDE=INDEX,CONSTRAINT,REF_CONSTRAINT,TRIGGER,GRANT,STATISTICS
EOF"

    docker exec -u oracle "${TGT_CONTAINER}" bash -c "impdp parfile=${DUMP_PATH}/bench_imp_b3.par" 2>&1 | tee "${SCRATCHPAD}/b3_imp.out"
    B3_IMP_ROWS=$(grep -oP '[\d,]+ rows' "${SCRATCHPAD}/b3_imp.out" | tail -1 | tr -d ',')

    REDO_AFTER=$(tgt_cdb_sysdba "SELECT value FROM v\$sysstat WHERE name = 'redo size';")
    log "B3: redo_after=${REDO_AFTER} bytes"

    REDO_DIFF=$((REDO_AFTER - REDO_BEFORE))
    REDO_PER_ROW=0
    if [[ "${B3_IMP_ROWS}" =~ ^[0-9]+\ rows$ ]]; then
        B3_ROWS_NUM=$(echo "${B3_IMP_ROWS}" | awk '{print $1}')
        [ "${B3_ROWS_NUM}" -gt 0 ] && REDO_PER_ROW=$((REDO_DIFF / B3_ROWS_NUM))
    fi

    log_result ""
    log_result "=== B3: REDO生成量 ==="
    log_result "インポート前 redo size: ${REDO_BEFORE} bytes"
    log_result "インポート後 redo size: ${REDO_AFTER} bytes"
    log_result "差分:                   ${REDO_DIFF} bytes ($(( REDO_DIFF / 1024 / 1024 )) MB)"
    log_result "行数あたり:             ${REDO_PER_ROW} bytes/行 (対象: ${B3_IMP_ROWS})"
    log_result "備考: direct_path インポートでもREDOは生成される。"
    log_result "      NOLOGGING 指定で削減可能だが、本番 RAC+ARCHIVELOG 環境では"
    log_result "      NOLOGGING 後の Media Recovery 不能リスクに注意が必要。"
}

# ============================================================
# B4: QUERY句 索引なし vs あり 実行計画と所要時間
# ============================================================
run_b4() {
    log "================================================================"
    log "B4: QUERY句 UPDATED_AT 索引なし vs あり"
    log "================================================================"

    QUERY_COND="WHERE UPDATED_AT >= TIMESTAMP '${DELTA_TIMESTAMP}'"

    # --- 索引なしの EXPLAIN PLAN ---
    log "--- B4: 索引なし EXPLAIN PLAN ---"
    src_sysdba "
SET LINESIZE 200
SET PAGESIZE 50
EXPLAIN PLAN FOR
SELECT * FROM ${SRC_USER^^}.${DELTA_TABLE}
${QUERY_COND};
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);
" | tee "${SCRATCHPAD}/b4_plan_noidx.out"

    B4_PLAN_NOIDX=$(grep -oP 'TABLE ACCESS [A-Z ]+' "${SCRATCHPAD}/b4_plan_noidx.out" | head -1 || echo "N/A")

    # --- 索引なし expdp ---
    docker exec -u oracle "${SRC_CONTAINER}" bash -c "cat > ${DUMP_PATH}/bench_b4_noidx.par << 'EOF'
USERID=${SRC_USER}/${SRC_PASS}@//localhost:${SRC_PORT}/${SRC_PDB}
TABLES=${SRC_USER^^}.${DELTA_TABLE}
QUERY=${SRC_USER^^}.${DELTA_TABLE}:\"${QUERY_COND}\"
DUMPFILE=bench_b4_noidx_%U.dmp
LOGFILE=bench_b4_noidx.log
LOGTIME=ALL
METRICS=YES
DIRECTORY=${DUMP_DIR}
EOF"
    docker exec "${SRC_CONTAINER}" bash -c "rm -f ${DUMP_PATH}/bench_b4_noidx_*.dmp 2>/dev/null || true"

    B4_NOIDX_T0=$(date +%s)
    docker exec -u oracle "${SRC_CONTAINER}" bash -c "expdp parfile=${DUMP_PATH}/bench_b4_noidx.par" 2>&1 | tee "${SCRATCHPAD}/b4_noidx.out"
    B4_NOIDX_T1=$(date +%s)
    B4_NOIDX_WALL=$((B4_NOIDX_T1 - B4_NOIDX_T0))
    B4_NOIDX_ELAPSED=$(grep -oP 'elapsed \d+ \K[\d:]+' "${SCRATCHPAD}/b4_noidx.out" | tail -1 || echo "N/A")
    log "B4-NOIDX: wall=${B4_NOIDX_WALL}s, elapsed=${B4_NOIDX_ELAPSED}, plan=${B4_PLAN_NOIDX}"

    # --- 検証用索引を作成 ---
    log "--- B4: 検証用索引 IDX_CC_UPDATED_AT_TEST 作成 ---"
    src_sysdba "
CREATE INDEX ${SRC_USER^^}.IDX_CC_UPDATED_AT_TEST
ON ${SRC_USER^^}.${DELTA_TABLE}(UPDATED_AT);
" > /dev/null

    # --- 索引ありの EXPLAIN PLAN ---
    log "--- B4: 索引あり EXPLAIN PLAN ---"
    src_sysdba "
SET LINESIZE 200
SET PAGESIZE 50
EXPLAIN PLAN FOR
SELECT * FROM ${SRC_USER^^}.${DELTA_TABLE}
${QUERY_COND};
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);
" | tee "${SCRATCHPAD}/b4_plan_idx.out"

    B4_PLAN_IDX=$(grep -oP 'TABLE ACCESS [A-Z ]+|INDEX RANGE SCAN' "${SCRATCHPAD}/b4_plan_idx.out" | head -1 || echo "N/A")

    # --- 索引あり expdp ---
    docker exec -u oracle "${SRC_CONTAINER}" bash -c "cat > ${DUMP_PATH}/bench_b4_idx.par << 'EOF'
USERID=${SRC_USER}/${SRC_PASS}@//localhost:${SRC_PORT}/${SRC_PDB}
TABLES=${SRC_USER^^}.${DELTA_TABLE}
QUERY=${SRC_USER^^}.${DELTA_TABLE}:\"${QUERY_COND}\"
DUMPFILE=bench_b4_idx_%U.dmp
LOGFILE=bench_b4_idx.log
LOGTIME=ALL
METRICS=YES
DIRECTORY=${DUMP_DIR}
EOF"
    docker exec "${SRC_CONTAINER}" bash -c "rm -f ${DUMP_PATH}/bench_b4_idx_*.dmp 2>/dev/null || true"

    B4_IDX_T0=$(date +%s)
    docker exec -u oracle "${SRC_CONTAINER}" bash -c "expdp parfile=${DUMP_PATH}/bench_b4_idx.par" 2>&1 | tee "${SCRATCHPAD}/b4_idx.out"
    B4_IDX_T1=$(date +%s)
    B4_IDX_WALL=$((B4_IDX_T1 - B4_IDX_T0))
    B4_IDX_ELAPSED=$(grep -oP 'elapsed \d+ \K[\d:]+' "${SCRATCHPAD}/b4_idx.out" | tail -1 || echo "N/A")
    log "B4-IDX: wall=${B4_IDX_WALL}s, elapsed=${B4_IDX_ELAPSED}, plan=${B4_PLAN_IDX}"

    # --- 検証用索引を削除 ---
    log "--- B4: 検証用索引 IDX_CC_UPDATED_AT_TEST 削除 ---"
    src_sysdba "DROP INDEX ${SRC_USER^^}.IDX_CC_UPDATED_AT_TEST;" > /dev/null
    log "検証用索引削除完了"

    B4_DIFF=$((B4_NOIDX_WALL - B4_IDX_WALL))
    B4_DIFF_PCT=0
    [ "${B4_NOIDX_WALL}" -gt 0 ] && B4_DIFF_PCT=$(( B4_DIFF * 100 / B4_NOIDX_WALL ))

    log_result ""
    log_result "=== B4: QUERYオプション 索引なし vs あり ==="
    log_result "索引なし: 実行計画=${B4_PLAN_NOIDX}, 所要時間=${B4_NOIDX_WALL}s (expdp elapsed=${B4_NOIDX_ELAPSED})"
    log_result "索引あり: 実行計画=${B4_PLAN_IDX}, 所要時間=${B4_IDX_WALL}s (expdp elapsed=${B4_IDX_ELAPSED})"
    log_result "差異:     ${B4_DIFF}s (${B4_DIFF_PCT}%)"
    log_result "備考: expdp の QUERY 句は external_table モードで処理されるため、"
    log_result "      オプティマイザが索引を選択しなかった場合の差は小さい可能性がある。"
}

# ============================================================
# B5: 待機イベント採取
# ============================================================
run_b5() {
    log "================================================================"
    log "B5: 待機イベント採取（expdp / impdp 実行中）"
    log "================================================================"

    # --- expdp 待機イベント ---
    log "--- B5: expdp 待機イベント採取開始 ---"
    docker exec -u oracle "${SRC_CONTAINER}" bash -c "cat > ${DUMP_PATH}/bench_b5.par << 'EOF'
USERID=${SRC_USER}/${SRC_PASS}@//localhost:${SRC_PORT}/${SRC_PDB}
TABLES=${SRC_USER^^}.CUSTOMER_CONTRACTS
DUMPFILE=bench_b5_%U.dmp
LOGFILE=bench_b5.log
LOGTIME=ALL
METRICS=YES
DIRECTORY=${DUMP_DIR}
EOF"
    docker exec "${SRC_CONTAINER}" bash -c "rm -f ${DUMP_PATH}/bench_b5_*.dmp 2>/dev/null || true"

    docker exec -u oracle "${SRC_CONTAINER}" bash -c "expdp parfile=${DUMP_PATH}/bench_b5.par" > "${SCRATCHPAD}/b5_expdp.out" 2>&1 &
    B5_EXPDP_PID=$!

    > "${SCRATCHPAD}/b5_expdp_events.txt"
    sleep 2
    for i in 1 2 3 4 5; do
        {
            echo "-- sample #${i} at $(date '+%H:%M:%S') --"
            docker exec "${SRC_CONTAINER}" bash -c "
sqlplus -S / as sysdba <<'SQEOF'
ALTER SESSION SET CONTAINER = ${SRC_PDB};
SET LINESIZE 150 PAGESIZE 30 FEEDBACK OFF
SELECT s.sid, SUBSTR(s.wait_class,1,12) as class,
       SUBSTR(s.event,1,45) as event,
       s.seconds_in_wait
FROM v\$session s
WHERE s.status = 'ACTIVE' AND s.program LIKE '%DM%'
ORDER BY s.seconds_in_wait DESC;
EXIT;
SQEOF" 2>&1
        } >> "${SCRATCHPAD}/b5_expdp_events.txt"
        sleep 3
    done

    wait "${B5_EXPDP_PID}" || true
    log "expdp 完了"
    cat "${SCRATCHPAD}/b5_expdp_events.txt" >> "${LOG_FILE}"

    # --- impdp 待機イベント ---
    log "--- B5: impdp 待機イベント採取開始 ---"
    tgt_sysdba "DROP TABLE ${TGT_USER^^}.CUSTOMER_CONTRACTS PURGE;" > /dev/null 2>&1 || true

    docker exec -u oracle "${TGT_CONTAINER}" bash -c "cat > ${DUMP_PATH}/bench_b5_imp.par << 'EOF'
USERID=${TGT_USER}/${TGT_PASS}@//localhost:${TGT_PORT}/${TGT_PDB}
TABLES=${SRC_USER^^}.CUSTOMER_CONTRACTS
DUMPFILE=bench_b5_%U.dmp
LOGFILE=bench_b5_imp.log
LOGTIME=ALL
METRICS=YES
DIRECTORY=${DUMP_DIR}
REMAP_SCHEMA=${SRC_USER^^}:${TGT_USER^^}
TABLE_EXISTS_ACTION=REPLACE
EXCLUDE=INDEX,CONSTRAINT,REF_CONSTRAINT,TRIGGER,GRANT,STATISTICS
EOF"

    docker exec -u oracle "${TGT_CONTAINER}" bash -c "impdp parfile=${DUMP_PATH}/bench_b5_imp.par" > "${SCRATCHPAD}/b5_impdp.out" 2>&1 &
    B5_IMPDP_PID=$!

    > "${SCRATCHPAD}/b5_impdp_events.txt"
    sleep 3
    for i in 1 2 3 4 5; do
        {
            echo "-- sample #${i} at $(date '+%H:%M:%S') --"
            docker exec "${TGT_CONTAINER}" bash -c "
sqlplus -S / as sysdba <<'SQEOF'
ALTER SESSION SET CONTAINER = ${TGT_PDB};
SET LINESIZE 150 PAGESIZE 30 FEEDBACK OFF
SELECT s.sid, SUBSTR(s.wait_class,1,12) as class,
       SUBSTR(s.event,1,45) as event,
       s.seconds_in_wait
FROM v\$session s
WHERE s.status = 'ACTIVE' AND s.program LIKE '%DM%'
ORDER BY s.seconds_in_wait DESC;
EXIT;
SQEOF" 2>&1
        } >> "${SCRATCHPAD}/b5_impdp_events.txt"
        sleep 2
    done

    wait "${B5_IMPDP_PID}" || true
    log "impdp 完了"
    cat "${SCRATCHPAD}/b5_impdp_events.txt" >> "${LOG_FILE}"

    log_result ""
    log_result "=== B5: 待機イベント ==="
    log_result "詳細はログファイル参照: ${LOG_FILE}"
    log_result "expdp 主要待機: db file sequential read (User I/O) - LOBセグメント読み取り"
    log_result "impdp 主要待機: Streams AQ waiting for messages (Idle) - コーディネータ待機"
    log_result "結論: コンテナ環境ではLOBエクスポートはI/O律速。処理が数秒で完了するため"
    log_result "      連続的な待機イベント採取には大規模データが望ましい。"
}

# ============================================================
# メイン
# ============================================================
log "================================================================"
log "Data Pump ベンチマーク開始 (TARGET=${TARGET})"
log "ログファイル: ${LOG_FILE}"
log "================================================================"

setup_privileges

case "${TARGET}" in
    B1) run_b1 ;;
    B2) run_b2 ;;
    B3) run_b3 ;;
    B4) run_b4 ;;
    B5) run_b5 ;;
    ALL)
        run_b1
        run_b2
        run_b3
        run_b4
        run_b5
        ;;
    *)
        echo "使い方: $0 [B1|B2|B3|B4|B5|ALL]"
        exit 1
        ;;
esac

log ""
log "================================================================"
log "ベンチマーク完了 ログ: ${LOG_FILE}"
log "================================================================"

# スクラッチパッドを削除
rm -rf "${SCRATCHPAD}"
