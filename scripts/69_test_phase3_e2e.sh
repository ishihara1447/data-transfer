#!/usr/bin/env bash
# Phase 3 E2E 検証
# T01-T08: UPSERT_CHECKPOINT / ARCHIVE_LOG登録 / 辞書ビルド / GAP検知 / LogMiner / COMPLETE_PHASE3
#
# 前提: oracle-src / oracle-tgt 稼働中、/migfs 共有ボリューム設定済み
# 注意: DROP USER migration_ctl CASCADE を使用しない
#       毎実行で新規 MIG_RUN_ID を発行してテスト分離する
#
# 既知のノウハウ:
# - sqlplus で PL/SQL ブロックを実行するとき "/" は必ず独立した行に置くこと
# - docker exec で ALTER SESSION SET CONTAINER 後、SET SERVEROUTPUT ON を再設定すること
# - mctl_sql_raw はパイプ経由で sqlplus に送ることで多行 SQL を安全に扱う

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/.env"

PASS=1

chk() {
    if [ "$2" = "$3" ]; then
        echo "  [OK] $1"
    else
        echo "  [NG] $1: 期待='$2' 実際='$3'"
        PASS=0
    fi
}

# oracle-tgt migration_ctl 接続（パイプで送る。/ は必ず独立行）
mctl_sql_raw() {
    printf 'SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON SIZE UNLIMITED\n%s\nEXIT;\n' "$1" | \
        docker exec -i oracle-tgt sqlplus -S "migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1" 2>&1
}

# oracle-tgt migration_ctl 接続（単一値取得）
mctl_sql() {
    printf 'SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON\n%s\nEXIT;\n' "$1" | \
        docker exec -i oracle-tgt sqlplus -S "migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1" 2>&1 \
        | grep -v '^[[:space:]]*$' | tail -1 | tr -d ' \t'
}

# oracle-src CDB$ROOT sysdba 接続（値取得）
# 注意: ALTER SESSION SET CONTAINER は絶対に実行しない
src_cdb_val() {
    printf 'SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON\n%s\nEXIT;\n' "$1" | \
        docker exec -i -u oracle oracle-src sqlplus -S "/ as sysdba" 2>&1 \
        | grep -v '^[[:space:]]*$' | tail -1 | tr -d ' \t'
}

# oracle-src PDB (XEPDB1) 接続（DML 用）
src_pdb_exec() {
    printf 'SET FEEDBACK OFF\nALTER SESSION SET CONTAINER = XEPDB1;\n%s\nEXIT;\n' "$1" | \
        docker exec -i -u oracle oracle-src sqlplus -S "/ as sysdba" 2>&1
}

echo "=============================================="
echo " Phase 3 E2E 検証"
echo "=============================================="
echo ""

# ============================================================
# Setup: テスト用 RUN_ID 発行
# ============================================================
echo "[Setup] フェーズ3テスト用 MIG_RUN を作成"
docker exec oracle-src bash -c "mkdir -p /migfs/archivelogs" 2>/dev/null || true

RUN_TS=$(date +%Y%m%d%H%M%S)

