#!/usr/bin/env bash
# フェーズ4 段1 E2E 検証
# T01-T15: 管理テーブル制約確認 / Phase4 API ライフサイクル / バルク登録 / 回帰テスト
#
# 前提: oracle-src / oracle-tgt 稼働中
#       scripts/62_test_migration_ctl_e2e.sh が PASS であること（フレッシュ構築済み）
# 注意: DROP USER migration_ctl CASCADE を使用しない
#       毎実行で新規 MIG_RUN_ID を発行してテスト分離する
#
# 既知ノウハウ（docs/phase3-design.md §6.5 より）:
# - sqlplus PL/SQL ブロックの "/" は必ず独立した行に置くこと
# - ALTER SESSION SET CONTAINER の後で SET SERVEROUTPUT ON を再設定すること
# - mctl_sql_raw は printf | docker exec -i ... sqlplus パイプ方式を使う

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

echo "=============================================="
echo " Phase 4 段1 E2E 検証 (T01-T15)"
echo "=============================================="
echo ""

# ============================================================
# Setup: テスト用 RUN_ID 発行
# ============================================================
echo "[Setup] フェーズ4テスト用 MIG_RUN を作成"

RUN_TS=$(date +%Y%m%d%H%M%S)

RUN_OUTPUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.CREATE_RUN(
        p_run_name       => 'E2E-PHASE4-${RUN_TS}',
        p_run_type       => 'POC',
        p_source_db_info => 'oracle-src/XEPDB1',
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
    echo "${RUN_OUTPUT}" | head -20
    exit 1
fi

# ARCHIVE_LOG のテスト用行を直接 INSERT（FK 参照先が必要なため）
# LOGMINER_BATCH_LOG / APPLY_TASK の FK 先として使用するダミー行
ARCLOG_OUTPUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    INSERT INTO ARCHIVE_LOG (
        ARCHIVE_LOG_ID, MIG_RUN_ID, SOURCE_DBID, SOURCE_RESETLOGS_ID,
        THREAD_NO, SEQUENCE_NO, FIRST_CHANGE_SCN, NEXT_CHANGE_SCN,
        COLLECT_STATUS, CREATED_AT
    ) VALUES (
        SEQ_ARCHIVE_LOG.NEXTVAL, ${RUN_ID}, 99999, 1,
        1, 9001, 100000, 200000,
        'VERIFIED', SYSTIMESTAMP
    ) RETURNING ARCHIVE_LOG_ID INTO v_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('ARC_ID='||v_id);
END;
/")

ARC_LOG_ID=$(echo "${ARCLOG_OUTPUT}" | grep 'ARC_ID=' | grep -oE '[0-9]+$' | tail -1)
echo "  ARC_LOG_ID: ${ARC_LOG_ID}"

if [[ -z "${ARC_LOG_ID}" ]]; then
    echo "  [NG] ARCHIVE_LOG 登録失敗"
    echo "${ARCLOG_OUTPUT}" | head -20
    exit 1
fi

echo ""

# ============================================================
# T01: LOGMINER_BATCH PK/FK/UQ/CHECK制約の確認
# ============================================================
echo "=== T01: LOGMINER_BATCH 制約確認 ==="

# 正常INSERT
T01_OUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    INSERT INTO LOGMINER_BATCH (
        LOGMINER_BATCH_ID, MIG_RUN_ID, BATCH_NO, FROM_SCN, TO_SCN,
        DICT_METHOD, STATUS, CREATED_AT
    ) VALUES (
        SEQ_LOGMINER_BATCH.NEXTVAL, ${RUN_ID}, 1, 100000, 200000,
        'DICT_FROM_REDO_LOGS', 'PLANNED', SYSTIMESTAMP
    ) RETURNING LOGMINER_BATCH_ID INTO v_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('LMB_ID='||v_id);
END;
/")
T01_LMB_ID=$(echo "${T01_OUT}" | grep 'LMB_ID=' | grep -oE '[0-9]+$' | tail -1)
T01_CNT=$(mctl_sql "SELECT COUNT(*) FROM LOGMINER_BATCH WHERE LOGMINER_BATCH_ID=${T01_LMB_ID};")
chk "T01-1: LOGMINER_BATCH 正常INSERT" "1" "${T01_CNT}"

# UQ制約違反: 同一(MIG_RUN_ID, BATCH_NO)
T01_UQ=$(mctl_sql_raw "
BEGIN
    INSERT INTO LOGMINER_BATCH (
        LOGMINER_BATCH_ID, MIG_RUN_ID, BATCH_NO, FROM_SCN, TO_SCN,
        DICT_METHOD, STATUS, CREATED_AT
    ) VALUES (
        SEQ_LOGMINER_BATCH.NEXTVAL, ${RUN_ID}, 1, 200001, 300000,
        'DICT_FROM_REDO_LOGS', 'PLANNED', SYSTIMESTAMP
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T01_ERR=$(echo "${T01_UQ}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T01-2: UQ制約違反でINSERT失敗" "-1" "${T01_ERR}"

# CHECK制約違反: 不正STATUS
T01_CHK=$(mctl_sql_raw "
BEGIN
    INSERT INTO LOGMINER_BATCH (
        LOGMINER_BATCH_ID, MIG_RUN_ID, BATCH_NO, FROM_SCN, TO_SCN,
        DICT_METHOD, STATUS, CREATED_AT
    ) VALUES (
        SEQ_LOGMINER_BATCH.NEXTVAL, ${RUN_ID}, 99, 100000, 200000,
        'DICT_FROM_REDO_LOGS', 'INVALID_STATUS', SYSTIMESTAMP
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T01_CERR=$(echo "${T01_CHK}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T01-3: CHECK制約違反でINSERT失敗" "-2290" "${T01_CERR}"

echo ""

# ============================================================
# T02: LOGMINER_BATCH_LOG FK/UQ制約の確認
# ============================================================
echo "=== T02: LOGMINER_BATCH_LOG 制約確認 ==="

# 正常INSERT
T02_OUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    INSERT INTO LOGMINER_BATCH_LOG (
        BATCH_LOG_ID, LOGMINER_BATCH_ID, ARCHIVE_LOG_ID, ADD_ORDER, CREATED_AT
    ) VALUES (
        SEQ_LOGMINER_BATCH_LOG.NEXTVAL, ${T01_LMB_ID}, ${ARC_LOG_ID}, 1, SYSTIMESTAMP
    ) RETURNING BATCH_LOG_ID INTO v_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BL_ID='||v_id);
END;
/")
T02_BL_ID=$(echo "${T02_OUT}" | grep 'BL_ID=' | grep -oE '[0-9]+$' | tail -1)
T02_CNT=$(mctl_sql "SELECT COUNT(*) FROM LOGMINER_BATCH_LOG WHERE BATCH_LOG_ID=${T02_BL_ID};")
chk "T02-1: LOGMINER_BATCH_LOG 正常INSERT" "1" "${T02_CNT}"

# UQ制約違反: 同一(LOGMINER_BATCH_ID, ARCHIVE_LOG_ID)
T02_UQ=$(mctl_sql_raw "
BEGIN
    INSERT INTO LOGMINER_BATCH_LOG (
        BATCH_LOG_ID, LOGMINER_BATCH_ID, ARCHIVE_LOG_ID, ADD_ORDER, CREATED_AT
    ) VALUES (
        SEQ_LOGMINER_BATCH_LOG.NEXTVAL, ${T01_LMB_ID}, ${ARC_LOG_ID}, 2, SYSTIMESTAMP
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T02_ERR=$(echo "${T02_UQ}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T02-2: UQ制約違反でINSERT失敗" "-1" "${T02_ERR}"

# FK違反: 存在しないARCHIVE_LOG_ID
T02_FK=$(mctl_sql_raw "
BEGIN
    INSERT INTO LOGMINER_BATCH_LOG (
        BATCH_LOG_ID, LOGMINER_BATCH_ID, ARCHIVE_LOG_ID, ADD_ORDER, CREATED_AT
    ) VALUES (
        SEQ_LOGMINER_BATCH_LOG.NEXTVAL, ${T01_LMB_ID}, 99999999, 3, SYSTIMESTAMP
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T02_FKERR=$(echo "${T02_FK}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T02-3: FK違反でINSERT失敗" "-2291" "${T02_FKERR}"

echo ""

# ============================================================
# T03: MINED_TRANSACTION PK/FK/UQ/CHECK制約の確認
# ============================================================
echo "=== T03: MINED_TRANSACTION 制約確認 ==="

T03_OUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    INSERT INTO MINED_TRANSACTION (
        MINED_TRANSACTION_ID, MIG_RUN_ID, LOGMINER_BATCH_ID,
        XID, COMMIT_SCN, STATUS, CREATED_AT
    ) VALUES (
        SEQ_MINED_TRANSACTION.NEXTVAL, ${RUN_ID}, ${T01_LMB_ID},
        '0001.00a2.0000c8f0', 150000, 'MINED', SYSTIMESTAMP
    ) RETURNING MINED_TRANSACTION_ID INTO v_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('TX_ID='||v_id);
END;
/")
T03_TX_ID=$(echo "${T03_OUT}" | grep 'TX_ID=' | grep -oE '[0-9]+$' | tail -1)
T03_CNT=$(mctl_sql "SELECT COUNT(*) FROM MINED_TRANSACTION WHERE MINED_TRANSACTION_ID=${T03_TX_ID};")
chk "T03-1: MINED_TRANSACTION 正常INSERT" "1" "${T03_CNT}"

# UQ制約違反: 同一(MIG_RUN_ID, XID, COMMIT_SCN)
T03_UQ=$(mctl_sql_raw "
BEGIN
    INSERT INTO MINED_TRANSACTION (
        MINED_TRANSACTION_ID, MIG_RUN_ID, LOGMINER_BATCH_ID,
        XID, COMMIT_SCN, STATUS, CREATED_AT
    ) VALUES (
        SEQ_MINED_TRANSACTION.NEXTVAL, ${RUN_ID}, ${T01_LMB_ID},
        '0001.00a2.0000c8f0', 150000, 'MINED', SYSTIMESTAMP
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T03_ERR=$(echo "${T03_UQ}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T03-2: UQ制約違反でINSERT失敗" "-1" "${T03_ERR}"

# CHECK制約違反: 不正STATUS
T03_CHK=$(mctl_sql_raw "
BEGIN
    INSERT INTO MINED_TRANSACTION (
        MINED_TRANSACTION_ID, MIG_RUN_ID, LOGMINER_BATCH_ID,
        XID, COMMIT_SCN, STATUS, CREATED_AT
    ) VALUES (
        SEQ_MINED_TRANSACTION.NEXTVAL, ${RUN_ID}, ${T01_LMB_ID},
        '0001.00b2.0000d8f0', 160000, 'INVALID', SYSTIMESTAMP
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T03_CERR=$(echo "${T03_CHK}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T03-3: CHECK制約違反でINSERT失敗" "-2290" "${T03_CERR}"

echo ""

# ============================================================
# T04: MINED_CHANGE PK/FK/UQ/CHECK制約の確認
# ============================================================
echo "=== T04: MINED_CHANGE 制約確認 ==="

T04_OUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    INSERT INTO MINED_CHANGE (
        MINED_CHANGE_ID, MIG_RUN_ID, MINED_TRANSACTION_ID,
        LOGMINER_BATCH_ID, RS_ID, SSN, SCN, COMMIT_SCN,
        OPERATION, SEG_OWNER, TABLE_NAME, CSF, STATUS, CREATED_AT
    ) VALUES (
        SEQ_MINED_CHANGE.NEXTVAL, ${RUN_ID}, ${T03_TX_ID},
        ${T01_LMB_ID}, 'RS001', 1, 140000, 150000,
        'INSERT', 'SRC_SCHEMA', 'REGIONS', 0, 'MINED', SYSTIMESTAMP
    ) RETURNING MINED_CHANGE_ID INTO v_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('CHG_ID='||v_id);
END;
/")
T04_CHG_ID=$(echo "${T04_OUT}" | grep 'CHG_ID=' | grep -oE '[0-9]+$' | tail -1)
T04_CNT=$(mctl_sql "SELECT COUNT(*) FROM MINED_CHANGE WHERE MINED_CHANGE_ID=${T04_CHG_ID};")
chk "T04-1: MINED_CHANGE 正常INSERT（SQL_REDO/UNDO=NULL）" "1" "${T04_CNT}"

# UQ制約違反: 同一(MIG_RUN_ID, RS_ID, SSN)
T04_UQ=$(mctl_sql_raw "
BEGIN
    INSERT INTO MINED_CHANGE (
        MINED_CHANGE_ID, MIG_RUN_ID, MINED_TRANSACTION_ID,
        LOGMINER_BATCH_ID, RS_ID, SSN, SCN, COMMIT_SCN,
        OPERATION, CSF, STATUS, CREATED_AT
    ) VALUES (
        SEQ_MINED_CHANGE.NEXTVAL, ${RUN_ID}, ${T03_TX_ID},
        ${T01_LMB_ID}, 'RS001', 1, 140001, 150001,
        'UPDATE', 0, 'MINED', SYSTIMESTAMP
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T04_ERR=$(echo "${T04_UQ}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T04-2: UQ制約違反でINSERT失敗" "-1" "${T04_ERR}"

# CHECK制約違反: 不正OPERATION
T04_OP=$(mctl_sql_raw "
BEGIN
    INSERT INTO MINED_CHANGE (
        MINED_CHANGE_ID, MIG_RUN_ID, MINED_TRANSACTION_ID,
        LOGMINER_BATCH_ID, RS_ID, SSN, SCN, COMMIT_SCN,
        OPERATION, CSF, STATUS, CREATED_AT
    ) VALUES (
        SEQ_MINED_CHANGE.NEXTVAL, ${RUN_ID}, ${T03_TX_ID},
        ${T01_LMB_ID}, 'RS002', 1, 140002, 150002,
        'SELECT', 0, 'MINED', SYSTIMESTAMP
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T04_OPERR=$(echo "${T04_OP}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T04-3: 不正OPERATION値でINSERT失敗" "-2290" "${T04_OPERR}"

# CHECK制約違反: 不正CSF値（2）
T04_CSF=$(mctl_sql_raw "
BEGIN
    INSERT INTO MINED_CHANGE (
        MINED_CHANGE_ID, MIG_RUN_ID, MINED_TRANSACTION_ID,
        LOGMINER_BATCH_ID, RS_ID, SSN, SCN, COMMIT_SCN,
        OPERATION, CSF, STATUS, CREATED_AT
    ) VALUES (
        SEQ_MINED_CHANGE.NEXTVAL, ${RUN_ID}, ${T03_TX_ID},
        ${T01_LMB_ID}, 'RS003', 1, 140003, 150003,
        'INSERT', 2, 'MINED', SYSTIMESTAMP
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T04_CSFERR=$(echo "${T04_CSF}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T04-4: 不正CSF値（2）でINSERT失敗" "-2290" "${T04_CSFERR}"

echo ""

# ============================================================
# T05: APPLY_BATCH PK/FK/UQ/CHECK制約の確認
# ============================================================
echo "=== T05: APPLY_BATCH 制約確認 ==="

T05_OUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    INSERT INTO APPLY_BATCH (
        APPLY_BATCH_ID, MIG_RUN_ID, BATCH_NO,
        FROM_COMMIT_SCN, TO_COMMIT_SCN, STATUS, CREATED_AT
    ) VALUES (
        SEQ_APPLY_BATCH.NEXTVAL, ${RUN_ID}, 1,
        100000, 200000, 'PLANNED', SYSTIMESTAMP
    ) RETURNING APPLY_BATCH_ID INTO v_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('AB_ID='||v_id);
END;
/")
T05_AB_ID=$(echo "${T05_OUT}" | grep 'AB_ID=' | grep -oE '[0-9]+$' | tail -1)
T05_CNT=$(mctl_sql "SELECT COUNT(*) FROM APPLY_BATCH WHERE APPLY_BATCH_ID=${T05_AB_ID};")
chk "T05-1: APPLY_BATCH 正常INSERT" "1" "${T05_CNT}"

# UQ制約違反: 同一(MIG_RUN_ID, BATCH_NO)
T05_UQ=$(mctl_sql_raw "
BEGIN
    INSERT INTO APPLY_BATCH (
        APPLY_BATCH_ID, MIG_RUN_ID, BATCH_NO,
        FROM_COMMIT_SCN, TO_COMMIT_SCN, STATUS, CREATED_AT
    ) VALUES (
        SEQ_APPLY_BATCH.NEXTVAL, ${RUN_ID}, 1,
        200001, 300000, 'PLANNED', SYSTIMESTAMP
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T05_ERR=$(echo "${T05_UQ}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T05-2: UQ制約違反でINSERT失敗" "-1" "${T05_ERR}"

echo ""

# ============================================================
# T06: APPLY_TASK PK/FK/CHECK制約の確認
# ============================================================
echo "=== T06: APPLY_TASK 制約確認 ==="

T06_OUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    INSERT INTO APPLY_TASK (
        APPLY_TASK_ID, APPLY_BATCH_ID, MINED_CHANGE_ID,
        MIG_RUN_ID, DML_TYPE, STATUS, RETRY_COUNT, CREATED_AT
    ) VALUES (
        SEQ_APPLY_TASK.NEXTVAL, ${T05_AB_ID}, ${T04_CHG_ID},
        ${RUN_ID}, 'INSERT', 'PENDING', 0, SYSTIMESTAMP
    ) RETURNING APPLY_TASK_ID INTO v_id;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('AT_ID='||v_id);
END;
/")
T06_AT_ID=$(echo "${T06_OUT}" | grep 'AT_ID=' | grep -oE '[0-9]+$' | tail -1)
T06_CNT=$(mctl_sql "SELECT COUNT(*) FROM APPLY_TASK WHERE APPLY_TASK_ID=${T06_AT_ID};")
chk "T06-1: APPLY_TASK 正常INSERT (PENDING, RETRY_COUNT=0)" "1" "${T06_CNT}"

# CHECK制約違反: 不正STATUS
T06_STS=$(mctl_sql_raw "
BEGIN
    INSERT INTO APPLY_TASK (
        APPLY_TASK_ID, APPLY_BATCH_ID, MINED_CHANGE_ID,
        MIG_RUN_ID, DML_TYPE, STATUS, RETRY_COUNT, CREATED_AT
    ) VALUES (
        SEQ_APPLY_TASK.NEXTVAL, ${T05_AB_ID}, ${T04_CHG_ID},
        ${RUN_ID}, 'INSERT', 'INVALID_STS', 0, SYSTIMESTAMP
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T06_STSERR=$(echo "${T06_STS}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T06-2: 不正STATUS値でINSERT失敗" "-2290" "${T06_STSERR}"

# CHECK制約違反: 不正DML_TYPE
T06_DML=$(mctl_sql_raw "
BEGIN
    INSERT INTO APPLY_TASK (
        APPLY_TASK_ID, APPLY_BATCH_ID, MINED_CHANGE_ID,
        MIG_RUN_ID, DML_TYPE, STATUS, RETRY_COUNT, CREATED_AT
    ) VALUES (
        SEQ_APPLY_TASK.NEXTVAL, ${T05_AB_ID}, ${T04_CHG_ID},
        ${RUN_ID}, 'SELECT', 'PENDING', 0, SYSTIMESTAMP
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T06_DMLERR=$(echo "${T06_DML}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T06-3: 不正DML_TYPE値でINSERT失敗" "-2290" "${T06_DMLERR}"

echo ""

# ============================================================
# T07: LOGMINER_BATCH ライフサイクル API テスト
# ============================================================
echo "=== T07: LOGMINER_BATCH ライフサイクル API ==="

T07_OUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_LOGMINER_BATCH(
        p_run_id         => ${RUN_ID},
        p_batch_no       => 10,
        p_from_scn       => 300000,
        p_to_scn         => 400000,
        p_dict_method    => 'DICT_FROM_REDO_LOGS',
        p_logmnr_options => NULL,
        p_batch_id       => v_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BATCH_ID='||v_id);
END;
/")
T07_BATCH_ID=$(echo "${T07_OUT}" | grep 'BATCH_ID=' | grep -oE '[0-9]+$' | tail -1)
T07_STS1=$(mctl_sql "SELECT STATUS FROM LOGMINER_BATCH WHERE LOGMINER_BATCH_ID=${T07_BATCH_ID};")
chk "T07-1: REGISTER_LOGMINER_BATCH → STATUS='PLANNED'" "PLANNED" "${T07_STS1}"

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.BEGIN_LOGMINER_BATCH(${T07_BATCH_ID});
    COMMIT;
END;
/" > /dev/null 2>&1
T07_STS2=$(mctl_sql "SELECT STATUS FROM LOGMINER_BATCH WHERE LOGMINER_BATCH_ID=${T07_BATCH_ID};")
chk "T07-2: BEGIN_LOGMINER_BATCH → STATUS='RUNNING'" "RUNNING" "${T07_STS2}"

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.COMPLETE_LOGMINER_BATCH(
        p_batch_id   => ${T07_BATCH_ID},
        p_change_cnt => 100,
        p_tx_cnt     => 10
    );
    COMMIT;
END;
/" > /dev/null 2>&1
T07_STS3=$(mctl_sql "SELECT STATUS FROM LOGMINER_BATCH WHERE LOGMINER_BATCH_ID=${T07_BATCH_ID};")
chk "T07-3: COMPLETE_LOGMINER_BATCH → STATUS='COMPLETED'" "COMPLETED" "${T07_STS3}"

# ADD_BATCH_LOG のテスト（別バッチに追加）
T07_ADD_OUT=$(mctl_sql_raw "
DECLARE
    v_bid NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_LOGMINER_BATCH(
        p_run_id      => ${RUN_ID},
        p_batch_no    => 11,
        p_from_scn    => 400001,
        p_to_scn      => 500000,
        p_dict_method => 'DICT_FROM_REDO_LOGS',
        p_batch_id    => v_bid
    );
    COMMIT;
    PKG_MIG_ADMIN.ADD_BATCH_LOG(
        p_batch_id       => v_bid,
        p_archive_log_id => ${ARC_LOG_ID},
        p_add_order      => 1
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('ABATCH_ID='||v_bid);
END;
/")
T07_ABID=$(echo "${T07_ADD_OUT}" | grep 'ABATCH_ID=' | grep -oE '[0-9]+$' | tail -1)
T07_BL_CNT=$(mctl_sql "SELECT COUNT(*) FROM LOGMINER_BATCH_LOG WHERE LOGMINER_BATCH_ID=${T07_ABID};")
chk "T07-4: ADD_BATCH_LOG → LOGMINER_BATCH_LOGに行が存在" "1" "${T07_BL_CNT}"

echo ""

# ============================================================
# T08: 不正な状態遷移（-20012）テスト
# ============================================================
echo "=== T08: 不正な状態遷移エラー確認 ==="

# STATUS='COMPLETED' の LOGMINER_BATCH に BEGIN を呼ぶ → -20012
T08_OUT=$(mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.BEGIN_LOGMINER_BATCH(${T07_BATCH_ID});
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T08_ERR=$(echo "${T08_OUT}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T08-1: COMPLETED状態でBEGIN_LOGMINER_BATCH → -20012" "-20012" "${T08_ERR}"

echo ""

# ============================================================
# T09: APPLY_BATCH / APPLY_TASK ライフサイクル
# ============================================================
echo "=== T09: APPLY_BATCH / APPLY_TASK ライフサイクル ==="

T09_OUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_APPLY_BATCH(
        p_run_id          => ${RUN_ID},
        p_batch_no        => 20,
        p_from_commit_scn => 100000,
        p_to_commit_scn   => 200000,
        p_batch_id        => v_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('APBATCH_ID='||v_id);
END;
/")
T09_APBID=$(echo "${T09_OUT}" | grep 'APBATCH_ID=' | grep -oE '[0-9]+$' | tail -1)
T09_STS1=$(mctl_sql "SELECT STATUS FROM APPLY_BATCH WHERE APPLY_BATCH_ID=${T09_APBID};")
chk "T09-1: REGISTER_APPLY_BATCH → STATUS='PLANNED'" "PLANNED" "${T09_STS1}"

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.BEGIN_APPLY_BATCH(${T09_APBID});
    COMMIT;
END;
/" > /dev/null 2>&1
T09_STS2=$(mctl_sql "SELECT STATUS FROM APPLY_BATCH WHERE APPLY_BATCH_ID=${T09_APBID};")
chk "T09-2: BEGIN_APPLY_BATCH → STATUS='RUNNING'" "RUNNING" "${T09_STS2}"

T09_TASK_OUT=$(mctl_sql_raw "
DECLARE
    v_tid NUMBER;
BEGIN
    PKG_MIG_ADMIN.QUEUE_APPLY_TASK(
        p_batch_id        => ${T09_APBID},
        p_mined_change_id => ${T04_CHG_ID},
        p_seg_owner       => 'SRC_SCHEMA',
        p_table_name      => 'REGIONS',
        p_dml_type        => 'INSERT',
        p_key_payload     => 'REGION_ID=1',
        p_dml_text        => 'INSERT INTO REGIONS VALUES(1,''TEST'')',
        p_task_id         => v_tid
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('TASK_ID='||v_tid);
END;
/")
T09_TASK_ID=$(echo "${T09_TASK_OUT}" | grep 'TASK_ID=' | grep -oE '[0-9]+$' | tail -1)
T09_TSKS=$(mctl_sql "SELECT STATUS FROM APPLY_TASK WHERE APPLY_TASK_ID=${T09_TASK_ID};")
chk "T09-3: QUEUE_APPLY_TASK → STATUS='PENDING'" "PENDING" "${T09_TSKS}"

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.START_APPLY_TASK(${T09_TASK_ID}, 'test_worker');
    COMMIT;
END;
/" > /dev/null 2>&1
T09_TSKS2=$(mctl_sql "SELECT STATUS FROM APPLY_TASK WHERE APPLY_TASK_ID=${T09_TASK_ID};")
chk "T09-4: START_APPLY_TASK → STATUS='RUNNING'" "RUNNING" "${T09_TSKS2}"

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.COMPLETE_APPLY_TASK(${T09_TASK_ID});
    COMMIT;
END;
/" > /dev/null 2>&1
T09_TSKS3=$(mctl_sql "SELECT STATUS FROM APPLY_TASK WHERE APPLY_TASK_ID=${T09_TASK_ID};")
chk "T09-5: COMPLETE_APPLY_TASK → STATUS='APPLIED'" "APPLIED" "${T09_TSKS3}"

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.COMPLETE_APPLY_BATCH(
        p_batch_id => ${T09_APBID},
        p_applied  => 1,
        p_skipped  => 0,
        p_errors   => 0
    );
    COMMIT;
END;
/" > /dev/null 2>&1
T09_BSTS=$(mctl_sql "SELECT STATUS FROM APPLY_BATCH WHERE APPLY_BATCH_ID=${T09_APBID};")
chk "T09-6: COMPLETE_APPLY_BATCH → STATUS='COMPLETED'" "COMPLETED" "${T09_BSTS}"

echo ""

# ============================================================
# T10: RETRY_APPLY_TASK / ERROR_APPLY_TASK テスト
# ============================================================
echo "=== T10: RETRY_APPLY_TASK / ERROR_APPLY_TASK ==="

# テスト用APPLY_TASKを新規作成（T10用独自バッチ）
T10_OUT=$(mctl_sql_raw "
DECLARE
    v_bid NUMBER;
    v_tid1 NUMBER;
    v_tid2 NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_APPLY_BATCH(
        p_run_id          => ${RUN_ID},
        p_batch_no        => 30,
        p_from_commit_scn => 200001,
        p_to_commit_scn   => 300000,
        p_batch_id        => v_bid
    );
    COMMIT;
    PKG_MIG_ADMIN.BEGIN_APPLY_BATCH(v_bid);
    COMMIT;
    PKG_MIG_ADMIN.QUEUE_APPLY_TASK(
        p_batch_id        => v_bid,
        p_mined_change_id => ${T04_CHG_ID},
        p_seg_owner       => 'SRC_SCHEMA',
        p_table_name      => 'REGIONS',
        p_dml_type        => 'UPDATE',
        p_task_id         => v_tid1
    );
    COMMIT;
    PKG_MIG_ADMIN.QUEUE_APPLY_TASK(
        p_batch_id        => v_bid,
        p_mined_change_id => ${T04_CHG_ID},
        p_seg_owner       => 'SRC_SCHEMA',
        p_table_name      => 'REGIONS',
        p_dml_type        => 'DELETE',
        p_task_id         => v_tid2
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('TID1='||v_tid1);
    DBMS_OUTPUT.PUT_LINE('TID2='||v_tid2);
END;
/")
T10_TID1=$(echo "${T10_OUT}" | grep 'TID1=' | grep -oE '[0-9]+$' | tail -1)
T10_TID2=$(echo "${T10_OUT}" | grep 'TID2=' | grep -oE '[0-9]+$' | tail -1)

# TID1: START → RETRY
mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.START_APPLY_TASK(${T10_TID1}, 'worker1');
    COMMIT;
END;
/" > /dev/null 2>&1

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.RETRY_APPLY_TASK(
        p_task_id   => ${T10_TID1},
        p_error_id  => NULL,
        p_error_msg => 'Deadlock detected, retry'
    );
    COMMIT;
END;
/" > /dev/null 2>&1
T10_RETRY_STS=$(mctl_sql "SELECT STATUS FROM APPLY_TASK WHERE APPLY_TASK_ID=${T10_TID1};")
T10_RETRY_CNT=$(mctl_sql "SELECT RETRY_COUNT FROM APPLY_TASK WHERE APPLY_TASK_ID=${T10_TID1};")
chk "T10-1: RETRY_APPLY_TASK → STATUS='RETRY'" "RETRY" "${T10_RETRY_STS}"
chk "T10-2: RETRY_APPLY_TASK → RETRY_COUNT=1" "1" "${T10_RETRY_CNT}"

# TID2: START → ERROR
mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.START_APPLY_TASK(${T10_TID2}, 'worker2');
    COMMIT;
END;
/" > /dev/null 2>&1

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.ERROR_APPLY_TASK(
        p_task_id   => ${T10_TID2},
        p_error_id  => NULL,
        p_error_msg => 'PK violation, cannot retry'
    );
    COMMIT;
END;
/" > /dev/null 2>&1
T10_ERR_STS=$(mctl_sql "SELECT STATUS FROM APPLY_TASK WHERE APPLY_TASK_ID=${T10_TID2};")
T10_ERR_CNT=$(mctl_sql "SELECT RETRY_COUNT FROM APPLY_TASK WHERE APPLY_TASK_ID=${T10_TID2};")
chk "T10-3: ERROR_APPLY_TASK → STATUS='ERROR'" "ERROR" "${T10_ERR_STS}"
chk "T10-4: ERROR_APPLY_TASK → RETRY_COUNT=1" "1" "${T10_ERR_CNT}"

# PENDING状態でRETRY_APPLY_TASKを呼ぶ → -20012
# TID1 は現在RETRY状態なので、新しいタスクを作ってPENDING状態でテスト
T10_NEW_OUT=$(mctl_sql_raw "
DECLARE
    v_bid NUMBER;
    v_tid NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_APPLY_BATCH(
        p_run_id          => ${RUN_ID},
        p_batch_no        => 31,
        p_from_commit_scn => 300001,
        p_to_commit_scn   => 400000,
        p_batch_id        => v_bid
    );
    COMMIT;
    PKG_MIG_ADMIN.BEGIN_APPLY_BATCH(v_bid);
    COMMIT;
    PKG_MIG_ADMIN.QUEUE_APPLY_TASK(
        p_batch_id        => v_bid,
        p_mined_change_id => ${T04_CHG_ID},
        p_seg_owner       => 'SRC_SCHEMA',
        p_table_name      => 'REGIONS',
        p_dml_type        => 'INSERT',
        p_task_id         => v_tid
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('NTID='||v_tid);
END;
/")
T10_NTID=$(echo "${T10_NEW_OUT}" | grep 'NTID=' | grep -oE '[0-9]+$' | tail -1)

T10_INVLD=$(mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.RETRY_APPLY_TASK(
        p_task_id   => ${T10_NTID},
        p_error_msg => 'should fail'
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T10_INVAL_ERR=$(echo "${T10_INVLD}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T10-5: PENDING状態でRETRY_APPLY_TASK → -20012" "-20012" "${T10_INVAL_ERR}"

echo ""

# ============================================================
# T11: バルク登録テスト
# ============================================================
echo "=== T11: バルク登録 (BULK_INS_MINED_TX / BULK_INS_MINED_CHG / BULK_INS_APPLY_TASKS) ==="

# BULK_INS_MINED_TX: 3件
T11_TX_OUT=$(mctl_sql_raw "
DECLARE
    v_tbl PKG_MIG_ADMIN.T_MINED_TX_TBL;
    v_bat NUMBER;
BEGIN
    -- バルクINSERT用のバッチを登録
    PKG_MIG_ADMIN.REGISTER_LOGMINER_BATCH(
        p_run_id      => ${RUN_ID},
        p_batch_no    => 50,
        p_from_scn    => 500000,
        p_to_scn      => 600000,
        p_dict_method => 'DICT_FROM_REDO_LOGS',
        p_batch_id    => v_bat
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BULK_BATCH='||v_bat);

    v_tbl(1).MIG_RUN_ID        := ${RUN_ID};
    v_tbl(1).LOGMINER_BATCH_ID := v_bat;
    v_tbl(1).XID               := 'BULK.TX.001';
    v_tbl(1).START_SCN         := 500001;
    v_tbl(1).COMMIT_SCN        := 550001;
    v_tbl(1).CHANGE_COUNT      := 5;

    v_tbl(2).MIG_RUN_ID        := ${RUN_ID};
    v_tbl(2).LOGMINER_BATCH_ID := v_bat;
    v_tbl(2).XID               := 'BULK.TX.002';
    v_tbl(2).START_SCN         := 550002;
    v_tbl(2).COMMIT_SCN        := 560002;
    v_tbl(2).CHANGE_COUNT      := 3;

    v_tbl(3).MIG_RUN_ID        := ${RUN_ID};
    v_tbl(3).LOGMINER_BATCH_ID := v_bat;
    v_tbl(3).XID               := 'BULK.TX.003';
    v_tbl(3).START_SCN         := 560003;
    v_tbl(3).COMMIT_SCN        := 570003;
    v_tbl(3).CHANGE_COUNT      := 1;

    PKG_MIG_ADMIN.BULK_INS_MINED_TX(v_tbl);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BULK_TX_DONE=OK');
END;
/")
T11_BULK_BATCH=$(echo "${T11_TX_OUT}" | grep 'BULK_BATCH=' | grep -oE '[0-9]+$' | tail -1)
T11_TX_CNT=$(mctl_sql "SELECT COUNT(*) FROM MINED_TRANSACTION WHERE MIG_RUN_ID=${RUN_ID} AND LOGMINER_BATCH_ID=${T11_BULK_BATCH};")
chk "T11-1: BULK_INS_MINED_TX 3件 → 3行存在" "3" "${T11_TX_CNT}"

# BULK_INS_MINED_CHG: 3件（T11で登録したトランザクションのID取得）
T11_TX1_ID=$(mctl_sql "SELECT MINED_TRANSACTION_ID FROM MINED_TRANSACTION WHERE MIG_RUN_ID=${RUN_ID} AND XID='BULK.TX.001' AND ROWNUM=1;")

T11_CHG_OUT=$(mctl_sql_raw "
DECLARE
    v_tbl PKG_MIG_ADMIN.T_MINED_CHG_TBL;
BEGIN
    v_tbl(1).MIG_RUN_ID           := ${RUN_ID};
    v_tbl(1).LOGMINER_BATCH_ID    := ${T11_BULK_BATCH};
    v_tbl(1).MINED_TRANSACTION_ID := ${T11_TX1_ID};
    v_tbl(1).RS_ID                := 'BULK.RS.001';
    v_tbl(1).SSN                  := 1;
    v_tbl(1).SCN                  := 500010;
    v_tbl(1).COMMIT_SCN           := 550001;
    v_tbl(1).OPERATION            := 'INSERT';
    v_tbl(1).SEG_OWNER            := 'SRC_SCHEMA';
    v_tbl(1).TABLE_NAME           := 'REGIONS';
    v_tbl(1).CSF                  := 0;

    v_tbl(2).MIG_RUN_ID           := ${RUN_ID};
    v_tbl(2).LOGMINER_BATCH_ID    := ${T11_BULK_BATCH};
    v_tbl(2).MINED_TRANSACTION_ID := ${T11_TX1_ID};
    v_tbl(2).RS_ID                := 'BULK.RS.002';
    v_tbl(2).SSN                  := 1;
    v_tbl(2).SCN                  := 500020;
    v_tbl(2).COMMIT_SCN           := 550001;
    v_tbl(2).OPERATION            := 'UPDATE';
    v_tbl(2).SEG_OWNER            := 'SRC_SCHEMA';
    v_tbl(2).TABLE_NAME           := 'REGIONS';
    v_tbl(2).CSF                  := 0;

    v_tbl(3).MIG_RUN_ID           := ${RUN_ID};
    v_tbl(3).LOGMINER_BATCH_ID    := ${T11_BULK_BATCH};
    v_tbl(3).MINED_TRANSACTION_ID := ${T11_TX1_ID};
    v_tbl(3).RS_ID                := 'BULK.RS.003';
    v_tbl(3).SSN                  := 1;
    v_tbl(3).SCN                  := 500030;
    v_tbl(3).COMMIT_SCN           := 550001;
    v_tbl(3).OPERATION            := 'DELETE';
    v_tbl(3).SEG_OWNER            := 'SRC_SCHEMA';
    v_tbl(3).TABLE_NAME           := 'REGIONS';
    v_tbl(3).CSF                  := 0;

    PKG_MIG_ADMIN.BULK_INS_MINED_CHG(v_tbl);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BULK_CHG_DONE=OK');
END;
/")
T11_CHG_CNT=$(mctl_sql "SELECT COUNT(*) FROM MINED_CHANGE WHERE MIG_RUN_ID=${RUN_ID} AND LOGMINER_BATCH_ID=${T11_BULK_BATCH};")
chk "T11-2: BULK_INS_MINED_CHG 3件 → 3行存在" "3" "${T11_CHG_CNT}"

# BULK_INS_APPLY_TASKS: 3件
T11_CHGID1=$(mctl_sql "SELECT MINED_CHANGE_ID FROM MINED_CHANGE WHERE MIG_RUN_ID=${RUN_ID} AND RS_ID='BULK.RS.001' AND ROWNUM=1;")
T11_CHGID2=$(mctl_sql "SELECT MINED_CHANGE_ID FROM MINED_CHANGE WHERE MIG_RUN_ID=${RUN_ID} AND RS_ID='BULK.RS.002' AND ROWNUM=1;")
T11_CHGID3=$(mctl_sql "SELECT MINED_CHANGE_ID FROM MINED_CHANGE WHERE MIG_RUN_ID=${RUN_ID} AND RS_ID='BULK.RS.003' AND ROWNUM=1;")

T11_TASK_OUT=$(mctl_sql_raw "
DECLARE
    v_bid NUMBER;
    v_tbl PKG_MIG_ADMIN.T_APPLY_TASK_TBL;
BEGIN
    PKG_MIG_ADMIN.REGISTER_APPLY_BATCH(
        p_run_id          => ${RUN_ID},
        p_batch_no        => 50,
        p_from_commit_scn => 500000,
        p_to_commit_scn   => 600000,
        p_batch_id        => v_bid
    );
    COMMIT;

    v_tbl(1).MIG_RUN_ID       := ${RUN_ID};
    v_tbl(1).APPLY_BATCH_ID   := v_bid;
    v_tbl(1).MINED_CHANGE_ID  := ${T11_CHGID1};
    v_tbl(1).SEG_OWNER        := 'SRC_SCHEMA';
    v_tbl(1).TABLE_NAME       := 'REGIONS';
    v_tbl(1).DML_TYPE         := 'INSERT';
    v_tbl(1).KEY_PAYLOAD      := 'ID=1';
    v_tbl(1).DML_TEXT         := NULL;

    v_tbl(2).MIG_RUN_ID       := ${RUN_ID};
    v_tbl(2).APPLY_BATCH_ID   := v_bid;
    v_tbl(2).MINED_CHANGE_ID  := ${T11_CHGID2};
    v_tbl(2).SEG_OWNER        := 'SRC_SCHEMA';
    v_tbl(2).TABLE_NAME       := 'REGIONS';
    v_tbl(2).DML_TYPE         := 'UPDATE';
    v_tbl(2).KEY_PAYLOAD      := 'ID=2';
    v_tbl(2).DML_TEXT         := NULL;

    v_tbl(3).MIG_RUN_ID       := ${RUN_ID};
    v_tbl(3).APPLY_BATCH_ID   := v_bid;
    v_tbl(3).MINED_CHANGE_ID  := ${T11_CHGID3};
    v_tbl(3).SEG_OWNER        := 'SRC_SCHEMA';
    v_tbl(3).TABLE_NAME       := 'REGIONS';
    v_tbl(3).DML_TYPE         := 'DELETE';
    v_tbl(3).KEY_PAYLOAD      := 'ID=3';
    v_tbl(3).DML_TEXT         := NULL;

    PKG_MIG_ADMIN.BULK_INS_APPLY_TASKS(v_tbl);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('APBID='||v_bid);
END;
/")
T11_APBID=$(echo "${T11_TASK_OUT}" | grep 'APBID=' | grep -oE '[0-9]+$' | tail -1)
T11_TASK_CNT=$(mctl_sql "SELECT COUNT(*) FROM APPLY_TASK WHERE APPLY_BATCH_ID=${T11_APBID};")
chk "T11-3: BULK_INS_APPLY_TASKS 3件 → 3行存在" "3" "${T11_TASK_CNT}"

echo ""

# ============================================================
# T12: MIG_CHECKPOINT の LOGMINER_READER / APPLY_WRITER UPSERT
# ============================================================
echo "=== T12: MIG_CHECKPOINT LOGMINER_READER / APPLY_WRITER UPSERT ==="

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.UPSERT_CHECKPOINT(
        p_run_id    => ${RUN_ID},
        p_component => 'LOGMINER_READER',
        p_key       => 'GLOBAL',
        p_thread_no => NULL,
        p_seq_no    => NULL,
        p_scn       => 400000
    );
    COMMIT;
END;
/" > /dev/null 2>&1
T12_LR=$(mctl_sql "SELECT CHECKPOINT_SCN FROM MIG_CHECKPOINT WHERE MIG_RUN_ID=${RUN_ID} AND COMPONENT_NAME='LOGMINER_READER' AND CHECKPOINT_KEY='GLOBAL';")
chk "T12-1: LOGMINER_READER UPSERT_CHECKPOINT → SCN=400000" "400000" "${T12_LR}"

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.UPSERT_CHECKPOINT(
        p_run_id    => ${RUN_ID},
        p_component => 'APPLY_WRITER',
        p_key       => 'GLOBAL',
        p_thread_no => NULL,
        p_seq_no    => NULL,
        p_scn       => 200000
    );
    COMMIT;
END;
/" > /dev/null 2>&1
T12_AW=$(mctl_sql "SELECT CHECKPOINT_SCN FROM MIG_CHECKPOINT WHERE MIG_RUN_ID=${RUN_ID} AND COMPONENT_NAME='APPLY_WRITER' AND CHECKPOINT_KEY='GLOBAL';")
chk "T12-2: APPLY_WRITER UPSERT_CHECKPOINT → SCN=200000" "200000" "${T12_AW}"

# 2回目のUPSERT（UPDATE経路）
mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.UPSERT_CHECKPOINT(
        p_run_id    => ${RUN_ID},
        p_component => 'APPLY_WRITER',
        p_key       => 'GLOBAL',
        p_thread_no => NULL,
        p_seq_no    => NULL,
        p_scn       => 250000
    );
    COMMIT;
END;
/" > /dev/null 2>&1
T12_AW2=$(mctl_sql "SELECT CHECKPOINT_SCN FROM MIG_CHECKPOINT WHERE MIG_RUN_ID=${RUN_ID} AND COMPONENT_NAME='APPLY_WRITER' AND CHECKPOINT_KEY='GLOBAL';")
T12_AW_CNT=$(mctl_sql "SELECT COUNT(*) FROM MIG_CHECKPOINT WHERE MIG_RUN_ID=${RUN_ID} AND COMPONENT_NAME='APPLY_WRITER';")
chk "T12-3: 2回目UPSERT → SCN=250000（UPDATE経路）" "250000" "${T12_AW2}"
chk "T12-4: 2回目UPSERT後も行数=1（重複なし）" "1" "${T12_AW_CNT}"

echo ""

# ============================================================
# T13: 不変条件テスト（差分DMLとチェックポイントの同一トランザクション）
# ============================================================
echo "=== T13: 不変条件（差分DML + チェックポイント同一トランザクション） ==="

# APPLY_TASKのCOMPLETE + UPSERT_CHECKPOINT を同一PLSQLブロック内で実行
# T11_TASK_OUT の最初のタスクIDを取得
T13_TASKID=$(mctl_sql "SELECT MIN(APPLY_TASK_ID) FROM APPLY_TASK WHERE APPLY_BATCH_ID=${T11_APBID};")

# タスクをRUNNING状態にしてからCOMPLETE + UPSERT を同一ブロックで
mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.START_APPLY_TASK(${T13_TASKID}, 'invariant_test');
    COMMIT;
END;
/" > /dev/null 2>&1

T13_OUT=$(mctl_sql_raw "
BEGIN
    -- 同一PL/SQLブロック内でAPPLY_TASKの更新とCHECKPOINTのUPSERTを実行
    -- §9 の不変条件: これが同一DBトランザクションで完了することを確認する
    PKG_MIG_ADMIN.COMPLETE_APPLY_TASK(${T13_TASKID});
    PKG_MIG_ADMIN.UPSERT_CHECKPOINT(
        p_run_id    => ${RUN_ID},
        p_component => 'APPLY_WRITER',
        p_key       => 'GLOBAL',
        p_thread_no => NULL,
        p_seq_no    => NULL,
        p_scn       => 550001
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('T13_DONE=OK');
END;
/")

T13_TASK_STS=$(mctl_sql "SELECT STATUS FROM APPLY_TASK WHERE APPLY_TASK_ID=${T13_TASKID};")
T13_CKPT=$(mctl_sql "SELECT CHECKPOINT_SCN FROM MIG_CHECKPOINT WHERE MIG_RUN_ID=${RUN_ID} AND COMPONENT_NAME='APPLY_WRITER' AND CHECKPOINT_KEY='GLOBAL';")
chk "T13-1: COMPLETE_APPLY_TASK → STATUS='APPLIED'" "APPLIED" "${T13_TASK_STS}"
chk "T13-2: UPSERT_CHECKPOINT → SCN=550001" "550001" "${T13_CKPT}"

# ロールバック確認: ROLLBACKすると両方が元に戻ること
# 別タスクで試験
T13_TASKID2=$(mctl_sql "SELECT APPLY_TASK_ID FROM APPLY_TASK WHERE APPLY_BATCH_ID=${T11_APBID} AND STATUS='PENDING' AND ROWNUM=1;")

if [[ -n "${T13_TASKID2}" && "${T13_TASKID2}" != "" ]]; then
    mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.START_APPLY_TASK(${T13_TASKID2}, 'rollback_test');
    COMMIT;
END;
/" > /dev/null 2>&1

    # 意図的にROLLBACKするブロック（実行してからROLLBACK）
    mctl_sql_raw "
DECLARE
    v_before_ckpt NUMBER;
    v_before_sts  VARCHAR2(20);
BEGIN
    -- ロールバックテスト: COMPLETE + UPSERT を実行してROLLBACK
    UPDATE APPLY_TASK SET STATUS='APPLIED', APPLIED_AT=SYSTIMESTAMP, UPDATED_AT=SYSTIMESTAMP
    WHERE APPLY_TASK_ID=${T13_TASKID2};
    MERGE INTO MIG_CHECKPOINT dst
    USING (SELECT ${RUN_ID} AS MIG_RUN_ID, 'APPLY_WRITER' AS COMPONENT_NAME, 'GLOBAL' AS CHECKPOINT_KEY FROM DUAL) src
    ON (dst.MIG_RUN_ID=src.MIG_RUN_ID AND dst.COMPONENT_NAME=src.COMPONENT_NAME AND dst.CHECKPOINT_KEY=src.CHECKPOINT_KEY)
    WHEN MATCHED THEN
        UPDATE SET dst.CHECKPOINT_SCN=999999999, dst.UPDATED_AT=SYSTIMESTAMP;
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('T13_ROLLBACK=OK');
END;
/" > /dev/null 2>&1

    T13_RB_STS=$(mctl_sql "SELECT STATUS FROM APPLY_TASK WHERE APPLY_TASK_ID=${T13_TASKID2};")
    T13_RB_CKPT=$(mctl_sql "SELECT CHECKPOINT_SCN FROM MIG_CHECKPOINT WHERE MIG_RUN_ID=${RUN_ID} AND COMPONENT_NAME='APPLY_WRITER' AND CHECKPOINT_KEY='GLOBAL';")
    chk "T13-3: ロールバック後 APPLY_TASK.STATUS='RUNNING'（元に戻る）" "RUNNING" "${T13_RB_STS}"
    chk "T13-4: ロールバック後 CHECKPOINT_SCN=550001（元に戻る）" "550001" "${T13_RB_CKPT}"
else
    echo "  [OK] T13-3/4: ロールバック対象タスクなし（スキップ）"
fi

echo ""

# ============================================================
# T14: SET_MINING_STATUS / SET_APPLY_STATUS
# ============================================================
echo "=== T14: SET_MINING_STATUS / SET_APPLY_STATUS ==="

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.SET_MINING_STATUS(${ARC_LOG_ID}, 'MINING');
    COMMIT;
END;
/" > /dev/null 2>&1
T14_MN=$(mctl_sql "SELECT MINING_STATUS FROM ARCHIVE_LOG WHERE ARCHIVE_LOG_ID=${ARC_LOG_ID};")
chk "T14-1: SET_MINING_STATUS('MINING') → MINING_STATUS='MINING'" "MINING" "${T14_MN}"

mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.SET_APPLY_STATUS(${ARC_LOG_ID}, 'APPLIED');
    COMMIT;
END;
/" > /dev/null 2>&1
T14_AP=$(mctl_sql "SELECT APPLY_STATUS FROM ARCHIVE_LOG WHERE ARCHIVE_LOG_ID=${ARC_LOG_ID};")
chk "T14-2: SET_APPLY_STATUS('APPLIED') → APPLY_STATUS='APPLIED'" "APPLIED" "${T14_AP}"

# 不正な状態値でエラー（CHECK制約違反）
T14_INV=$(mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.SET_MINING_STATUS(${ARC_LOG_ID}, 'INVALID_STATE');
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('ERR='||SQLCODE);
END;
/")
T14_ERR=$(echo "${T14_INV}" | grep 'ERR=' | grep -oE '\-?[0-9]+$' | tail -1)
chk "T14-3: 不正な状態値 → CHECK制約違反 (-2290)" "-2290" "${T14_ERR}"

echo ""

# ============================================================
# T15: 回帰テスト（62 / 66 / 69 を実行して全 PASS を確認）
# ============================================================
echo "=== T15: 回帰テスト ==="

echo "  [T15-1] scripts/62_test_migration_ctl_e2e.sh を実行..."
if bash "${ROOT}/scripts/62_test_migration_ctl_e2e.sh" > /tmp/t15_62.log 2>&1; then
    echo "  [OK] T15-1: 62_test_migration_ctl_e2e.sh PASS"
else
    echo "  [NG] T15-1: 62_test_migration_ctl_e2e.sh FAIL"
    tail -20 /tmp/t15_62.log
    PASS=0
fi

echo "  [T15-2] scripts/66_test_phase1_2_e2e.sh を実行..."
if bash "${ROOT}/scripts/66_test_phase1_2_e2e.sh" > /tmp/t15_66.log 2>&1; then
    echo "  [OK] T15-2: 66_test_phase1_2_e2e.sh PASS"
else
    echo "  [NG] T15-2: 66_test_phase1_2_e2e.sh FAIL"
    tail -20 /tmp/t15_66.log
    PASS=0
fi

echo "  [T15-3] scripts/69_test_phase3_e2e.sh を実行..."
if bash "${ROOT}/scripts/69_test_phase3_e2e.sh" > /tmp/t15_69.log 2>&1; then
    echo "  [OK] T15-3: 69_test_phase3_e2e.sh PASS"
else
    echo "  [NG] T15-3: 69_test_phase3_e2e.sh FAIL"
    tail -20 /tmp/t15_69.log
    PASS=0
fi

echo ""

# ============================================================
# 最終判定
# ============================================================
echo "=============================================="
if [ "${PASS}" = "1" ]; then
    echo "  [PASS] Phase 4 段1 E2E 全テスト完了 (T01-T15)"
else
    echo "  [FAIL] Phase 4 段1 E2E: 上記 [NG] を確認してください"
fi
echo "=============================================="

exit $((1 - PASS))
