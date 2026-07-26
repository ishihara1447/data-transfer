#!/usr/bin/env bash
# migration_ctl スキーマ E2E 検証 v2.0
# 検証対象: 9テーブル DDL・制約・FK + PKG_MIG_ADMIN API

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/.env"

SQL_DIR="${ROOT}/sql/migration_ctl"
PASS=1

chk() {
    if [ "$2" = "$3" ]; then
        echo "  [OK] $1"
    else
        echo "  [NG] $1: 期待='$2' 実際='$3'"
        PASS=0
    fi
}

# oracle-tgt への接続（SYSDBA）
tgt_sysdba() {
    docker exec -u oracle oracle-tgt bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
$1
SQLEOF" 2>&1
}

# oracle-tgt への migration_ctl 接続
mctl_sql() {
    docker exec oracle-tgt bash -c "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'SQLEOF'
$1
SQLEOF" 2>&1
}

num() { grep -oE '[0-9]+' | tail -1; }

echo "=============================================="
echo " migration_ctl スキーマ E2E 検証 v2.0"
echo "=============================================="
echo ""

# ===========================================================================
# セットアップ: migration_ctl ユーザーおよびテーブルの作成
# ===========================================================================
echo "[Setup] migration_ctl ユーザー確認・作成"

USER_EXISTS=$(tgt_sysdba "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT COUNT(*) FROM dba_users WHERE username = 'MIGRATION_CTL';
" | num)

if [ "${USER_EXISTS}" = "1" ]; then
    echo "  -> migration_ctl ユーザーが存在するため DROP して再作成します"
    tgt_sysdba "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
DROP USER migration_ctl CASCADE;
" > /dev/null
fi

echo "  -> 01_migration_ctl_user.sql を実行します"
TMPDIR_MCT="/tmp/migration_ctl_setup_$$"
mkdir -p "${TMPDIR_MCT}"
sed "s/&&MIGRATION_CTL_PASS/${MIGRATION_CTL_PASS}/g" \
    "${SQL_DIR}/01_migration_ctl_user.sql" > "${TMPDIR_MCT}/01_migration_ctl_user.sql"
docker cp "${TMPDIR_MCT}/01_migration_ctl_user.sql" oracle-tgt:/tmp/01_migration_ctl_user.sql
docker exec -u oracle oracle-tgt bash -c "sqlplus -S '/ as sysdba' @/tmp/01_migration_ctl_user.sql" 2>&1

echo "  -> 02_migration_ctl_ddl.sql を実行します（v2.0 9テーブル）"
docker cp "${SQL_DIR}/02_migration_ctl_ddl.sql" oracle-tgt:/tmp/02_migration_ctl_ddl.sql
docker exec oracle-tgt bash -c "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 @/tmp/02_migration_ctl_ddl.sql" 2>&1

echo "  -> 03_pkg_mig_admin.sql を実行します"
docker cp "${SQL_DIR}/03_pkg_mig_admin.sql" oracle-tgt:/tmp/03_pkg_mig_admin.sql
docker exec oracle-tgt bash -c "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 @/tmp/03_pkg_mig_admin.sql" 2>&1

rm -rf "${TMPDIR_MCT}"
echo ""
echo "  [Setup] 完了"
echo ""

# ===========================================================================
# T01: MIGRATION_RUN の INSERT と制約確認
# ===========================================================================
echo "[T01] MIGRATION_RUN INSERT・制約検証"

# 正常 INSERT
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO MIGRATION_RUN (RUN_NAME, RUN_TYPE)
VALUES ('TEST-RUN-001', 'POC');
COMMIT;" > /dev/null

# MIG_RUN_ID が採番されていること（> 0）
RUN_ID=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT MIG_RUN_ID FROM MIGRATION_RUN WHERE RUN_NAME = 'TEST-RUN-001';" | num)
if [ -n "${RUN_ID}" ] && [ "${RUN_ID}" -gt 0 ] 2>/dev/null; then
    echo "  [OK] SEQUENCE採番: MIG_RUN_ID=${RUN_ID}"
else
    echo "  [NG] SEQUENCE採番失敗: MIG_RUN_ID='${RUN_ID}'"
    PASS=0
fi

# UNIQUE 制約: 同名 INSERT → ORA-00001
UNIQUE_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO MIGRATION_RUN (RUN_NAME, RUN_TYPE)
VALUES ('TEST-RUN-001', 'POC');
COMMIT;" 2>&1)
if echo "${UNIQUE_ERR}" | grep -q "ORA-00001"; then
    echo "  [OK] UNIQUE制約: 同名INSERT -> ORA-00001"
else
    echo "  [NG] UNIQUE制約: ORA-00001 が発生しなかった"
    echo "       出力: ${UNIQUE_ERR}"
    PASS=0
fi

# CHECK 制約: 無効な RUN_TYPE → ORA-02290
CHECK_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO MIGRATION_RUN (RUN_NAME, RUN_TYPE)
VALUES ('TEST-RUN-INVALID', 'INVALID');
COMMIT;" 2>&1)
if echo "${CHECK_ERR}" | grep -q "ORA-02290"; then
    echo "  [OK] CHECK制約(RUN_TYPE): 無効値 -> ORA-02290"
else
    echo "  [NG] CHECK制約(RUN_TYPE): ORA-02290 が発生しなかった"
    echo "       出力: ${CHECK_ERR}"
    PASS=0
fi

echo ""

# ===========================================================================
# T02: PHASE_STATUS の INSERT と制約確認（状態値はCOMPLETED）
# ===========================================================================
echo "[T02] PHASE_STATUS INSERT・制約検証"

# 7フェーズ分を INSERT
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE) VALUES (${RUN_ID}, 'PREP_A');
INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE) VALUES (${RUN_ID}, 'PREP_B');
INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE) VALUES (${RUN_ID}, 'PHASE1');
INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE) VALUES (${RUN_ID}, 'PHASE2');
INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE) VALUES (${RUN_ID}, 'PHASE3');
INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE) VALUES (${RUN_ID}, 'PHASE4');
INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE) VALUES (${RUN_ID}, 'PHASE5');
COMMIT;" > /dev/null

