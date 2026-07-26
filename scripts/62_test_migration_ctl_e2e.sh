#!/usr/bin/env bash
# migration_ctl スキーマ E2E 検証
# 検証対象: MIGRATION_RUN / PHASE_STATUS / MIGRATION_OBJECT の DDL・制約・FK

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

# oracle-tgt への接続（SYSDBA）- コンテナ内部では 1521
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
echo " migration_ctl スキーマ E2E 検証"
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
# &&MIGRATION_CTL_PASS を実際のパスワードに置換した一時 SQL ファイルをコンテナへ渡す
TMPDIR_MCT="/tmp/migration_ctl_setup_$$"
mkdir -p "${TMPDIR_MCT}"
sed "s/&&MIGRATION_CTL_PASS/${MIGRATION_CTL_PASS}/g" \
    "${SQL_DIR}/01_migration_ctl_user.sql" > "${TMPDIR_MCT}/01_migration_ctl_user.sql"
docker cp "${TMPDIR_MCT}/01_migration_ctl_user.sql" oracle-tgt:/tmp/01_migration_ctl_user.sql
docker exec -u oracle oracle-tgt bash -c "sqlplus -S '/ as sysdba' @/tmp/01_migration_ctl_user.sql" 2>&1

echo "  -> 02_migration_ctl_ddl.sql を実行します"
docker cp "${SQL_DIR}/02_migration_ctl_ddl.sql" oracle-tgt:/tmp/02_migration_ctl_ddl.sql
docker exec oracle-tgt bash -c "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 @/tmp/02_migration_ctl_ddl.sql" 2>&1
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
# T02: PHASE_STATUS の INSERT と制約確認
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

# 状態遷移: NOT_STARTED → RUNNING → DONE
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
UPDATE PHASE_STATUS SET STATUS = 'RUNNING', STARTED_AT = SYSTIMESTAMP, UPDATED_AT = SYSTIMESTAMP
WHERE MIG_RUN_ID = ${RUN_ID} AND PHASE_CODE = 'PREP_A';
COMMIT;" > /dev/null

STS_RUNNING=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT STATUS FROM PHASE_STATUS WHERE MIG_RUN_ID = ${RUN_ID} AND PHASE_CODE = 'PREP_A';" | grep -v "^$" | tail -1 | tr -d ' ')
chk "状態遷移 NOT_STARTED->RUNNING" "RUNNING" "${STS_RUNNING}"

mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
UPDATE PHASE_STATUS SET STATUS = 'DONE', FINISHED_AT = SYSTIMESTAMP, UPDATED_AT = SYSTIMESTAMP
WHERE MIG_RUN_ID = ${RUN_ID} AND PHASE_CODE = 'PREP_A';
COMMIT;" > /dev/null

STS_DONE=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT STATUS FROM PHASE_STATUS WHERE MIG_RUN_ID = ${RUN_ID} AND PHASE_CODE = 'PREP_A';" | grep -v "^$" | tail -1 | tr -d ' ')
chk "状態遷移 RUNNING->DONE" "DONE" "${STS_DONE}"

echo ""

# ===========================================================================
# T03: MIGRATION_OBJECT の INSERT と制約確認
# ===========================================================================
echo "[T03] MIGRATION_OBJECT INSERT・制約検証"

mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO MIGRATION_OBJECT (MIG_RUN_ID, OBJECT_SCHEMA, OBJECT_NAME, MIGRATION_METHOD, PROCESS_ORDER, EST_ROW_COUNT, EST_SIZE_MB)
VALUES (${RUN_ID}, 'SRC_SCHEMA', 'CUSTOMERS', 'FULL', 1, 10000, 50.5);
INSERT INTO MIGRATION_OBJECT (MIG_RUN_ID, OBJECT_SCHEMA, OBJECT_NAME, MIGRATION_METHOD, PROCESS_ORDER, CDC_CATALOG_TABLE_NAME)
VALUES (${RUN_ID}, 'SRC_SCHEMA', 'ORDERS', 'CDC', 2, 'ORDERS');
INSERT INTO MIGRATION_OBJECT (MIG_RUN_ID, OBJECT_SCHEMA, OBJECT_NAME, MIGRATION_METHOD, PROCESS_ORDER)
VALUES (${RUN_ID}, 'SRC_SCHEMA', 'ORDER_ITEMS', 'TRANSFORM', 3);
COMMIT;" > /dev/null