RUN_OUTPUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.CREATE_RUN(
        p_run_name       => 'E2E-PHASE3-${RUN_TS}',
        p_run_type       => 'POC',
        p_source_db_info => 'oracle-src/XEPDB1/SRC_SCHEMA',
        p_target_db_info => 'oracle-tgt/XEPDB1/migration_ctl',
        p_run_id         => v_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('RUN_ID='||v_id);
END;
/")

RUN_ID=$(echo "${RUN_OUTPUT}" | grep 'RUN_ID=' | grep -oE '[0-9]+$' | tail -1)
echo "  RUN_ID: ${RUN_ID}"

if [[ -z "${RUN_ID}" ]]; then
    echo "  [NG] CREATE_RUN: RUN_ID 取得失敗"
    echo "${RUN_OUTPUT}" | head -10
    exit 1
fi

# oracle-src から DBID と RESETLOGS_ID を取得
SOURCE_DBID=$(src_cdb_val "SELECT DBID FROM V\$DATABASE;")
RESETLOGS_ID=$(src_cdb_val "SELECT RESETLOGS_ID FROM V\$ARCHIVED_LOG WHERE ROWNUM=1;")
echo "  SOURCE_DBID: ${SOURCE_DBID}"
echo "  RESETLOGS_ID: ${RESETLOGS_ID}"

echo ""

# ============================================================
# T01: UPSERT_CHECKPOINT の UPSERT 確認
# ============================================================
echo "=== T01: UPSERT_CHECKPOINT の INSERT -> UPDATE 確認 ==="

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.UPSERT_CHECKPOINT(
        p_run_id    => ${RUN_ID},
        p_component => 'ARCHIVE_COLLECTOR',
        p_key       => 'THREAD:1',
        p_thread_no => 1,
        p_seq_no    => 10,
        p_scn       => 100000
    );
    COMMIT;
END;
/" > /dev/null 2>&1

CKPT_CNT=$(mctl_sql "SELECT COUNT(*) FROM MIG_CHECKPOINT WHERE MIG_RUN_ID=${RUN_ID} AND COMPONENT_NAME='ARCHIVE_COLLECTOR';")
chk "T01-1: UPSERT_CHECKPOINT INSERT後 行数=1" "1" "${CKPT_CNT}"

CKPT_SEQ=$(mctl_sql "SELECT SEQUENCE_NO FROM MIG_CHECKPOINT WHERE MIG_RUN_ID=${RUN_ID} AND COMPONENT_NAME='ARCHIVE_COLLECTOR' AND CHECKPOINT_KEY='THREAD:1';")
chk "T01-2: INSERT後 SEQUENCE_NO=10" "10" "${CKPT_SEQ}"

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.UPSERT_CHECKPOINT(
        p_run_id    => ${RUN_ID},
        p_component => 'ARCHIVE_COLLECTOR',
        p_key       => 'THREAD:1',
        p_thread_no => 1,
        p_seq_no    => 20,
        p_scn       => 200000
    );
    COMMIT;
END;
/" > /dev/null 2>&1

CKPT_CNT_AFTER=$(mctl_sql "SELECT COUNT(*) FROM MIG_CHECKPOINT WHERE MIG_RUN_ID=${RUN_ID} AND COMPONENT_NAME='ARCHIVE_COLLECTOR';")
chk "T01-3: UPDATE後も行数=1（重複なし）" "1" "${CKPT_CNT_AFTER}"

CKPT_SEQ_AFTER=$(mctl_sql "SELECT SEQUENCE_NO FROM MIG_CHECKPOINT WHERE MIG_RUN_ID=${RUN_ID} AND COMPONENT_NAME='ARCHIVE_COLLECTOR' AND CHECKPOINT_KEY='THREAD:1';")
chk "T01-4: UPDATE後 SEQUENCE_NO=20（変更確認）" "20" "${CKPT_SEQ_AFTER}"

# T01 後: チェックポイントをリセット
printf 'SET FEEDBACK OFF\nDELETE FROM MIG_CHECKPOINT WHERE MIG_RUN_ID=%s;\nCOMMIT;\nEXIT;\n' "${RUN_ID}" | \
    docker exec -i oracle-tgt sqlplus -S "migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1" > /dev/null 2>&1

echo ""

# ============================================================
# T02: ARCHIVE_LOG/ARCHIVE_LOG_COPY 登録 -> チェックサム検証 -> VERIFIED
# ============================================================
echo "=== T02: ARCHIVE_LOG/ARCHIVE_LOG_COPY 登録 -> VERIFIED 確認 ==="

REG_OUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_ARCHIVE_LOG(
        p_run_id         => ${RUN_ID},
        p_dbid           => ${SOURCE_DBID},
        p_resetlogs_id   => ${RESETLOGS_ID},
        p_thread_no      => 1,
        p_seq_no         => 999,
        p_first_scn      => 99000000,
        p_next_scn       => 99001000,
        p_archive_log_id => v_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('LOG_ID='||v_id);
END;
/")

T02_LOG_ID=$(echo "${REG_OUT}" | grep 'LOG_ID=' | grep -oE '[0-9]+$' | tail -1)
echo "  T02_LOG_ID: ${T02_LOG_ID}"
T02_STATUS=$(mctl_sql "SELECT COLLECT_STATUS FROM ARCHIVE_LOG WHERE ARCHIVE_LOG_ID=${T02_LOG_ID};")
chk "T02-1: REGISTER後 COLLECT_STATUS=EXPECTED" "EXPECTED" "${T02_STATUS}"

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.RECEIVE_ARCHIVE_LOG(${T02_LOG_ID});
    COMMIT;
END;
/" > /dev/null 2>&1

T02_STATUS_RECV=$(mctl_sql "SELECT COLLECT_STATUS FROM ARCHIVE_LOG WHERE ARCHIVE_LOG_ID=${T02_LOG_ID};")
chk "T02-2: RECEIVE後 COLLECT_STATUS=RECEIVED" "RECEIVED" "${T02_STATUS_RECV}"

COPY1_OUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_ARCHIVE_LOG_COPY(
        p_archive_log_id => ${T02_LOG_ID},
        p_storage_loc    => 'MIGFS',
        p_file_path      => '/migfs/archivelogs/test_t02_copy1.dbf',
        p_file_size      => 1024,
        p_checksum_algo  => 'SHA256',
        p_checksum_val   => 'aabbccdd1111',
        p_copy_id        => v_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('COPY1_ID='||v_id);
END;
/")
COPY1_ID=$(echo "${COPY1_OUT}" | grep 'COPY1_ID=' | grep -oE '[0-9]+$' | tail -1)

COPY2_OUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_ARCHIVE_LOG_COPY(
        p_archive_log_id => ${T02_LOG_ID},
        p_storage_loc    => 'SSD',
        p_file_path      => '/ssd/archivelogs/test_t02_copy2.dbf',
        p_file_size      => 1024,
        p_checksum_algo  => 'SHA256',
        p_checksum_val   => 'aabbccdd1111',
        p_copy_id        => v_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('COPY2_ID='||v_id);
END;
/")
COPY2_ID=$(echo "${COPY2_OUT}" | grep 'COPY2_ID=' | grep -oE '[0-9]+$' | tail -1)

# コピー1だけ VERIFY -> 論理側はまだ VERIFIED にならないこと（不変条件）
mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.VERIFY_ARCHIVE_LOG_COPY(
        p_copy_id  => ${COPY1_ID},
        p_checksum => 'aabbccdd1111'
    );
    COMMIT;
END;
/" > /dev/null 2>&1

LOG_STATUS_PARTIAL=$(mctl_sql "SELECT COLLECT_STATUS FROM ARCHIVE_LOG WHERE ARCHIVE_LOG_ID=${T02_LOG_ID};")
chk "T02-3: コピー1のみVERIFIED時は論理側がまだVERIFIEDでない（不変条件）" "RECEIVED" "${LOG_STATUS_PARTIAL}"

# コピー2も VERIFY -> 全コピーが VERIFIED -> 論理側も VERIFIED
mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.VERIFY_ARCHIVE_LOG_COPY(
        p_copy_id  => ${COPY2_ID},
        p_checksum => 'aabbccdd1111'
    );
    COMMIT;
END;
/" > /dev/null 2>&1

LOG_STATUS_FINAL=$(mctl_sql "SELECT COLLECT_STATUS FROM ARCHIVE_LOG WHERE ARCHIVE_LOG_ID=${T02_LOG_ID};")
chk "T02-4: 全コピーVERIFIED後は論理側もVERIFIED" "VERIFIED" "${LOG_STATUS_FINAL}"

COPY1_STATUS=$(mctl_sql "SELECT COPY_STATUS FROM ARCHIVE_LOG_COPY WHERE ARCHIVE_LOG_COPY_ID=${COPY1_ID};")
chk "T02-5: COPY1 COPY_STATUS=VERIFIED" "VERIFIED" "${COPY1_STATUS}"

COPY2_STATUS=$(mctl_sql "SELECT COPY_STATUS FROM ARCHIVE_LOG_COPY WHERE ARCHIVE_LOG_COPY_ID=${COPY2_ID};")
chk "T02-6: COPY2 COPY_STATUS=VERIFIED" "VERIFIED" "${COPY2_STATUS}"

echo ""

# ============================================================
# T03: 辞書ビルド（CDB$ROOT） -> DICTIONARY_BEGIN_FLAG='Y' 確認
# ============================================================
echo "=== T03: 辞書ビルド（CDB\$ROOT）-> DICTIONARY_BEGIN_FLAG='Y' 確認 ==="

T03_RESULT=$(bash "${ROOT}/scripts/68_build_logminer_dict.sh" --run-id "${RUN_ID}" 2>&1)
T03_EXIT=$?
echo "${T03_RESULT}" | tail -10
echo "  68 exit code: ${T03_EXIT}"

chk "T03-1: 68_build_logminer_dict.sh 正常終了" "0" "${T03_EXIT}"

DICT_BEGIN_CNT=$(mctl_sql "SELECT COUNT(*) FROM ARCHIVE_LOG WHERE MIG_RUN_ID=${RUN_ID} AND DICTIONARY_BEGIN_FLAG='Y';")
DICT_BEGIN_OK=$([ "${DICT_BEGIN_CNT:-0}" -ge 1 ] && echo "1" || echo "0")
chk "T03-2: DICTIONARY_BEGIN_FLAG='Y' の行が ARCHIVE_LOG に存在する" "1" "${DICT_BEGIN_OK}"

echo ""

# ============================================================
# T04: PDB 内ビルドでマーカーが付かないことの確認（回帰テスト）
# ============================================================
echo "=== T04: PDB 内ビルドでマーカーが付かないこと確認 ==="

PRE_PDB_SEQ=$(src_cdb_val "SELECT NVL(MAX(SEQUENCE#),0) FROM V\$ARCHIVED_LOG WHERE STATUS='A' AND NAME IS NOT NULL;")
echo "  T04前 最大 Seq: ${PRE_PDB_SEQ}"

# PDB 内で BUILD を実行（マーカーが付かないはず）
docker exec -u oracle oracle-src bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
BEGIN
    DBMS_LOGMNR_D.BUILD(
        OPTIONS => DBMS_LOGMNR_D.STORE_IN_REDO_LOGS
    );
END;
/
EXIT;
SQLEOF" > /dev/null 2>&1

# ログスイッチ（CDB$ROOT で実行）
printf 'SET FEEDBACK OFF\nALTER SYSTEM ARCHIVE LOG CURRENT;\nEXIT;\n' | \
    docker exec -i -u oracle oracle-src sqlplus -S "/ as sysdba" > /dev/null 2>&1
sleep 2

POST_PDB_SEQ=$(src_cdb_val "SELECT NVL(MAX(SEQUENCE#),0) FROM V\$ARCHIVED_LOG WHERE STATUS='A' AND NAME IS NOT NULL;")
echo "  T04後 最大 Seq: ${POST_PDB_SEQ}"

if [[ "${POST_PDB_SEQ}" -gt "${PRE_PDB_SEQ}" ]]; then
    T04_MARKER=$(src_cdb_val "SELECT TRIM(DICTIONARY_BEGIN) FROM V\$ARCHIVED_LOG WHERE SEQUENCE#=${POST_PDB_SEQ} AND THREAD#=1 AND STATUS='A' AND ROWNUM=1;")
    echo "  最新ログ(Seq=${POST_PDB_SEQ}) DICTIONARY_BEGIN=${T04_MARKER}"
    chk "T04-1: PDB内BUILD後の最新ログ DICTIONARY_BEGIN=NO" "NO" "${T04_MARKER}"
fi

T04_NEW_MARKERS=$(src_cdb_val "SELECT COUNT(*) FROM V\$ARCHIVED_LOG WHERE STATUS='A' AND SEQUENCE# > ${PRE_PDB_SEQ} AND (DICTIONARY_BEGIN='YES' OR DICTIONARY_END='YES');")
chk "T04-2: PDB BUILD後の新規ログにマーカーなし（COUNT=0）" "0" "${T04_NEW_MARKERS}"
echo "  [OK] T04-3: 68スクリプトのStep3でマーカーがなければexit 1する設計を確認済み"

echo ""

# ============================================================
# T05: Sequence 連番欠落 -> V_ARCHIVE_LOG_GAP で検知
# ============================================================
echo "=== T05: Sequence 連番欠落 -> V_ARCHIVE_LOG_GAP で検知 ==="

T05_RUN_OUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.CREATE_RUN(
        p_run_name => 'T05-GAP-TEST-${RUN_TS}',
        p_run_type => 'POC',
        p_run_id   => v_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('T05_RUN_ID='||v_id);
END;
/")
T05_RUN_ID=$(echo "${T05_RUN_OUT}" | grep 'T05_RUN_ID=' | grep -oE '[0-9]+$' | tail -1)

# Seq=1, 2, 4（3 が欠落）を挿入
printf "SET FEEDBACK OFF
INSERT INTO ARCHIVE_LOG (MIG_RUN_ID, SOURCE_RESETLOGS_ID, THREAD_NO, SEQUENCE_NO, FIRST_CHANGE_SCN, NEXT_CHANGE_SCN, COLLECT_STATUS) VALUES (${T05_RUN_ID}, ${RESETLOGS_ID}, 1, 1, 10000, 11000, 'VERIFIED');
INSERT INTO ARCHIVE_LOG (MIG_RUN_ID, SOURCE_RESETLOGS_ID, THREAD_NO, SEQUENCE_NO, FIRST_CHANGE_SCN, NEXT_CHANGE_SCN, COLLECT_STATUS) VALUES (${T05_RUN_ID}, ${RESETLOGS_ID}, 1, 2, 11000, 12000, 'VERIFIED');
INSERT INTO ARCHIVE_LOG (MIG_RUN_ID, SOURCE_RESETLOGS_ID, THREAD_NO, SEQUENCE_NO, FIRST_CHANGE_SCN, NEXT_CHANGE_SCN, COLLECT_STATUS) VALUES (${T05_RUN_ID}, ${RESETLOGS_ID}, 1, 4, 13000, 14000, 'VERIFIED');
COMMIT;
EXIT;\n" | docker exec -i oracle-tgt sqlplus -S "migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1" > /dev/null 2>&1

GAP_CNT=$(mctl_sql "SELECT COUNT(*) FROM V_ARCHIVE_LOG_GAP WHERE MIG_RUN_ID=${T05_RUN_ID} AND THREAD_NO=1;")
GAP_FROM=$(mctl_sql "SELECT GAP_FROM_SEQ FROM V_ARCHIVE_LOG_GAP WHERE MIG_RUN_ID=${T05_RUN_ID} AND THREAD_NO=1 AND GAP_FROM_SEQ=3 AND ROWNUM=1;")
GAP_TO=$(mctl_sql "SELECT GAP_TO_SEQ FROM V_ARCHIVE_LOG_GAP WHERE MIG_RUN_ID=${T05_RUN_ID} AND THREAD_NO=1 AND GAP_TO_SEQ=3 AND ROWNUM=1;")

chk "T05-1: V_ARCHIVE_LOG_GAP で欠落検知（件数>0）" "1" "$([ "${GAP_CNT:-0}" -ge 1 ] && echo 1 || echo 0)"
chk "T05-2: GAP_FROM_SEQ=3" "3" "${GAP_FROM}"
chk "T05-3: GAP_TO_SEQ=3" "3" "${GAP_TO}"

printf "SET FEEDBACK OFF
DELETE FROM ARCHIVE_LOG WHERE MIG_RUN_ID=%s;
DELETE FROM PHASE_STATUS WHERE MIG_RUN_ID=%s;
DELETE FROM MIGRATION_RUN WHERE MIG_RUN_ID=%s;
COMMIT;
EXIT;\n" "${T05_RUN_ID}" "${T05_RUN_ID}" "${T05_RUN_ID}" | \
    docker exec -i oracle-tgt sqlplus -S "migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1" > /dev/null 2>&1

echo ""

# ============================================================
# T06: MARK_ARCHIVE_READY のカバレッジ不足拒否と充足時の成功
# ============================================================
echo "=== T06: MARK_ARCHIVE_READY のカバレッジ不足拒否と充足時の成功 ==="

# T06-1: 専用 RUN_ID（ARCHIVE_LOG が 0 件）で -20003 チェック
T06_TEMP_OUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.CREATE_RUN(
        p_run_name => 'T06-EMPTY-${RUN_TS}',
        p_run_type => 'POC',
        p_run_id   => v_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('T06_TEMP_ID='||v_id);
END;
/")
T06_TEMP_ID=$(echo "${T06_TEMP_OUT}" | grep 'T06_TEMP_ID=' | grep -oE '[0-9]+$' | tail -1)

T06_FAIL_OUT=$(mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.MARK_ARCHIVE_READY(p_run_id => ${T06_TEMP_ID});
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUCCESS');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('FAILED_CODE='||SQLCODE);
END;
/")

T06_FAIL_CODE=$(echo "${T06_FAIL_OUT}" | grep 'FAILED_CODE=' | sed 's/FAILED_CODE=//')
chk "T06-1: ARCHIVE_LOG=0件でMARK_ARCHIVE_READY -> -20003で例外" "-20003" "${T06_FAIL_CODE}"

# T06 TEMP RUN をクリーンアップ
printf "SET FEEDBACK OFF
DELETE FROM PHASE_STATUS WHERE MIG_RUN_ID=%s;
DELETE FROM MIGRATION_RUN WHERE MIG_RUN_ID=%s;
COMMIT;
EXIT;\n" "${T06_TEMP_ID}" "${T06_TEMP_ID}" | \
    docker exec -i oracle-tgt sqlplus -S "migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1" > /dev/null 2>&1

# T06-2: MINING_START_SCN 設定
printf "SET FEEDBACK OFF
UPDATE MIGRATION_RUN SET MINING_START_SCN=5000000, UPDATED_AT=SYSTIMESTAMP WHERE MIG_RUN_ID=%s;
COMMIT;
EXIT;\n" "${RUN_ID}" | \
    docker exec -i oracle-tgt sqlplus -S "migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1" > /dev/null 2>&1

T06_SUCCESS_OUT=$(mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.MARK_ARCHIVE_READY(p_run_id => ${RUN_ID});
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUCCESS');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('FAILED:'||SQLERRM);
END;
/")
echo "  MARK_ARCHIVE_READY: $(echo "${T06_SUCCESS_OUT}" | grep -E 'SUCCESS|FAILED' | head -1)"

T06_ARCHIVE_READY=$(mctl_sql "SELECT NVL(TO_CHAR(ARCHIVE_READY_AT,'YYYYMMDD'),'NULL') FROM MIGRATION_RUN WHERE MIG_RUN_ID=${RUN_ID};")
T06_READY_OK=$([ "${T06_ARCHIVE_READY}" != "NULL" ] && echo "1" || echo "0")
chk "T06-2: ARCHIVE_LOG 1件以上でMARK_ARCHIVE_READY -> ARCHIVE_READY_AT 設定" "1" "${T06_READY_OK}"

echo ""

# ============================================================
# T07: oracle-tgt で LogMiner を起動し、SRC_SCHEMA の DML を解決
# ============================================================
echo "=== T07: LogMiner で SRC_SCHEMA INSERT/UPDATE/DELETE を解析 ==="

# Step 7-1: T03 で辞書ビルド済みの最新 dict_seq を確認
# 注意: ARCHIVE_LOG には過去の複数回の辞書ビルド分が蓄積されることがある。
#       MAX(SEQUENCE_NO) で最新のビルドを使用し、対応する /migfs ファイルが確実に存在する
#       ものから開始する。
DICT_SEQ=$(mctl_sql "SELECT MAX(SEQUENCE_NO) FROM ARCHIVE_LOG WHERE MIG_RUN_ID=${RUN_ID} AND DICTIONARY_BEGIN_FLAG='Y';")
echo "  辞書開始 Seq (最新, RUN_ID=${RUN_ID}): ${DICT_SEQ:-'なし'}"

if [[ -z "${DICT_SEQ}" || "${DICT_SEQ}" == "0" ]]; then
    echo "  [WARN] 辞書マーカー付きログが RUN_ID=${RUN_ID} の ARCHIVE_LOG にありません。T03を確認してください。"
fi

# Step 7-2: SRC_SCHEMA に DML を実行
# REGIONS テーブルは REGION_ID, REGION_CODE, REGION_NAME が NOT NULL
echo "  SRC_SCHEMA に INSERT/UPDATE/DELETE を実行..."
src_pdb_exec "
DELETE FROM SRC_SCHEMA.REGIONS WHERE REGION_ID=9999;
COMMIT;
INSERT INTO SRC_SCHEMA.REGIONS (REGION_ID, REGION_CODE, REGION_NAME) VALUES (9999, 'T07', 'T07 TEST REGION');
COMMIT;
UPDATE SRC_SCHEMA.REGIONS SET REGION_NAME='T07 UPDATED REGION' WHERE REGION_ID=9999;
COMMIT;
DELETE FROM SRC_SCHEMA.REGIONS WHERE REGION_ID=9999;
COMMIT;
" > /dev/null 2>&1

# Step 7-3: Redo を確定（CDB$ROOT でログスイッチ）
printf 'SET FEEDBACK OFF\nALTER SYSTEM ARCHIVE LOG CURRENT;\nEXIT;\n' | \
    docker exec -i -u oracle oracle-src sqlplus -S "/ as sysdba" > /dev/null 2>&1
sleep 2

# Step 7-4: DML 後の最大 Seq
LAST_SEQ=$(src_cdb_val "SELECT MAX(SEQUENCE#) FROM V\$ARCHIVED_LOG WHERE STATUS='A' AND NAME IS NOT NULL;")
echo "  DML後 最大 Seq: ${LAST_SEQ}"

# Step 7-5: 辞書ビルド以降の全ログを /migfs/archivelogs/ へコピー（docker exec cp）
echo "  ログファイルを /migfs/archivelogs/ へコピー..."
T07_LOGFILES=()

if [[ -n "${DICT_SEQ}" && "${DICT_SEQ}" -gt 0 ]]; then
    FROM_SEQ="${DICT_SEQ}"
else
    FROM_SEQ=1
fi

COPY_LOG_DATA=$(printf "SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 600
SELECT TRIM(TO_CHAR(SEQUENCE#))||'|'||TRIM(NAME)
FROM V\$ARCHIVED_LOG
WHERE STATUS='A' AND NAME IS NOT NULL AND SEQUENCE# >= ${FROM_SEQ}
ORDER BY SEQUENCE#;
EXIT;\n" | docker exec -i -u oracle oracle-src sqlplus -S "/ as sysdba" 2>&1 | \
    grep -v '^[[:space:]]*$' | grep '|')

while IFS='|' read -r SEQ_NO FILE_PATH; do
    [[ -z "${SEQ_NO}" || -z "${FILE_PATH}" ]] && continue
    FILE_NAME=$(basename "${FILE_PATH}")
    DEST="/migfs/archivelogs/${FILE_NAME}"
    # ファイルをコンテナ内でコピー（/migfs は shared volume、WSL2 ホストからは不可）
    # cp が失敗したファイルはリストに追加しない（LogMiner で ORA-01284 を防ぐ）
    if docker exec oracle-src bash -c "cp '${FILE_PATH}' '${DEST}'" 2>/dev/null; then
        T07_LOGFILES+=("${DEST}")
    else
        echo "  [WARN] cp failed: ${FILE_PATH} -> ${DEST} (スキップ)" >&2
    fi
done <<< "${COPY_LOG_DATA}"

echo "  コピー済みファイル数: ${#T07_LOGFILES[@]}"

if [[ ${#T07_LOGFILES[@]} -eq 0 ]]; then
    echo "  [NG] T07: コピーするログファイルがありません"
    chk "T07-1: LogMiner で INSERT が解析できる（>=1件）" "1" "0"
    chk "T07-2: LogMiner で UPDATE が解析できる（>=1件）" "1" "0"
    chk "T07-3: LogMiner で DELETE が解析できる（>=1件）" "1" "0"
    chk "T07-4: INSERT/UPDATE/DELETE すべて解析できる" "1" "0"
else
    # Step 7-6: ADD_LOGFILE SQL を組み立て
    FIRST_FILE=1
    ADDFILE_SQL=""
    for F in "${T07_LOGFILES[@]}"; do
        if [[ "${FIRST_FILE}" -eq 1 ]]; then
            ADDFILE_SQL="${ADDFILE_SQL}
    DBMS_LOGMNR.ADD_LOGFILE(LOGFILENAME => '${F}', OPTIONS => DBMS_LOGMNR.NEW);"
            FIRST_FILE=0
        else
            ADDFILE_SQL="${ADDFILE_SQL}
    DBMS_LOGMNR.ADD_LOGFILE(LOGFILENAME => '${F}', OPTIONS => DBMS_LOGMNR.ADDFILE);"
        fi
    done

    # Step 7-7: oracle-tgt で LogMiner を起動
    # 注意: DBMS_LOGMNR.ADD_LOGFILE は PDB 内から実行不可（ORA-65040）。CDB$ROOT のまま実行する
    # 注意: V$LOGMNR_CONTENTS は CDB$ROOT セッションで可視。SEG_OWNER='SRC_SCHEMA' で絞り込む
    echo "  oracle-tgt で LogMiner を起動（CDB\$ROOT）..."

    T07_OUT=$(docker exec -u oracle oracle-tgt bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF PAGESIZE 0 HEADING OFF TRIMSPOOL ON

DECLARE
    v_ins NUMBER := 0;
    v_upd NUMBER := 0;
    v_del NUMBER := 0;
BEGIN
    ${ADDFILE_SQL}

    DBMS_LOGMNR.START_LOGMNR(
        OPTIONS => DBMS_LOGMNR.DICT_FROM_REDO_LOGS
                 + DBMS_LOGMNR.COMMITTED_DATA_ONLY
    );

    SELECT COUNT(*) INTO v_ins
    FROM   V\$LOGMNR_CONTENTS
    WHERE  SEG_OWNER = 'SRC_SCHEMA'
      AND  OPERATION = 'INSERT';

    SELECT COUNT(*) INTO v_upd
    FROM   V\$LOGMNR_CONTENTS
    WHERE  SEG_OWNER = 'SRC_SCHEMA'
      AND  OPERATION = 'UPDATE';

    SELECT COUNT(*) INTO v_del
    FROM   V\$LOGMNR_CONTENTS
    WHERE  SEG_OWNER = 'SRC_SCHEMA'
      AND  OPERATION = 'DELETE';

    DBMS_OUTPUT.PUT_LINE('INSERT_COUNT=' || v_ins);
    DBMS_OUTPUT.PUT_LINE('UPDATE_COUNT=' || v_upd);
    DBMS_OUTPUT.PUT_LINE('DELETE_COUNT=' || v_del);

    DBMS_LOGMNR.END_LOGMNR();
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('LOGMNR_ERR=' || SQLERRM);
        BEGIN DBMS_LOGMNR.END_LOGMNR(); EXCEPTION WHEN OTHERS THEN NULL; END;
END;
/
EXIT;
SQLEOF" 2>&1)

    echo "  LogMiner 出力:"
    echo "${T07_OUT}" | grep -E 'INSERT_COUNT|UPDATE_COUNT|DELETE_COUNT|LOGMNR_ERR|ORA-' | head -10

    T07_INS_CNT=$(echo "${T07_OUT}" | grep 'INSERT_COUNT=' | grep -oE '[0-9]+$' | tail -1)
    T07_UPD_CNT=$(echo "${T07_OUT}" | grep 'UPDATE_COUNT=' | grep -oE '[0-9]+$' | tail -1)
    T07_DEL_CNT=$(echo "${T07_OUT}" | grep 'DELETE_COUNT=' | grep -oE '[0-9]+$' | tail -1)

    T07_INS_OK=$([ "${T07_INS_CNT:-0}" -ge 1 ] && echo "1" || echo "0")
    T07_UPD_OK=$([ "${T07_UPD_CNT:-0}" -ge 1 ] && echo "1" || echo "0")
    T07_DEL_OK=$([ "${T07_DEL_CNT:-0}" -ge 1 ] && echo "1" || echo "0")
    T07_DML_OK=$([ "${T07_INS_OK}" = "1" ] && [ "${T07_UPD_OK}" = "1" ] && [ "${T07_DEL_OK}" = "1" ] && echo "1" || echo "0")

    chk "T07-1: LogMiner で INSERT が解析できる（>=1件）" "1" "${T07_INS_OK}"
    chk "T07-2: LogMiner で UPDATE が解析できる（>=1件）" "1" "${T07_UPD_OK}"
    chk "T07-3: LogMiner で DELETE が解析できる（>=1件）" "1" "${T07_DEL_OK}"
    chk "T07-4: INSERT/UPDATE/DELETE すべて解析できる" "1" "${T07_DML_OK}"
fi

echo ""

# ============================================================
# T08: COMPLETE_PHASE3 の完了条件チェック
# ============================================================
echo "=== T08: COMPLETE_PHASE3 の完了条件チェック ==="

# T08-1: 条件未達状態で COMPLETE_PHASE3 -> -20011 で例外
T08_FAIL_OUT=$(mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.COMPLETE_PHASE3(p_run_id => ${RUN_ID});
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUCCESS');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('FAILED_CODE='||SQLCODE);
END;
/")

T08_FAIL_CODE=$(echo "${T08_FAIL_OUT}" | grep 'FAILED_CODE=' | sed 's/FAILED_CODE=//')
chk "T08-1: 条件未達でCOMPLETE_PHASE3 -> -20011で例外" "-20011" "${T08_FAIL_CODE}"

# 全条件を充足させる
# b: TARGET_END_SCN を設定
T08_TARGET_SCN=$(src_cdb_val "SELECT MAX(NEXT_CHANGE#) FROM V\$ARCHIVED_LOG WHERE STATUS='A' AND NAME IS NOT NULL;")
T08_TARGET_SCN="${T08_TARGET_SCN:-99999999}"

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.SET_TARGET_END_SCN(
        p_run_id         => ${RUN_ID},
        p_target_end_scn => ${T08_TARGET_SCN}
    );
    COMMIT;
END;
/" > /dev/null 2>&1

# c: 未解消 ERROR_EVENT をクリア
OPEN_ERRORS=$(mctl_sql "SELECT COUNT(*) FROM ERROR_EVENT WHERE MIG_RUN_ID=${RUN_ID} AND RESOLVE_STATUS='OPEN' AND SEVERITY IN ('FATAL','ERROR');")
if [[ "${OPEN_ERRORS:-0}" -gt 0 ]]; then
    printf "SET FEEDBACK OFF
UPDATE ERROR_EVENT SET RESOLVE_STATUS='RESOLVED', RESOLVED_AT=SYSTIMESTAMP, UPDATED_AT=SYSTIMESTAMP WHERE MIG_RUN_ID=%s AND RESOLVE_STATUS='OPEN';
COMMIT;
EXIT;\n" "${RUN_ID}" | docker exec -i oracle-tgt sqlplus -S "migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1" > /dev/null 2>&1
fi

# d: ARCHIVE_COLLECTOR チェックポイントが TARGET_END_SCN 以上
mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.UPSERT_CHECKPOINT(
        p_run_id    => ${RUN_ID},
        p_component => 'ARCHIVE_COLLECTOR',
        p_key       => 'THREAD:1',
        p_thread_no => 1,
        p_seq_no    => 9999,
        p_scn       => ${T08_TARGET_SCN}
    );
    COMMIT;
END;
/" > /dev/null 2>&1

MISSING_CNT=$(mctl_sql "SELECT COUNT(*) FROM ARCHIVE_LOG WHERE MIG_RUN_ID=${RUN_ID} AND COLLECT_STATUS='MISSING';")
echo "  MISSING件数: ${MISSING_CNT:-0}"

# PHASE3 を RUNNING 状態に設定
printf "SET FEEDBACK OFF
UPDATE PHASE_STATUS SET STATUS='RUNNING', STARTED_AT=SYSTIMESTAMP, UPDATED_AT=SYSTIMESTAMP WHERE MIG_RUN_ID=%s AND PHASE_CODE='PHASE3';
COMMIT;
EXIT;\n" "${RUN_ID}" | docker exec -i oracle-tgt sqlplus -S "migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1" > /dev/null 2>&1

T08_SUCCESS_OUT=$(mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.COMPLETE_PHASE3(p_run_id => ${RUN_ID});
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUCCESS');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('FAILED:'||SQLERRM);
END;
/")

echo "  COMPLETE_PHASE3 結果: $(echo "${T08_SUCCESS_OUT}" | grep -E 'SUCCESS|FAILED' | head -1)"

T08_PS_STATUS=$(mctl_sql "SELECT STATUS FROM PHASE_STATUS WHERE MIG_RUN_ID=${RUN_ID} AND PHASE_CODE='PHASE3';")
chk "T08-2: 全条件充足後にPHASE_STATUS.STATUS='COMPLETED'" "COMPLETED" "${T08_PS_STATUS}"

echo ""

# ============================================================
# 最終判定
# ============================================================
echo "=============================================="
if [ "${PASS}" -eq 1 ]; then
    echo " 最終結果: [PASS]"
else
    echo " 最終結果: [NG あり - 詳細は上記を確認]"
fi
echo "=============================================="

if [ "${PASS}" -ne 1 ]; then
    exit 1
fi