PHASE_CNT=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM PHASE_STATUS WHERE MIG_RUN_ID = ${RUN_ID};" | num)
chk "7フェーズ INSERT 件数" "7" "${PHASE_CNT}"

# FK 制約: 存在しない MIG_RUN_ID → ORA-02291
FK_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE)
VALUES (99999999, 'PREP_A');
COMMIT;" 2>&1)
if echo "${FK_ERR}" | grep -q "ORA-02291"; then
    echo "  [OK] FK制約(PHASE_STATUS): 存在しないMIG_RUN_ID -> ORA-02291"
else
    echo "  [NG] FK制約(PHASE_STATUS): ORA-02291 が発生しなかった"
    echo "       出力: ${FK_ERR}"
    PASS=0
fi

# UNIQUE 制約: 同 MIG_RUN_ID + PHASE_CODE → ORA-00001
UQ2_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO PHASE_STATUS (MIG_RUN_ID, PHASE_CODE)
VALUES (${RUN_ID}, 'PREP_A');
COMMIT;" 2>&1)
if echo "${UQ2_ERR}" | grep -q "ORA-00001"; then
    echo "  [OK] UNIQUE制約(PHASE_STATUS): 重複PHASE_CODE -> ORA-00001"
else
    echo "  [NG] UNIQUE制約(PHASE_STATUS): ORA-00001 が発生しなかった"
    echo "       出力: ${UQ2_ERR}"
    PASS=0
fi

# 状態遷移: NOT_STARTED → RUNNING → COMPLETED（DONEではなくCOMPLETED）
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
UPDATE PHASE_STATUS SET STATUS = 'RUNNING', STARTED_AT = SYSTIMESTAMP, UPDATED_AT = SYSTIMESTAMP
WHERE MIG_RUN_ID = ${RUN_ID} AND PHASE_CODE = 'PREP_A';
COMMIT;" > /dev/null

STS_RUNNING=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT STATUS FROM PHASE_STATUS WHERE MIG_RUN_ID = ${RUN_ID} AND PHASE_CODE = 'PREP_A';" \
    | grep -v "^$" | tail -1 | tr -d ' ')
chk "状態遷移 NOT_STARTED->RUNNING" "RUNNING" "${STS_RUNNING}"

mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
UPDATE PHASE_STATUS SET STATUS = 'COMPLETED', FINISHED_AT = SYSTIMESTAMP, UPDATED_AT = SYSTIMESTAMP
WHERE MIG_RUN_ID = ${RUN_ID} AND PHASE_CODE = 'PREP_A';
COMMIT;" > /dev/null

STS_COMPLETED=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT STATUS FROM PHASE_STATUS WHERE MIG_RUN_ID = ${RUN_ID} AND PHASE_CODE = 'PREP_A';" \
    | grep -v "^$" | tail -1 | tr -d ' ')
chk "状態遷移 RUNNING->COMPLETED" "COMPLETED" "${STS_COMPLETED}"

# DONE を STATUS にセットしようとすると ORA-02290
DONE_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
UPDATE PHASE_STATUS SET STATUS = 'DONE'
WHERE MIG_RUN_ID = ${RUN_ID} AND PHASE_CODE = 'PREP_A';
COMMIT;" 2>&1)
if echo "${DONE_ERR}" | grep -q "ORA-02290"; then
    echo "  [OK] CHECK制約(PHASE_STATUS STATUS): DONE -> ORA-02290"
else
    echo "  [NG] CHECK制約(PHASE_STATUS STATUS): DONE が拒否されなかった"
    echo "       出力: ${DONE_ERR}"
    PASS=0
fi

echo ""

# ===========================================================================
# T03: MIGRATION_OBJECT の INSERT と制約確認（v2.0 列定義）
# ===========================================================================
echo "[T03] MIGRATION_OBJECT INSERT・制約検証（v2.0）"

mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO MIGRATION_OBJECT (
    MIG_RUN_ID, SOURCE_OWNER, SOURCE_TABLE_NAME,
    FULL_LOAD_FLAG, APPLY_ORDER_NO, ESTIMATED_ROWS, ESTIMATED_DATA_BYTES
) VALUES (${RUN_ID}, 'SRC_SCHEMA', 'CUSTOMERS', 'Y', 1, 10000, 52428800);
INSERT INTO MIGRATION_OBJECT (
    MIG_RUN_ID, SOURCE_OWNER, SOURCE_TABLE_NAME,
    FULL_LOAD_FLAG, CDC_FLAG, APPLY_ORDER_NO
) VALUES (${RUN_ID}, 'SRC_SCHEMA', 'ORDERS', 'Y', 'Y', 2);
INSERT INTO MIGRATION_OBJECT (
    MIG_RUN_ID, SOURCE_OWNER, SOURCE_TABLE_NAME,
    FULL_LOAD_FLAG, CDC_FLAG, TRANSFORM_FLAG, APPLY_ORDER_NO
) VALUES (${RUN_ID}, 'SRC_SCHEMA', 'ORDER_ITEMS', 'Y', 'Y', 'Y', 3);
COMMIT;" > /dev/null

OBJ_CNT=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM MIGRATION_OBJECT WHERE MIG_RUN_ID = ${RUN_ID};" | num)
chk "MIGRATION_OBJECT 3件 INSERT" "3" "${OBJ_CNT}"