OBJ_CNT=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM MIGRATION_OBJECT WHERE MIG_RUN_ID = ${RUN_ID};" | num)
chk "MIGRATION_OBJECT 3件 INSERT" "3" "${OBJ_CNT}"

# UNIQUE 制約: 同 MIG_RUN_ID + OBJECT_SCHEMA + OBJECT_NAME → ORA-00001
UQ3_ERR=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO MIGRATION_OBJECT (MIG_RUN_ID, OBJECT_SCHEMA, OBJECT_NAME, MIGRATION_METHOD)
VALUES (${RUN_ID}, 'SRC_SCHEMA', 'CUSTOMERS', 'SKIP');
COMMIT;" 2>&1)
if echo "${UQ3_ERR}" | grep -q "ORA-00001"; then
    echo "  [OK] UNIQUE制約(MIGRATION_OBJECT): 重複オブジェクト -> ORA-00001"
else
    echo "  [NG] UNIQUE制約(MIGRATION_OBJECT): ORA-00001 が発生しなかった"
    echo "       出力: ${UQ3_ERR}"
    PASS=0
fi

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
# T05: cdc_schema との JOIN 確認
# ===========================================================================
echo "[T05] cdc_schema.cdc_table_catalog との JOIN 確認"

CDC_TABLE_EXISTS=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM all_tables
WHERE owner = 'CDC_SCHEMA' AND table_name = 'CDC_TABLE_CATALOG';" | num)

if [ "${CDC_TABLE_EXISTS}" = "1" ]; then
    echo "  -> cdc_schema.cdc_table_catalog が存在します。JOIN を実行します。"
    JOIN_RESULT=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM MIGRATION_OBJECT mo
LEFT JOIN cdc_schema.cdc_table_catalog ctc
  ON ctc.table_name = mo.CDC_CATALOG_TABLE_NAME
WHERE mo.MIG_RUN_ID = ${RUN_ID};" | num)
    if [ -n "${JOIN_RESULT}" ] && [ "${JOIN_RESULT}" -ge 0 ] 2>/dev/null; then
        echo "  [OK] cdc_schema JOIN: 結果件数=${JOIN_RESULT}"
    else
        echo "  [NG] cdc_schema JOIN: 結果取得失敗"
        PASS=0
    fi
else
    echo "  -> cdc_schema.cdc_table_catalog は存在しません。LEFT JOIN で NULL 確認します。"
    # cdc_table_catalog が存在しない場合は MIGRATION_OBJECT 単体で件数確認
    JOIN_RESULT=$(mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM MIGRATION_OBJECT mo WHERE MIG_RUN_ID = ${RUN_ID};" | num)
    chk "cdc_schema不在時のMIGRATION_OBJECT単体取得" "3" "${JOIN_RESULT}"
fi

echo ""

# ===========================================================================
# クリーンアップ: テストデータを削除
# ===========================================================================
echo "[Cleanup] テストデータ削除"
mctl_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
DELETE FROM MIGRATION_OBJECT WHERE MIG_RUN_ID IN (
    SELECT MIG_RUN_ID FROM MIGRATION_RUN WHERE RUN_NAME LIKE 'TEST-RUN-%'
);
DELETE FROM PHASE_STATUS WHERE MIG_RUN_ID IN (
    SELECT MIG_RUN_ID FROM MIGRATION_RUN WHERE RUN_NAME LIKE 'TEST-RUN-%'
);
DELETE FROM MIGRATION_RUN WHERE RUN_NAME LIKE 'TEST-RUN-%';
COMMIT;" > /dev/null
echo "  テストデータを削除しました"

echo ""
echo "=============================================="
if [ "${PASS}" = "1" ]; then
    echo "  [PASS] migration_ctl E2E 全テスト完了"
else
    echo "  [FAIL] migration_ctl E2E: 上記 [NG] を確認してください"
fi
echo "=============================================="

if [ "${PASS}" != "1" ]; then
    exit 1
fi