# UNIQUE 制約: 同 MIG_RUN_ID + SOURCE_OWNER + SOURCE_TABLE_NAME → ORA-00001
UQ3_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO MIGRATION_OBJECT (MIG_RUN_ID, SOURCE_OWNER, SOURCE_TABLE_NAME)
VALUES (${RUN_ID}, 'SRC_SCHEMA', 'CUSTOMERS');
COMMIT;" 2>&1)
if echo "${UQ3_ERR}" | grep -q "ORA-00001"; then
    echo "  [OK] UNIQUE制約(MIGRATION_OBJECT): 重複オブジェクト -> ORA-00001"
else
    echo "  [NG] UNIQUE制約(MIGRATION_OBJECT): ORA-00001 が発生しなかった"
    echo "       出力: ${UQ3_ERR}"
    PASS=0
fi

# MIG_OBJECT_ID を取得（以降のテストで使用）
MIG_OBJECT_ID=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT MIG_OBJECT_ID FROM MIGRATION_OBJECT
WHERE MIG_RUN_ID = ${RUN_ID} AND SOURCE_TABLE_NAME = 'CUSTOMERS';" | num)

echo ""

# ===========================================================================
# T04: CHK_MIG_RUN_SCN チェック制約
# ===========================================================================
echo "[T04] CHK_MIG_RUN_SCN チェック制約検証"

# OK: MINING_START_SCN(500) <= BASELINE_SCN(1000)
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO MIGRATION_RUN (RUN_NAME, RUN_TYPE, BASELINE_SCN, MINING_START_SCN)
VALUES ('TEST-RUN-SCN-OK', 'POC', 1000, 500);
COMMIT;" > /dev/null
SCN_OK_CNT=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM MIGRATION_RUN WHERE RUN_NAME = 'TEST-RUN-SCN-OK';" | num)
chk "SCN制約OK(500<=1000) INSERT成功" "1" "${SCN_OK_CNT}"

# NG: MINING_START_SCN(2000) > BASELINE_SCN(1000) → ORA-02290
SCN_NG_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO MIGRATION_RUN (RUN_NAME, RUN_TYPE, BASELINE_SCN, MINING_START_SCN)
VALUES ('TEST-RUN-SCN-NG', 'POC', 1000, 2000);
COMMIT;" 2>&1)
if echo "${SCN_NG_ERR}" | grep -q "ORA-02290"; then
    echo "  [OK] CHK_MIG_RUN_SCN: MINING_START>BASELINE -> ORA-02290"
else
    echo "  [NG] CHK_MIG_RUN_SCN: ORA-02290 が発生しなかった"
    echo "       出力: ${SCN_NG_ERR}"
    PASS=0
fi

echo ""

# ===========================================================================
# T05: DATAPUMP_JOB + DATAPUMP_JOB_OBJECT + DATAPUMP_FILE の結合テスト
# ===========================================================================
echo "[T05] DATAPUMP_JOB + DATAPUMP_JOB_OBJECT + DATAPUMP_FILE 結合テスト"

# DATAPUMP_JOB に EXPORT ジョブを INSERT
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO DATAPUMP_JOB (MIG_RUN_ID, JOB_NAME, OPERATION)
VALUES (${RUN_ID}, 'TEST_EXPORT_JOB_001', 'EXPORT');
COMMIT;" > /dev/null

DP_JOB_ID=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT DATAPUMP_JOB_ID FROM DATAPUMP_JOB
WHERE JOB_NAME = 'TEST_EXPORT_JOB_001';" | num)
if [ -n "${DP_JOB_ID}" ] && [ "${DP_JOB_ID}" -gt 0 ] 2>/dev/null; then
    echo "  [OK] DATAPUMP_JOB INSERT: DATAPUMP_JOB_ID=${DP_JOB_ID}"
else
    echo "  [NG] DATAPUMP_JOB INSERT 失敗"
    PASS=0
fi

# DATAPUMP_JOB_OBJECT に対応を INSERT
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO DATAPUMP_JOB_OBJECT (DATAPUMP_JOB_ID, MIG_OBJECT_ID)
VALUES (${DP_JOB_ID}, ${MIG_OBJECT_ID});
COMMIT;" > /dev/null

DP_JO_CNT=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM DATAPUMP_JOB_OBJECT WHERE DATAPUMP_JOB_ID = ${DP_JOB_ID};" | num)
chk "DATAPUMP_JOB_OBJECT INSERT 件数" "1" "${DP_JO_CNT}"

# DATAPUMP_FILE にダンプファイルを INSERT（STATUS='EXPECTED'）
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO DATAPUMP_FILE (
    MIG_RUN_ID, DATAPUMP_JOB_ID, FILE_ROLE, STATUS, FILE_NAME
) VALUES (${RUN_ID}, ${DP_JOB_ID}, 'DUMP', 'EXPECTED', 'exp_001.dmp');
COMMIT;" > /dev/null

DP_FILE_CNT=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM DATAPUMP_FILE WHERE MIG_RUN_ID = ${RUN_ID};" | num)
chk "DATAPUMP_FILE INSERT 件数" "1" "${DP_FILE_CNT}"

# FK制約確認: 存在しないジョブIDへの DATAPUMP_JOB_OBJECT INSERT → ORA-02291
FK_DP_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO DATAPUMP_JOB_OBJECT (DATAPUMP_JOB_ID, MIG_OBJECT_ID)
VALUES (99999999, ${MIG_OBJECT_ID});
COMMIT;" 2>&1)
if echo "${FK_DP_ERR}" | grep -q "ORA-02291"; then
    echo "  [OK] FK制約(DATAPUMP_JOB_OBJECT): 存在しないJOB_ID -> ORA-02291"
else
    echo "  [NG] FK制約(DATAPUMP_JOB_OBJECT): ORA-02291 が発生しなかった"
    echo "       出力: ${FK_DP_ERR}"
    PASS=0
fi

echo ""

# ===========================================================================
# T06: ARCHIVE_LOG + ARCHIVE_LOG_COPY の論理/物理分離テスト
# ===========================================================================
echo "[T06] ARCHIVE_LOG + ARCHIVE_LOG_COPY 論理/物理分離テスト"

# ARCHIVE_LOG に THREAD_NO=1/SEQUENCE_NO=100 のログを INSERT
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO ARCHIVE_LOG (
    MIG_RUN_ID, SOURCE_RESETLOGS_ID, THREAD_NO, SEQUENCE_NO,
    FIRST_CHANGE_SCN, NEXT_CHANGE_SCN, COLLECT_STATUS
) VALUES (${RUN_ID}, 12345678, 1, 100, 900000, 910000, 'EXPECTED');
COMMIT;" > /dev/null

ARCHIVE_LOG_ID=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT ARCHIVE_LOG_ID FROM ARCHIVE_LOG
WHERE MIG_RUN_ID = ${RUN_ID} AND THREAD_NO = 1 AND SEQUENCE_NO = 100;" | num)
if [ -n "${ARCHIVE_LOG_ID}" ] && [ "${ARCHIVE_LOG_ID}" -gt 0 ] 2>/dev/null; then
    echo "  [OK] ARCHIVE_LOG INSERT: ARCHIVE_LOG_ID=${ARCHIVE_LOG_ID}"
else
    echo "  [NG] ARCHIVE_LOG INSERT 失敗"
    PASS=0
fi

# ARCHIVE_LOG_COPY に2行 INSERT（論理1行に対して物理2コピー）
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO ARCHIVE_LOG_COPY (
    ARCHIVE_LOG_ID, MIG_RUN_ID, STORAGE_LOCATION, FILE_PATH, COPY_STATUS
) VALUES (${ARCHIVE_LOG_ID}, ${RUN_ID}, 'MIGRATION_FILE_SERVER',
    '/mig_server/redo/thread1_seq100.arc', 'EXPECTED');
INSERT INTO ARCHIVE_LOG_COPY (
    ARCHIVE_LOG_ID, MIG_RUN_ID, STORAGE_LOCATION, FILE_PATH, COPY_STATUS
) VALUES (${ARCHIVE_LOG_ID}, ${RUN_ID}, '8TB_SSD',
    '/ssd/redo/thread1_seq100.arc', 'EXPECTED');
COMMIT;" > /dev/null

ALC_CNT=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM ARCHIVE_LOG_COPY WHERE ARCHIVE_LOG_ID = ${ARCHIVE_LOG_ID};" | num)
chk "ARCHIVE_LOG_COPY 2行 INSERT（物理2コピー）" "2" "${ALC_CNT}"

# ARCHIVE_LOG_COPY_IDを取得（以降のT11で使用。MIGRATION_FILE_SERVER行）
ALC_ID1=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT ARCHIVE_LOG_COPY_ID FROM ARCHIVE_LOG_COPY
WHERE ARCHIVE_LOG_ID = ${ARCHIVE_LOG_ID} AND STORAGE_LOCATION = 'MIGRATION_FILE_SERVER';" | num)

# ARCHIVE_LOG_COPY_IDを取得（以降のT11で使用。8TB_SSD行）
ALC_ID2=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT ARCHIVE_LOG_COPY_ID FROM ARCHIVE_LOG_COPY
WHERE ARCHIVE_LOG_ID = ${ARCHIVE_LOG_ID} AND STORAGE_LOCATION = '8TB_SSD';" | num)

# UNIQUE制約確認: 同一 MIG_RUN_ID+RESETLOGS_ID+THREAD_NO+SEQUENCE_NO → ORA-00001
UQ_ARC_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO ARCHIVE_LOG (
    MIG_RUN_ID, SOURCE_RESETLOGS_ID, THREAD_NO, SEQUENCE_NO, COLLECT_STATUS
) VALUES (${RUN_ID}, 12345678, 1, 100, 'EXPECTED');
COMMIT;" 2>&1)
if echo "${UQ_ARC_ERR}" | grep -q "ORA-00001"; then
    echo "  [OK] UNIQUE制約(ARCHIVE_LOG): 重複THREAD+SEQ -> ORA-00001"
else
    echo "  [NG] UNIQUE制約(ARCHIVE_LOG): ORA-00001 が発生しなかった"
    echo "       出力: ${UQ_ARC_ERR}"
    PASS=0
fi

echo ""

# ===========================================================================
# T07: MIG_STATUS_HISTORY 追記テスト
# ===========================================================================
echo "[T07] MIG_STATUS_HISTORY 追記テスト"

mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO MIG_STATUS_HISTORY (
    MIG_RUN_ID, TABLE_NAME, RECORD_ID, OLD_STATUS, NEW_STATUS, CHANGED_BY
) VALUES (${RUN_ID}, 'MIGRATION_RUN', ${RUN_ID}, NULL, 'CREATED', USER);
INSERT INTO MIG_STATUS_HISTORY (
    MIG_RUN_ID, TABLE_NAME, RECORD_ID, OLD_STATUS, NEW_STATUS, CHANGED_BY,
    NOTE
) VALUES (${RUN_ID}, 'PHASE_STATUS', ${RUN_ID}, 'NOT_STARTED', 'RUNNING', USER,
    'T07テスト用記録');
COMMIT;" > /dev/null

HIST_CNT=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM MIG_STATUS_HISTORY WHERE MIG_RUN_ID = ${RUN_ID};" | num)
if [ -n "${HIST_CNT}" ] && [ "${HIST_CNT}" -gt 0 ] 2>/dev/null; then
    echo "  [OK] MIG_STATUS_HISTORY INSERT: 記録件数=${HIST_CNT}"
else
    echo "  [NG] MIG_STATUS_HISTORY INSERT 失敗: 記録件数='${HIST_CNT}'"
    PASS=0
fi

echo ""

# ===========================================================================
# T08: PKG_MIG_ADMIN.CREATE_RUN テスト
# ===========================================================================
echo "[T08] PKG_MIG_ADMIN.CREATE_RUN テスト"

PKG_RUN_ID=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
DECLARE
  v_run_id NUMBER;
BEGIN
  PKG_MIG_ADMIN.CREATE_RUN(
    p_run_name       => 'TEST-PKG-RUN-001',
    p_run_type       => 'POC',
    p_source_db_info => NULL,
    p_target_db_info => NULL,
    p_run_id         => v_run_id
  );
  DBMS_OUTPUT.PUT_LINE('RUN_ID:' || v_run_id);
END;
/" | grep 'RUN_ID:' | grep -oE '[0-9]+')

if [ -n "${PKG_RUN_ID}" ] && [ "${PKG_RUN_ID}" -gt 0 ] 2>/dev/null; then
    echo "  [OK] CREATE_RUN: PKG_RUN_ID=${PKG_RUN_ID}"
else
    echo "  [NG] CREATE_RUN 失敗: PKG_RUN_ID='${PKG_RUN_ID}'"
    PASS=0
fi

# MIGRATION_RUN に1行作成されること（STATUS='CREATED'）
PKG_RUN_STATUS=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT STATUS FROM MIGRATION_RUN WHERE MIG_RUN_ID = ${PKG_RUN_ID:-0};" \
    | grep -v "^$" | tail -1 | tr -d ' ')
chk "CREATE_RUN: MIGRATION_RUN STATUS=CREATED" "CREATED" "${PKG_RUN_STATUS}"

# PHASE_STATUS に7行作成されること（全行 NOT_STARTED）
PKG_PHASE_CNT=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM PHASE_STATUS WHERE MIG_RUN_ID = ${PKG_RUN_ID:-0};" | num)
chk "CREATE_RUN: PHASE_STATUS 7行作成" "7" "${PKG_PHASE_CNT}"

# NOT_STARTEDが7行あること
PKG_NS_CNT=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM PHASE_STATUS
WHERE MIG_RUN_ID = ${PKG_RUN_ID:-0} AND STATUS = 'NOT_STARTED';" | num)
chk "CREATE_RUN: PHASE_STATUS 全行NOT_STARTED" "7" "${PKG_NS_CNT}"

# MIG_STATUS_HISTORY に記録があること
PKG_HIST_CNT=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM MIG_STATUS_HISTORY WHERE MIG_RUN_ID = ${PKG_RUN_ID:-0};" | num)
if [ -n "${PKG_HIST_CNT}" ] && [ "${PKG_HIST_CNT}" -gt 0 ] 2>/dev/null; then
    echo "  [OK] CREATE_RUN: MIG_STATUS_HISTORY 記録あり(${PKG_HIST_CNT}件)"
else
    echo "  [NG] CREATE_RUN: MIG_STATUS_HISTORY 記録なし"
    PASS=0
fi

echo ""

# ===========================================================================
# T09: PKG_MIG_ADMIN.FIX_BASELINE_SCN テスト
# ===========================================================================
echo "[T09] PKG_MIG_ADMIN.FIX_BASELINE_SCN テスト"

mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN
  PKG_MIG_ADMIN.FIX_BASELINE_SCN(
    p_run_id       => ${PKG_RUN_ID:-0},
    p_baseline_scn => 1000000
  );
END;
/" > /dev/null

# STATUS='BASELINE_FIXED', BASELINE_SCN=1000000 になること
FIXED_SCN=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT BASELINE_SCN FROM MIGRATION_RUN WHERE MIG_RUN_ID = ${PKG_RUN_ID:-0};" | num)
chk "FIX_BASELINE_SCN: BASELINE_SCN=1000000" "1000000" "${FIXED_SCN}"

FIXED_STS=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT STATUS FROM MIGRATION_RUN WHERE MIG_RUN_ID = ${PKG_RUN_ID:-0};" \
    | grep -v "^$" | tail -1 | tr -d ' ')
chk "FIX_BASELINE_SCN: STATUS=BASELINE_FIXED" "BASELINE_FIXED" "${FIXED_STS}"

# 2回目の FIX_BASELINE_SCN で ORA-20001 が発生すること
OVERWRITE_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN
  PKG_MIG_ADMIN.FIX_BASELINE_SCN(
    p_run_id       => ${PKG_RUN_ID:-0},
    p_baseline_scn => 2000000
  );
END;
/" 2>&1)
if echo "${OVERWRITE_ERR}" | grep -q "ORA-20001"; then
    echo "  [OK] FIX_BASELINE_SCN 2回目: 上書き禁止 -> ORA-20001"
else
    echo "  [NG] FIX_BASELINE_SCN 2回目: ORA-20001 が発生しなかった"
    echo "       出力: ${OVERWRITE_ERR}"
    PASS=0
fi

echo ""

# ===========================================================================
# T10: PKG_MIG_ADMIN.START_DATAPUMP_JOB / COMPLETE_DATAPUMP_JOB テスト
# ===========================================================================
echo "[T10] PKG_MIG_ADMIN.START_DATAPUMP_JOB / COMPLETE_DATAPUMP_JOB テスト"

# PKG_RUN_ID用のジョブを INSERT
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO DATAPUMP_JOB (MIG_RUN_ID, JOB_NAME, OPERATION)
VALUES (${PKG_RUN_ID:-0}, 'PKG_TEST_EXPORT_JOB', 'EXPORT');
COMMIT;" > /dev/null

PKG_DP_JOB_ID=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT DATAPUMP_JOB_ID FROM DATAPUMP_JOB
WHERE JOB_NAME = 'PKG_TEST_EXPORT_JOB';" | num)

# START_DATAPUMP_JOB: PLANNED → RUNNING
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN
  PKG_MIG_ADMIN.START_DATAPUMP_JOB(p_job_id => ${PKG_DP_JOB_ID:-0});
END;
/" > /dev/null

START_STS=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT STATUS FROM DATAPUMP_JOB WHERE DATAPUMP_JOB_ID = ${PKG_DP_JOB_ID:-0};" \
    | grep -v "^$" | tail -1 | tr -d ' ')
chk "START_DATAPUMP_JOB: STATUS=RUNNING" "RUNNING" "${START_STS}"

# COMPLETE_DATAPUMP_JOB: RUNNING → COMPLETED
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN
  PKG_MIG_ADMIN.COMPLETE_DATAPUMP_JOB(
    p_job_id      => ${PKG_DP_JOB_ID:-0},
    p_rows        => 100,
    p_bytes       => 1048576,
    p_error_count => 0
  );
END;
/" > /dev/null

COMP_STS=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT STATUS FROM DATAPUMP_JOB WHERE DATAPUMP_JOB_ID = ${PKG_DP_JOB_ID:-0};" \
    | grep -v "^$" | tail -1 | tr -d ' ')
chk "COMPLETE_DATAPUMP_JOB: STATUS=COMPLETED" "COMPLETED" "${COMP_STS}"

COMP_ROWS=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT PROCESSED_ROWS FROM DATAPUMP_JOB WHERE DATAPUMP_JOB_ID = ${PKG_DP_JOB_ID:-0};" | num)
chk "COMPLETE_DATAPUMP_JOB: PROCESSED_ROWS=100" "100" "${COMP_ROWS}"

# 不正な状態からの START_DATAPUMP_JOB（COMPLETED→RUNNING）で ORA-20002
INVALID_START_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN
  PKG_MIG_ADMIN.START_DATAPUMP_JOB(p_job_id => ${PKG_DP_JOB_ID:-0});
END;
/" 2>&1)
if echo "${INVALID_START_ERR}" | grep -q "ORA-20002"; then
    echo "  [OK] START_DATAPUMP_JOB(COMPLETED): 不正遷移 -> ORA-20002"
else
    echo "  [NG] START_DATAPUMP_JOB(COMPLETED): ORA-20002 が発生しなかった"
    echo "       出力: ${INVALID_START_ERR}"
    PASS=0
fi

echo ""

# ===========================================================================
# T11: PKG_MIG_ADMIN.VERIFY_ARCHIVE_LOG_COPY テスト
# ===========================================================================
echo "[T11] PKG_MIG_ADMIN.VERIFY_ARCHIVE_LOG_COPY テスト"

# T06で作成したARCHIVE_LOG/ARCHIVE_LOG_COPYを準備
# ARCHIVE_LOG.COLLECT_STATUS を RECEIVED に更新
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
UPDATE ARCHIVE_LOG
SET COLLECT_STATUS = 'RECEIVED', UPDATED_AT = SYSTIMESTAMP
WHERE ARCHIVE_LOG_ID = ${ARCHIVE_LOG_ID:-0};
COMMIT;" > /dev/null

# ARCHIVE_LOG_COPY (ALC_ID1) を RECEIVED に更新
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
UPDATE ARCHIVE_LOG_COPY
SET COPY_STATUS = 'RECEIVED', RECEIVED_AT = SYSTIMESTAMP, UPDATED_AT = SYSTIMESTAMP
WHERE ARCHIVE_LOG_COPY_ID = ${ALC_ID1:-0};
COMMIT;" > /dev/null

# VERIFY_ARCHIVE_LOG_COPY を呼び出す（1件目コピー）
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN
  PKG_MIG_ADMIN.VERIFY_ARCHIVE_LOG_COPY(
    p_copy_id  => ${ALC_ID1:-0},
    p_checksum => 'sha256:abc123def456'
  );
END;
/" > /dev/null

# COPY_STATUS = 'VERIFIED' になること
COPY_STS=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COPY_STATUS FROM ARCHIVE_LOG_COPY
WHERE ARCHIVE_LOG_COPY_ID = ${ALC_ID1:-0};" \
    | grep -v "^$" | tail -1 | tr -d ' ')
chk "VERIFY_ARCHIVE_LOG_COPY(1件目): COPY_STATUS=VERIFIED" "VERIFIED" "${COPY_STS}"

# CHECKSUM_VALUE が記録されること
COPY_CHK=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT CHECKSUM_VALUE FROM ARCHIVE_LOG_COPY
WHERE ARCHIVE_LOG_COPY_ID = ${ALC_ID1:-0};" \
    | grep -v "^$" | tail -1 | tr -d ' ')
chk "VERIFY_ARCHIVE_LOG_COPY(1件目): CHECKSUM記録" "sha256:abc123def456" "${COPY_CHK}"

# 1件目VERIFYの直後: 2件目(8TB_SSD)がまだEXPECTEDのためARCHIVE_LOGはまだVERIFIEDでないこと
COLLECT_STS_BEFORE=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COLLECT_STATUS FROM ARCHIVE_LOG
WHERE ARCHIVE_LOG_ID = ${ARCHIVE_LOG_ID:-0};" \
    | grep -v "^$" | tail -1 | tr -d ' ')
if [ "${COLLECT_STS_BEFORE}" != "VERIFIED" ]; then
    echo "  [OK] VERIFY_ARCHIVE_LOG_COPY(1件目後): ARCHIVE_LOG はまだ VERIFIED でない(${COLLECT_STS_BEFORE})"
else
    echo "  [NG] VERIFY_ARCHIVE_LOG_COPY(1件目後): 全コピーVERIFY前なのに ARCHIVE_LOG が VERIFIED になった"
    PASS=0
fi

# ARCHIVE_LOG_COPY (ALC_ID2) を RECEIVED に更新して VERIFY
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
UPDATE ARCHIVE_LOG_COPY
SET COPY_STATUS = 'RECEIVED', RECEIVED_AT = SYSTIMESTAMP, UPDATED_AT = SYSTIMESTAMP
WHERE ARCHIVE_LOG_COPY_ID = ${ALC_ID2:-0};
COMMIT;" > /dev/null

mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN
  PKG_MIG_ADMIN.VERIFY_ARCHIVE_LOG_COPY(
    p_copy_id  => ${ALC_ID2:-0},
    p_checksum => 'sha256:xyz789def456'
  );
END;
/" > /dev/null

# 2件目VERIFYの後: 全コピーVERIFIED → ARCHIVE_LOG.COLLECT_STATUS=VERIFIED になること
COLLECT_STS=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COLLECT_STATUS FROM ARCHIVE_LOG
WHERE ARCHIVE_LOG_ID = ${ARCHIVE_LOG_ID:-0};" \
    | grep -v "^$" | tail -1 | tr -d ' ')
chk "VERIFY_ARCHIVE_LOG_COPY(全コピーVERIFY後): ARCHIVE_LOG.COLLECT_STATUS=VERIFIED" "VERIFIED" "${COLLECT_STS}"

# MIG_STATUS_HISTORY に記録があること
VER_HIST=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM MIG_STATUS_HISTORY
WHERE TABLE_NAME = 'ARCHIVE_LOG_COPY' AND NEW_STATUS = 'VERIFIED';" | num)
if [ -n "${VER_HIST}" ] && [ "${VER_HIST}" -gt 0 ] 2>/dev/null; then
    echo "  [OK] VERIFY_ARCHIVE_LOG_COPY: MIG_STATUS_HISTORY 記録あり"
else
    echo "  [NG] VERIFY_ARCHIVE_LOG_COPY: MIG_STATUS_HISTORY 記録なし"
    PASS=0
fi

echo ""

# ===========================================================================
# T12: SCN_BOUNDARY 確認SQL + MARK_ARCHIVE_READY テスト
# ===========================================================================
echo "[T12] SCN_BOUNDARY 確認SQL + MARK_ARCHIVE_READY テスト"

# ARCHIVE_LOG が1件以上存在することを確認
ARC_LOG_CNT=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM ARCHIVE_LOG WHERE MIG_RUN_ID = ${RUN_ID};" | num)
if [ -n "${ARC_LOG_CNT}" ] && [ "${ARC_LOG_CNT}" -gt 0 ] 2>/dev/null; then
    echo "  [OK] ARCHIVE_LOG件数確認: MIG_RUN_ID=${RUN_ID} -> ${ARC_LOG_CNT}件"
else
    echo "  [NG] ARCHIVE_LOG件数確認: 0件"
    PASS=0
fi

# MARK_ARCHIVE_READY を呼び出す（T06でARCHIVE_LOGを作成済みのRUN_IDを使用）
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN
  PKG_MIG_ADMIN.MARK_ARCHIVE_READY(p_run_id => ${RUN_ID});
END;
/" > /dev/null

ARCH_RDY_STS=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT STATUS FROM MIGRATION_RUN WHERE MIG_RUN_ID = ${RUN_ID};" \
    | grep -v "^$" | tail -1 | tr -d ' ')
chk "MARK_ARCHIVE_READY: STATUS=ARCHIVE_READY" "ARCHIVE_READY" "${ARCH_RDY_STS}"

# ARCHIVE_READYのタイムスタンプが記録されること
ARCH_TS=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM MIGRATION_RUN
WHERE MIG_RUN_ID = ${RUN_ID} AND ARCHIVE_READY_AT IS NOT NULL;" | num)
chk "MARK_ARCHIVE_READY: ARCHIVE_READY_AT 記録" "1" "${ARCH_TS}"

# ARCHIVE_LOGが0件のRUNへの呼び出しは ORA-20003（PKG_RUN_IDはARCHIVE_LOG 0件）
NO_LOG_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN
  PKG_MIG_ADMIN.MARK_ARCHIVE_READY(p_run_id => ${PKG_RUN_ID:-0});
END;
/" 2>&1)
if echo "${NO_LOG_ERR}" | grep -q "ORA-20003"; then
    echo "  [OK] MARK_ARCHIVE_READY(カバレッジ不足): -> ORA-20003"
else
    echo "  [NG] MARK_ARCHIVE_READY(カバレッジ不足): ORA-20003 が発生しなかった"
    echo "       出力: ${NO_LOG_ERR}"
    PASS=0
fi

echo ""

# ===========================================================================
# T13: PKG_MIG_ADMIN.FAIL_DATAPUMP_JOB テスト
# ===========================================================================
echo "[T13] PKG_MIG_ADMIN.FAIL_DATAPUMP_JOB テスト"

# 新しいジョブを PLANNED で INSERT
FAIL_JOB_ID=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO DATAPUMP_JOB (MIG_RUN_ID, JOB_NAME, OPERATION)
VALUES (${RUN_ID}, 'TEST-FAIL-JOB', 'EXPORT');
COMMIT;
SELECT DATAPUMP_JOB_ID FROM DATAPUMP_JOB WHERE JOB_NAME = 'TEST-FAIL-JOB';" | num)
chk "FAIL_JOB INSERT" "1" "$([ -n "${FAIL_JOB_ID}" ] && [ "${FAIL_JOB_ID}" -gt 0 ] 2>/dev/null && echo "1" || echo "0")"

# RUNNING にしてから FAIL
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN PKG_MIG_ADMIN.START_DATAPUMP_JOB(${FAIL_JOB_ID}); END;
/" > /dev/null

mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN PKG_MIG_ADMIN.FAIL_DATAPUMP_JOB(${FAIL_JOB_ID}, 'ORA-12345: テストエラー'); END;
/" > /dev/null

FAIL_STS=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT STATUS FROM DATAPUMP_JOB WHERE DATAPUMP_JOB_ID = ${FAIL_JOB_ID};" | grep -v "^$" | tail -1 | tr -d ' ')
chk "FAIL_DATAPUMP_JOB: STATUS=FAILED" "FAILED" "${FAIL_STS}"

FAIL_REMARKS=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT REMARKS FROM DATAPUMP_JOB WHERE DATAPUMP_JOB_ID = ${FAIL_JOB_ID};" | grep -v "^$" | tail -1)
if echo "${FAIL_REMARKS}" | grep -q "ORA-12345"; then
    echo "  [OK] FAIL_DATAPUMP_JOB: REMARKS にエラーメッセージ記録"
else
    echo "  [NG] FAIL_DATAPUMP_JOB: REMARKS にエラーメッセージなし: '${FAIL_REMARKS}'"
    PASS=0
fi

# COMPLETED状態のジョブ(T10のPKG_DP_JOB_ID)に FAIL → ORA-20002
FAIL_COMPLETED_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN PKG_MIG_ADMIN.FAIL_DATAPUMP_JOB(${PKG_DP_JOB_ID:-0}, 'should fail'); END;
/" 2>&1)
if echo "${FAIL_COMPLETED_ERR}" | grep -q "ORA-20002"; then
    echo "  [OK] FAIL_DATAPUMP_JOB(COMPLETED): 不正遷移 -> ORA-20002"
else
    echo "  [NG] FAIL_DATAPUMP_JOB(COMPLETED): ORA-20002 が発生しなかった"
    echo "       出力: ${FAIL_COMPLETED_ERR}"
    PASS=0
fi

echo ""

# ===========================================================================
# T14: PKG_MIG_ADMIN.SET_TARGET_END_SCN テスト
# ===========================================================================
echo "[T14] PKG_MIG_ADMIN.SET_TARGET_END_SCN テスト"

# T08で作成したPKG_RUN_IDに対してSET_TARGET_END_SCN
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN PKG_MIG_ADMIN.SET_TARGET_END_SCN(${PKG_RUN_ID}, 9999999); END;
/" > /dev/null

TES_SCN=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT TARGET_END_SCN FROM MIGRATION_RUN WHERE MIG_RUN_ID = ${PKG_RUN_ID};" | num)
chk "SET_TARGET_END_SCN: TARGET_END_SCN=9999999" "9999999" "${TES_SCN}"

# 2回目の SET_TARGET_END_SCN → ORA-20001（上書き禁止）
TES_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN PKG_MIG_ADMIN.SET_TARGET_END_SCN(${PKG_RUN_ID}, 8888888); END;
/" 2>&1)
if echo "${TES_ERR}" | grep -q "ORA-20001"; then
    echo "  [OK] SET_TARGET_END_SCN 2回目: 上書き禁止 -> ORA-20001"
else
    echo "  [NG] SET_TARGET_END_SCN 2回目: ORA-20001 が発生しなかった"
    echo "       出力: ${TES_ERR}"
    PASS=0
fi

echo ""

# ===========================================================================
# T15: PKG_MIG_ADMIN.UPDATE_LAST_APPLIED_SCN テスト
# ===========================================================================
echo "[T15] PKG_MIG_ADMIN.UPDATE_LAST_APPLIED_SCN テスト"

# 前進するSCN → 正常
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN PKG_MIG_ADMIN.UPDATE_LAST_APPLIED_SCN(${PKG_RUN_ID}, 5000000); END;
/" > /dev/null

LAST_SCN=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT LAST_APPLIED_SCN FROM MIGRATION_RUN WHERE MIG_RUN_ID = ${PKG_RUN_ID};" | num)
chk "UPDATE_LAST_APPLIED_SCN: LAST_APPLIED_SCN=5000000" "5000000" "${LAST_SCN}"

# SCN後退 → ORA-20004
RETREAT_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN PKG_MIG_ADMIN.UPDATE_LAST_APPLIED_SCN(${PKG_RUN_ID}, 4000000); END;
/" 2>&1)
if echo "${RETREAT_ERR}" | grep -q "ORA-20004"; then
    echo "  [OK] UPDATE_LAST_APPLIED_SCN(後退): -> ORA-20004"
else
    echo "  [NG] UPDATE_LAST_APPLIED_SCN(後退): ORA-20004 が発生しなかった"
    echo "       出力: ${RETREAT_ERR}"
    PASS=0
fi

# 前進するSCN（5000001）→ 正常
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
BEGIN PKG_MIG_ADMIN.UPDATE_LAST_APPLIED_SCN(${PKG_RUN_ID}, 5000001); END;
/" > /dev/null

LAST_SCN2=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT LAST_APPLIED_SCN FROM MIGRATION_RUN WHERE MIG_RUN_ID = ${PKG_RUN_ID};" | num)
chk "UPDATE_LAST_APPLIED_SCN(前進5000001): 正常更新" "5000001" "${LAST_SCN2}"

echo ""

# ===========================================================================
# 最終結果サマリ
# （次回実行時に DROP USER CASCADE で再初期化されるためクリーンアップ不要）
# ===========================================================================
echo "=============================================="
if [ "${PASS}" = "1" ]; then
    echo "  [PASS] migration_ctl E2E 全テスト完了 (T01-T15)"
else
    echo "  [FAIL] migration_ctl E2E: 上記 [NG] を確認してください"
fi
echo "=============================================="

if [ "${PASS}" != "1" ]; then
    exit 1
fi
