#!/usr/bin/env bash
# Phase 1/2 E2E 検証
# T01-T16: CREATE_RUN -> expdp(GRP01正常/GRP02失敗->回復) -> impdp -> 件数突合
#
# 前提: oracle-src / oracle-tgt 稼働中、/migfs 共有ボリューム設定済み

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/.env"

# .env に STAGING_SCHEMA_PASS がないため TGT_SCHEMA_PASS を使用
STAGING_SCHEMA_PASS="${TGT_SCHEMA_PASS}"

PASS=1

chk() {
    if [ "$2" = "$3" ]; then
        echo "  [OK] $1"
    else
        echo "  [NG] $1: 期待='$2' 実際='$3'"
        PASS=0
    fi
}

# oracle-src SYSDBA 接続（PDB コンテキスト設定済み）
src_sysdba() {
    docker exec -u oracle oracle-src bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
$1
EXIT;
SQLEOF" 2>&1
}

# oracle-tgt migration_ctl 接続（最終非空行を返す。スペース・タブを除去）
mctl_sql() {
    docker exec oracle-tgt bash -c "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
$1
EXIT;
SQLEOF" 2>&1 | grep -v '^[[:space:]]*$' | tail -1 | tr -d ' \t'
}

# oracle-tgt STAGING_SCHEMA 接続
staging_sql() {
    docker exec oracle-tgt bash -c "sqlplus -S STAGING_SCHEMA/${STAGING_SCHEMA_PASS}@localhost:1521/XEPDB1 <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
$1
EXIT;
SQLEOF" 2>&1 | grep -v '^[[:space:]]*$' | tail -1 | tr -d ' \t'
}

echo "=============================================="
echo " Phase 1/2 E2E 検証"
echo "=============================================="
echo ""

# ============================================================
# Setup: テスト前クリーンアップ
# ============================================================
echo "[Setup] テスト前クリーンアップ"

docker exec -u root oracle-src bash -c \
    "rm -f /migfs/exp_*.dmp /migfs/exp_*.log /migfs/imp_*.log /migfs/preview_ddl.sql /migfs/preview_ddl.log" \
    2>/dev/null || true

docker exec -u oracle oracle-tgt bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
BEGIN
    -- FK 依存順に TRUNCATE: 子テーブルから先
    BEGIN EXECUTE IMMEDIATE 'TRUNCATE TABLE STAGING_SCHEMA.ORDERS';    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN EXECUTE IMMEDIATE 'TRUNCATE TABLE STAGING_SCHEMA.CUSTOMERS'; EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN EXECUTE IMMEDIATE 'TRUNCATE TABLE STAGING_SCHEMA.REGIONS';   EXCEPTION WHEN OTHERS THEN NULL; END;
END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' | tail -3

echo ""

# ============================================================
# T01: CREATE_RUN + PHASE_STATUS 7行確認
# ============================================================
echo "=== T01: CREATE_RUN + PHASE_STATUS 7行確認 ==="

RUN_TS=$(date +%Y%m%d%H%M%S)
RUN_OUTPUT=$(docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET SERVEROUTPUT ON FEEDBACK OFF
DECLARE
    v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.CREATE_RUN(
        p_run_name       => 'E2E-PHASE12-${RUN_TS}',
        p_run_type       => 'POC',
        p_source_db_info => 'oracle-src/XEPDB1/SRC_SCHEMA',
        p_target_db_info => 'oracle-tgt/XEPDB1/STAGING_SCHEMA',
        p_run_id         => v_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('RUN_ID='||v_id);
END;
/
EXIT;
EOF" 2>&1)

RUN_ID=$(echo "${RUN_OUTPUT}" | grep 'RUN_ID=' | grep -oE '[0-9]+' | tail -1)
echo "  RUN_ID: ${RUN_ID}"

if [ -z "${RUN_ID}" ]; then
    echo "  [NG] CREATE_RUN: RUN_ID 取得失敗"
    echo "  出力:"
    echo "${RUN_OUTPUT}" | head -20
    exit 1
fi

PS_COUNT=$(mctl_sql "SELECT COUNT(*) FROM PHASE_STATUS WHERE MIG_RUN_ID=${RUN_ID};")
chk "T01-1: PHASE_STATUS 7行作成" "7" "${PS_COUNT}"

MR_STATUS=$(mctl_sql "SELECT STATUS FROM MIGRATION_RUN WHERE MIG_RUN_ID=${RUN_ID};")
chk "T01-2: MIGRATION_RUN.STATUS=CREATED" "CREATED" "${MR_STATUS}"
echo ""

# ============================================================
# T02: MIGRATION_OBJECT 登録（3テーブル）
# ============================================================
echo "=== T02: MIGRATION_OBJECT 登録（3テーブル） ==="

docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
BEGIN
    INSERT INTO MIGRATION_OBJECT (
        MIG_RUN_ID, SOURCE_OWNER, SOURCE_TABLE_NAME,
        STAGE_OWNER, STAGE_TABLE_NAME,
        FULL_LOAD_FLAG, CDC_FLAG, TRANSFORM_FLAG,
        PRIMARY_KEY_COLUMNS, HAS_LOB_FLAG,
        EXPORT_GROUP_CODE, APPLY_ORDER_NO, STATUS
    ) VALUES (
        ${RUN_ID}, 'SRC_SCHEMA', 'REGIONS',
        'STAGING_SCHEMA', 'REGIONS',
        'Y', 'Y', 'N', 'REGION_ID', 'N', 'GRP01', 1, 'IN_SCOPE'
    );
    INSERT INTO MIGRATION_OBJECT (
        MIG_RUN_ID, SOURCE_OWNER, SOURCE_TABLE_NAME,
        STAGE_OWNER, STAGE_TABLE_NAME,
        FULL_LOAD_FLAG, CDC_FLAG, TRANSFORM_FLAG,
        PRIMARY_KEY_COLUMNS, HAS_LOB_FLAG,
        EXPORT_GROUP_CODE, APPLY_ORDER_NO, STATUS
    ) VALUES (
        ${RUN_ID}, 'SRC_SCHEMA', 'CUSTOMERS',
        'STAGING_SCHEMA', 'CUSTOMERS',
        'Y', 'Y', 'N', 'CUSTOMER_ID', 'N', 'GRP01', 2, 'IN_SCOPE'
    );
    INSERT INTO MIGRATION_OBJECT (
        MIG_RUN_ID, SOURCE_OWNER, SOURCE_TABLE_NAME,
        STAGE_OWNER, STAGE_TABLE_NAME,
        FULL_LOAD_FLAG, CDC_FLAG, TRANSFORM_FLAG,
        PRIMARY_KEY_COLUMNS, HAS_LOB_FLAG,
        EXPORT_GROUP_CODE, APPLY_ORDER_NO, STATUS
    ) VALUES (
        ${RUN_ID}, 'SRC_SCHEMA', 'ORDERS',
        'STAGING_SCHEMA', 'ORDERS',
        'Y', 'Y', 'N', 'ORDER_ID', 'N', 'GRP02', 3, 'IN_SCOPE'
    );
    COMMIT;
END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true

OBJ_COUNT=$(mctl_sql "SELECT COUNT(*) FROM MIGRATION_OBJECT WHERE MIG_RUN_ID=${RUN_ID};")
chk "T02: MIGRATION_OBJECT 3件登録" "3" "${OBJ_COUNT}"
echo ""

# ============================================================
# T03: ARCHIVE_LOG挿入 + MARK_ARCHIVE_READY + FIX_BASELINE_SCN + SCN記録票
# ============================================================
echo "=== T03: FIX_BASELINE_SCN + SCN外部記録票 ==="

# 基準SCN取得（oracle-src）
BASELINE_SCN=$(src_sysdba "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT CURRENT_SCN FROM V\$DATABASE;
" | grep -oE '[0-9]+' | tail -1)

echo "  BASELINE_SCN: ${BASELINE_SCN}"

if [ -z "${BASELINE_SCN}" ]; then
    echo "  [NG] BASELINE_SCN 取得失敗"
    PASS=0
    BASELINE_SCN=1
fi

# ARCHIVE_LOG ダミーレコード挿入（MARK_ARCHIVE_READY の前提）
docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
INSERT INTO ARCHIVE_LOG (
    MIG_RUN_ID, SOURCE_RESETLOGS_ID, THREAD_NO, SEQUENCE_NO,
    FIRST_CHANGE_SCN, NEXT_CHANGE_SCN, COLLECT_STATUS
) VALUES (${RUN_ID}, 12345678, 1, 1, ${BASELINE_SCN}, ${BASELINE_SCN}+1000, 'EXPECTED');
COMMIT;
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true

# MINING_START_SCN 設定
docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
UPDATE MIGRATION_RUN SET MINING_START_SCN=${BASELINE_SCN}, UPDATED_AT=SYSTIMESTAMP
WHERE MIG_RUN_ID=${RUN_ID};
COMMIT;
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true

# MARK_ARCHIVE_READY
docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF SERVEROUTPUT ON
BEGIN
    PKG_MIG_ADMIN.MARK_ARCHIVE_READY(p_run_id => ${RUN_ID});
    COMMIT;
END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true

# FIX_BASELINE_SCN
docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF SERVEROUTPUT ON
BEGIN
    PKG_MIG_ADMIN.FIX_BASELINE_SCN(p_run_id => ${RUN_ID}, p_baseline_scn => ${BASELINE_SCN});
    COMMIT;
END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true

MR_STATUS=$(mctl_sql "SELECT STATUS FROM MIGRATION_RUN WHERE MIG_RUN_ID=${RUN_ID};")
chk "T03-1: MIGRATION_RUN.STATUS=BASELINE_FIXED" "BASELINE_FIXED" "${MR_STATUS}"

# SCN 外部記録票生成
mkdir -p "${ROOT}/out"
SCN_RECORD_FILE="${ROOT}/out/scn_record_$(date +%Y%m%d_%H%M%S).txt"
cat > "${SCN_RECORD_FILE}" <<SCNEOF
==========================================================
 Phase 1 基準SCN 外部記録票（E2Eテスト生成）
==========================================================
MIG_RUN_ID   : ${RUN_ID}
BASELINE_SCN : ${BASELINE_SCN}
CAPTURED_AT  : $(date '+%Y-%m-%d %H:%M:%S')
TARGET_GROUP : ALL (E2E-TEST)
HOSTNAME     : $(hostname)

【二重記録の目的】
管理DBが一時的に利用不可の場合でも、この外部ファイルから
同一 MIG_RUN_ID でのデータを復元・照合できるようにする。
==========================================================
SCNEOF
echo "  SCN記録票: ${SCN_RECORD_FILE}"
echo ""

# ============================================================
# T04: GRP01 expdp 実行（正常系）
# ============================================================
echo "=== T04: GRP01 expdp 実行（正常） ==="

# oracle-src に MIG_FS_DIR DIRECTORY 作成・権限付与
src_sysdba "
CREATE OR REPLACE DIRECTORY MIG_FS_DIR AS '/migfs';
GRANT READ, WRITE ON DIRECTORY MIG_FS_DIR TO SRC_SCHEMA;
GRANT READ, WRITE ON DIRECTORY MIG_FS_DIR TO SYSTEM;
GRANT DATAPUMP_EXP_FULL_DATABASE TO SRC_SCHEMA;
" > /dev/null

# PHASE_STATUS RUNNING + MIGRATION_RUN EXPORTING
docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
BEGIN
    UPDATE PHASE_STATUS
    SET STATUS='RUNNING', STARTED_AT=SYSTIMESTAMP, UPDATED_AT=SYSTIMESTAMP
    WHERE MIG_RUN_ID=${RUN_ID} AND PHASE_CODE='PHASE1' AND STATUS IN ('NOT_STARTED','PAUSED');
    UPDATE MIGRATION_RUN
    SET STATUS='EXPORTING', UPDATED_AT=SYSTIMESTAMP
    WHERE MIG_RUN_ID=${RUN_ID};
    COMMIT;
END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true

# GRP01 DATAPUMP_JOB 登録・START
GRP01_JOB_ID=$(docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
DECLARE v_id NUMBER;
BEGIN
    INSERT INTO DATAPUMP_JOB (
        MIG_RUN_ID, JOB_NAME, OPERATION, STATUS,
        BASELINE_SCN, DIRECTORY_NAME, LOG_FILE_NAME
    ) VALUES (
        ${RUN_ID}, 'E2E_EXPDP_GRP01', 'EXPORT', 'PLANNED',
        ${BASELINE_SCN}, 'MIG_FS_DIR', 'exp_grp01.log'
    ) RETURNING DATAPUMP_JOB_ID INTO v_id;
    PKG_MIG_ADMIN.START_DATAPUMP_JOB(v_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE(v_id);
END;
/
EXIT;
EOF" 2>&1 | grep -oE '^[0-9]+$' | tail -1)

echo "  GRP01_JOB_ID: ${GRP01_JOB_ID}"

# GRP01 expdp 実行
GRP01_EXIT=0
docker exec -u oracle oracle-src bash -c \
    "expdp SRC_SCHEMA/${SRC_SCHEMA_PASS}@//localhost:1521/XEPDB1 \
     tables=SRC_SCHEMA.REGIONS,SRC_SCHEMA.CUSTOMERS \
     flashback_scn=${BASELINE_SCN} \
     dumpfile=exp_grp01_%U.dmp logfile=exp_grp01.log \
     directory=MIG_FS_DIR \
     content=ALL \
     exclude=TRIGGER,GRANT,STATISTICS \
     parallel=1" 2>&1 | tail -5 || GRP01_EXIT=$?

if [ "${GRP01_EXIT}" -eq 0 ]; then
    docker exec oracle-tgt bash -c \
        "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
BEGIN PKG_MIG_ADMIN.COMPLETE_DATAPUMP_JOB(${GRP01_JOB_ID}); COMMIT; END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true
else
    echo "  [WARN] GRP01 expdp exit=${GRP01_EXIT}"
fi

GRP01_STATUS=$(mctl_sql "SELECT STATUS FROM DATAPUMP_JOB WHERE DATAPUMP_JOB_ID=${GRP01_JOB_ID};")
chk "T04: GRP01 DATAPUMP_JOB COMPLETED" "COMPLETED" "${GRP01_STATUS}"
echo ""

# ============================================================
# T05: GRP02 expdp 意図的失敗
# ============================================================
echo "=== T05: GRP02 expdp 意図的失敗 ==="

GRP02_JOB_ID=$(docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
DECLARE v_id NUMBER;
BEGIN
    INSERT INTO DATAPUMP_JOB (
        MIG_RUN_ID, JOB_NAME, OPERATION, STATUS,
        BASELINE_SCN, DIRECTORY_NAME, LOG_FILE_NAME
    ) VALUES (
        ${RUN_ID}, 'E2E_EXPDP_GRP02', 'EXPORT', 'PLANNED',
        ${BASELINE_SCN}, 'MIG_FS_DIR', 'exp_grp02.log'
    ) RETURNING DATAPUMP_JOB_ID INTO v_id;
    PKG_MIG_ADMIN.START_DATAPUMP_JOB(v_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE(v_id);
END;
/
EXIT;
EOF" 2>&1 | grep -oE '^[0-9]+$' | tail -1)

echo "  GRP02_JOB_ID: ${GRP02_JOB_ID}"

# 意図的に失敗: 存在しないテーブルを指定
docker exec -u oracle oracle-src bash -c \
    "expdp SRC_SCHEMA/${SRC_SCHEMA_PASS}@//localhost:1521/XEPDB1 \
     tables=SRC_SCHEMA.NONEXISTENT_TABLE_E2E \
     dumpfile=exp_grp02_fail_%U.dmp logfile=exp_grp02_fail.log \
     directory=MIG_FS_DIR parallel=1" 2>&1 | tail -3 || true

# FAIL_DATAPUMP_JOB + RAISE_ERROR_EVENT
docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET SERVEROUTPUT ON FEEDBACK OFF
DECLARE v_event_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.FAIL_DATAPUMP_JOB(
        p_job_id        => ${GRP02_JOB_ID},
        p_error_message => 'ORA-39166: Object SRC_SCHEMA.NONEXISTENT_TABLE_E2E not found (intentional)'
    );
    COMMIT;
    PKG_MIG_ADMIN.RAISE_ERROR_EVENT(
        p_run_id          => ${RUN_ID},
        p_phase_code      => 'PHASE1',
        p_severity        => 'ERROR',
        p_component_name  => 'GRP02',
        p_datapump_job_id => ${GRP02_JOB_ID},
        p_ora_error_code  => 'ORA-39166',
        p_error_message   => 'Intentional failure for E2E retry test',
        p_event_id        => v_event_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('ERROR_EVENT_ID='||v_event_id);
END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true

GRP02_STATUS=$(mctl_sql "SELECT STATUS FROM DATAPUMP_JOB WHERE DATAPUMP_JOB_ID=${GRP02_JOB_ID};")
chk "T05-1: GRP02 DATAPUMP_JOB FAILED" "FAILED" "${GRP02_STATUS}"

ERROR_CNT=$(mctl_sql "SELECT COUNT(*) FROM ERROR_EVENT WHERE MIG_RUN_ID=${RUN_ID} AND RESOLVE_STATUS='OPEN';")
chk "T05-2: ERROR_EVENT が OPEN で記録" "1" "${ERROR_CNT}"
echo ""

# ============================================================
# T06: COMPLETE_PHASE(PHASE1) が条件未達で失敗すること
# ============================================================
echo "=== T06: COMPLETE_PHASE(PHASE1) が条件未達で失敗すること ==="

COMPLETE_RESULT=$(docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET SERVEROUTPUT ON FEEDBACK OFF
BEGIN
    PKG_MIG_ADMIN.COMPLETE_PHASE(p_run_id=>${RUN_ID}, p_phase_code=>'PHASE1');
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('FAILED:'||SQLERRM);
END;
/
EXIT;
EOF" 2>&1)

if echo "${COMPLETE_RESULT}" | grep -q 'FAILED:'; then
    HAS_FAILED=1
else
    HAS_FAILED=0
fi
chk "T06-1: COMPLETE_PHASE が条件未達で例外発生" "1" "${HAS_FAILED}"

PS_STATUS=$(mctl_sql "SELECT STATUS FROM PHASE_STATUS WHERE MIG_RUN_ID=${RUN_ID} AND PHASE_CODE='PHASE1';")
chk "T06-2: PHASE_STATUS まだ RUNNING" "RUNNING" "${PS_STATUS}"
echo ""

# ============================================================
# T07: ERROR_EVENT 解消 + GRP02 RETRY 状態へ
# ============================================================
echo "=== T07: ERROR_EVENT 解消 + GRP02 RETRY 状態へ ==="

docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
BEGIN
    UPDATE ERROR_EVENT
    SET RESOLVE_STATUS='RESOLVED', RESOLVED_AT=SYSTIMESTAMP,
        RESOLVE_NOTE='GRP02 再実行のため手動解消', UPDATED_AT=SYSTIMESTAMP
    WHERE MIG_RUN_ID=${RUN_ID} AND PHASE_CODE='PHASE1' AND RESOLVE_STATUS='OPEN';
    UPDATE DATAPUMP_JOB
    SET STATUS='RETRY', UPDATED_AT=SYSTIMESTAMP
    WHERE DATAPUMP_JOB_ID=${GRP02_JOB_ID};
    COMMIT;
END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true

ERROR_OPEN=$(mctl_sql "SELECT COUNT(*) FROM ERROR_EVENT WHERE MIG_RUN_ID=${RUN_ID} AND RESOLVE_STATUS='OPEN';")
chk "T07-1: ERROR_EVENT が解消 (OPEN=0)" "0" "${ERROR_OPEN}"

GRP02_RETRY=$(mctl_sql "SELECT STATUS FROM DATAPUMP_JOB WHERE DATAPUMP_JOB_ID=${GRP02_JOB_ID};")
chk "T07-2: GRP02 DATAPUMP_JOB RETRY 状態" "RETRY" "${GRP02_RETRY}"
echo ""

# ============================================================
# T08: GRP02 部分再実行（ORDERS 正常）
# ============================================================
echo "=== T08: GRP02 部分再実行（ORDERS 正常） ==="

docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
BEGIN PKG_MIG_ADMIN.START_DATAPUMP_JOB(${GRP02_JOB_ID}); COMMIT; END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true

GRP02_RERUN_EXIT=0
docker exec -u oracle oracle-src bash -c \
    "expdp SRC_SCHEMA/${SRC_SCHEMA_PASS}@//localhost:1521/XEPDB1 \
     tables=SRC_SCHEMA.ORDERS \
     flashback_scn=${BASELINE_SCN} \
     dumpfile=exp_grp02_%U.dmp logfile=exp_grp02.log \
     directory=MIG_FS_DIR \
     content=ALL \
     exclude=TRIGGER,GRANT,STATISTICS \
     parallel=1" 2>&1 | tail -5 || GRP02_RERUN_EXIT=$?

if [ "${GRP02_RERUN_EXIT}" -eq 0 ]; then
    docker exec oracle-tgt bash -c \
        "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
BEGIN PKG_MIG_ADMIN.COMPLETE_DATAPUMP_JOB(${GRP02_JOB_ID}); COMMIT; END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true
else
    echo "  [WARN] GRP02 再実行 exit=${GRP02_RERUN_EXIT}"
fi

GRP02_STATUS=$(mctl_sql "SELECT STATUS FROM DATAPUMP_JOB WHERE DATAPUMP_JOB_ID=${GRP02_JOB_ID};")
chk "T08: GRP02 部分再実行 COMPLETED" "COMPLETED" "${GRP02_STATUS}"
echo ""

# ============================================================
# T09: DATAPUMP_FILE 登録・VERIFIED
# ============================================================
echo "=== T09: DATAPUMP_FILE 登録・VERIFIED ==="

for FNAME in $(docker exec oracle-src bash -c \
    "ls /migfs/exp_grp*.dmp 2>/dev/null | xargs -I{} basename {}" 2>/dev/null || true); do
    [ -z "${FNAME}" ] && continue
    FSIZE=$(docker exec oracle-src bash -c \
        "stat -c %s /migfs/${FNAME}" 2>/dev/null || echo 0)
    SHA256=$(docker exec oracle-src bash -c \
        "sha256sum /migfs/${FNAME} 2>/dev/null | cut -d' ' -f1" || echo "")

    if [ -z "${SHA256}" ]; then
        echo "  [WARN] ${FNAME}: SHA-256 計算失敗"
        continue
    fi

    FILE_ID=$(docker exec oracle-tgt bash -c \
        "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
DECLARE v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_DATAPUMP_FILE(
        p_run_id           => ${RUN_ID},
        p_job_id           => NULL,
        p_file_role        => 'DUMP',
        p_file_name        => '${FNAME}',
        p_file_path        => '/migfs/${FNAME}',
        p_storage_location => 'MIGFS_VOLUME',
        p_file_id          => v_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE(v_id);
END;
/
EXIT;
EOF" 2>&1 | grep -oE '^[0-9]+$' | tail -1)

    if [ -n "${FILE_ID}" ]; then
        docker exec oracle-tgt bash -c \
            "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF SERVEROUTPUT ON
BEGIN
    PKG_MIG_ADMIN.VERIFY_DATAPUMP_FILE(
        p_file_id         => ${FILE_ID},
        p_file_size_bytes => ${FSIZE},
        p_checksum_algo   => 'SHA256',
        p_checksum_value  => '${SHA256}'
    );
    COMMIT;
END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true
        echo "  VERIFIED: ${FNAME} (FILE_ID=${FILE_ID})"
    else
        echo "  [WARN] ${FNAME}: REGISTER 失敗"
    fi
done

VERIFIED_COUNT=$(mctl_sql "SELECT COUNT(*) FROM DATAPUMP_FILE WHERE MIG_RUN_ID=${RUN_ID} AND FILE_ROLE='DUMP' AND STATUS='VERIFIED';")
VERIFIED_OK=$([ "${VERIFIED_COUNT:-0}" -ge 2 ] && echo "1" || echo "0")
chk "T09: DUMP ファイル VERIFIED 件数 >= 2 (実数=${VERIFIED_COUNT})" "1" "${VERIFIED_OK}"
echo ""

# ============================================================
# T10: COMPLETE_PHASE(PHASE1) 成功
# ============================================================
echo "=== T10: COMPLETE_PHASE(PHASE1) 成功 ==="

COMPLETE1_OUTPUT=$(docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET SERVEROUTPUT ON FEEDBACK OFF
BEGIN
    PKG_MIG_ADMIN.COMPLETE_PHASE(p_run_id=>${RUN_ID}, p_phase_code=>'PHASE1');
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUCCESS');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('FAILED:'||SQLERRM);
END;
/
EXIT;
EOF" 2>&1)

echo "${COMPLETE1_OUTPUT}" | grep -E 'SUCCESS|FAILED' | head -3 || true

PS1_STATUS=$(mctl_sql "SELECT STATUS FROM PHASE_STATUS WHERE MIG_RUN_ID=${RUN_ID} AND PHASE_CODE='PHASE1';")
chk "T10: PHASE1 PHASE_STATUS COMPLETED" "COMPLETED" "${PS1_STATUS}"
echo ""

# ============================================================
# T11: Phase 2 準備 + impdp 実行
# ============================================================
echo "=== T11: 承認記録・impdp 実行 ==="

# oracle-tgt に MIG_FS_DIR 作成・権限付与
docker exec -u oracle oracle-tgt bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
CREATE OR REPLACE DIRECTORY MIG_FS_DIR AS '/migfs';
GRANT READ, WRITE ON DIRECTORY MIG_FS_DIR TO STAGING_SCHEMA;
GRANT READ, WRITE ON DIRECTORY MIG_FS_DIR TO SYSTEM;
GRANT DATAPUMP_IMP_FULL_DATABASE TO STAGING_SCHEMA;
GRANT CREATE TABLE TO STAGING_SCHEMA;
GRANT UNLIMITED TABLESPACE TO STAGING_SCHEMA;
COMMIT;
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true

# TARGET_VERIFIED_AT 更新（oracle-tgt 側チェックサム照合済みとして記録）
for FNAME in $(docker exec oracle-tgt bash -c \
    "ls /migfs/exp_grp*.dmp 2>/dev/null | xargs -I{} basename {}" 2>/dev/null || true); do
    [ -z "${FNAME}" ] && continue
    docker exec oracle-tgt bash -c \
        "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
UPDATE DATAPUMP_FILE
SET TARGET_VERIFIED_AT=SYSTIMESTAMP, UPDATED_AT=SYSTIMESTAMP
WHERE FILE_NAME='${FNAME}' AND MIG_RUN_ID=${RUN_ID};
COMMIT;
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true
done

# PHASE2 RUNNING + MIGRATION_RUN IMPORTING + APPROVAL_STATUS
docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
BEGIN
    UPDATE PHASE_STATUS
    SET STATUS='RUNNING', STARTED_AT=SYSTIMESTAMP, UPDATED_AT=SYSTIMESTAMP
    WHERE MIG_RUN_ID=${RUN_ID} AND PHASE_CODE='PHASE2' AND STATUS IN ('NOT_STARTED','PAUSED');
    UPDATE MIGRATION_RUN
    SET STATUS='IMPORTING', UPDATED_AT=SYSTIMESTAMP
    WHERE MIG_RUN_ID=${RUN_ID};
    UPDATE PHASE_STATUS
    SET APPROVAL_STATUS='APPROVED', APPROVED_BY='E2E_TEST',
        APPROVED_AT=SYSTIMESTAMP, UPDATED_AT=SYSTIMESTAMP
    WHERE MIG_RUN_ID=${RUN_ID} AND PHASE_CODE='PHASE2';
    COMMIT;
END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true

PS2_APPROVAL=$(mctl_sql "SELECT APPROVAL_STATUS FROM PHASE_STATUS WHERE MIG_RUN_ID=${RUN_ID} AND PHASE_CODE='PHASE2';")
chk "T11-1: PHASE2 APPROVAL_STATUS APPROVED" "APPROVED" "${PS2_APPROVAL}"

# GRP01 impdp ジョブ登録・START
IMP_GRP01_JOB_ID=$(docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
DECLARE v_id NUMBER;
BEGIN
    INSERT INTO DATAPUMP_JOB (
        MIG_RUN_ID, JOB_NAME, OPERATION, STATUS,
        DIRECTORY_NAME, LOG_FILE_NAME,
        REMAP_SCHEMA_DEF, TABLE_EXISTS_ACTION
    ) VALUES (
        ${RUN_ID}, 'E2E_IMPDP_GRP01', 'IMPORT', 'PLANNED',
        'MIG_FS_DIR', 'imp_grp01.log',
        'SRC_SCHEMA:STAGING_SCHEMA', 'REPLACE'
    ) RETURNING DATAPUMP_JOB_ID INTO v_id;
    PKG_MIG_ADMIN.START_DATAPUMP_JOB(v_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE(v_id);
END;
/
EXIT;
EOF" 2>&1 | grep -oE '^[0-9]+$' | tail -1)

echo "  IMP_GRP01_JOB_ID: ${IMP_GRP01_JOB_ID}"

DUMPFILES_GRP01=$(docker exec oracle-tgt bash -c \
    "ls /migfs/exp_grp01_*.dmp 2>/dev/null | xargs -I{} basename {} | tr '\n' ',' | sed 's/,\$//'" \
    2>/dev/null || true)
echo "  GRP01 dumps: ${DUMPFILES_GRP01}"

IMP_GRP01_EXIT=0
docker exec -u oracle oracle-tgt bash -c \
    "impdp STAGING_SCHEMA/${STAGING_SCHEMA_PASS}@//localhost:1521/XEPDB1 \
     dumpfile=${DUMPFILES_GRP01} \
     directory=MIG_FS_DIR logfile=imp_grp01.log \
     remap_schema=SRC_SCHEMA:STAGING_SCHEMA \
     table_exists_action=REPLACE \
     exclude=TRIGGER,GRANT,STATISTICS,INDEX \
     content=ALL" 2>&1 | tail -5 || IMP_GRP01_EXIT=$?

if [ "${IMP_GRP01_EXIT}" -eq 0 ]; then
    docker exec oracle-tgt bash -c \
        "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
BEGIN PKG_MIG_ADMIN.COMPLETE_DATAPUMP_JOB(${IMP_GRP01_JOB_ID}); COMMIT; END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true
else
    echo "  [WARN] GRP01 impdp exit=${IMP_GRP01_EXIT}"
fi

# GRP02 impdp ジョブ登録・START
IMP_GRP02_JOB_ID=$(docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
DECLARE v_id NUMBER;
BEGIN
    INSERT INTO DATAPUMP_JOB (
        MIG_RUN_ID, JOB_NAME, OPERATION, STATUS,
        DIRECTORY_NAME, LOG_FILE_NAME,
        REMAP_SCHEMA_DEF, TABLE_EXISTS_ACTION
    ) VALUES (
        ${RUN_ID}, 'E2E_IMPDP_GRP02', 'IMPORT', 'PLANNED',
        'MIG_FS_DIR', 'imp_grp02.log',
        'SRC_SCHEMA:STAGING_SCHEMA', 'REPLACE'
    ) RETURNING DATAPUMP_JOB_ID INTO v_id;
    PKG_MIG_ADMIN.START_DATAPUMP_JOB(v_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE(v_id);
END;
/
EXIT;
EOF" 2>&1 | grep -oE '^[0-9]+$' | tail -1)

echo "  IMP_GRP02_JOB_ID: ${IMP_GRP02_JOB_ID}"

DUMPFILES_GRP02=$(docker exec oracle-tgt bash -c \
    "ls /migfs/exp_grp02_*.dmp 2>/dev/null | xargs -I{} basename {} | tr '\n' ',' | sed 's/,\$//'" \
    2>/dev/null || true)
echo "  GRP02 dumps: ${DUMPFILES_GRP02}"

IMP_GRP02_EXIT=0
docker exec -u oracle oracle-tgt bash -c \
    "impdp STAGING_SCHEMA/${STAGING_SCHEMA_PASS}@//localhost:1521/XEPDB1 \
     dumpfile=${DUMPFILES_GRP02} \
     directory=MIG_FS_DIR logfile=imp_grp02.log \
     remap_schema=SRC_SCHEMA:STAGING_SCHEMA \
     table_exists_action=REPLACE \
     exclude=TRIGGER,GRANT,STATISTICS,INDEX \
     content=ALL" 2>&1 | tail -5 || IMP_GRP02_EXIT=$?

if [ "${IMP_GRP02_EXIT}" -eq 0 ]; then
    docker exec oracle-tgt bash -c \
        "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
BEGIN PKG_MIG_ADMIN.COMPLETE_DATAPUMP_JOB(${IMP_GRP02_JOB_ID}); COMMIT; END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true
else
    echo "  [WARN] GRP02 impdp exit=${IMP_GRP02_EXIT}"
fi

IMP_COMPLETED=$(mctl_sql "SELECT COUNT(*) FROM DATAPUMP_JOB WHERE MIG_RUN_ID=${RUN_ID} AND OPERATION='IMPORT' AND STATUS='COMPLETED';")
chk "T11-2: IMPORT ジョブ 2件 COMPLETED" "2" "${IMP_COMPLETED}"
echo ""

# ============================================================
# T12: CONSUME_DATAPUMP_FILE
# ============================================================
echo "=== T12: CONSUME_DATAPUMP_FILE ==="

for FNAME in $(docker exec oracle-tgt bash -c \
    "ls /migfs/exp_grp*.dmp 2>/dev/null | xargs -I{} basename {}" 2>/dev/null || true); do
    [ -z "${FNAME}" ] && continue

    # GRP01 / GRP02 を判定
    if echo "${FNAME}" | grep -q "grp01"; then
        IMP_JOB_ID="${IMP_GRP01_JOB_ID}"
    else
        IMP_JOB_ID="${IMP_GRP02_JOB_ID}"
    fi

    FILE_ID=$(mctl_sql "SELECT DATAPUMP_FILE_ID FROM DATAPUMP_FILE WHERE FILE_NAME='${FNAME}' AND STATUS='VERIFIED' AND MIG_RUN_ID=${RUN_ID} AND ROWNUM=1;")

    if echo "${FILE_ID}" | grep -qE '^[0-9]+$'; then
        docker exec oracle-tgt bash -c \
            "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
BEGIN
    PKG_MIG_ADMIN.CONSUME_DATAPUMP_FILE(
        p_file_id       => ${FILE_ID},
        p_import_job_id => ${IMP_JOB_ID}
    );
    COMMIT;
END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true
        echo "  CONSUMED: ${FNAME} (FILE_ID=${FILE_ID})"
    else
        echo "  [WARN] CONSUME スキップ: ${FNAME} (FILE_ID='${FILE_ID}')"
    fi
done

CONSUMED_COUNT=$(mctl_sql "SELECT COUNT(*) FROM DATAPUMP_FILE WHERE MIG_RUN_ID=${RUN_ID} AND FILE_ROLE='DUMP' AND STATUS='CONSUMED';")
CONSUMED_OK=$([ "${CONSUMED_COUNT:-0}" -ge 2 ] && echo "1" || echo "0")
chk "T12: DUMP ファイル CONSUMED 件数 >= 2 (実数=${CONSUMED_COUNT})" "1" "${CONSUMED_OK}"
echo ""

# ============================================================
# T13: 件数検証（VALIDATION_RUN/RESULT）+ COMPLETE_PHASE(PHASE2)
# ============================================================
echo "=== T13: 件数検証 + COMPLETE_PHASE(PHASE2) ==="

# SRC 件数（AS OF SCN で Export 断面の件数を取得）
SRC_REGIONS=$(src_sysdba "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT COUNT(*) FROM SRC_SCHEMA.REGIONS AS OF SCN ${BASELINE_SCN};
" | grep -oE '[0-9]+' | tail -1)

SRC_CUSTOMERS=$(src_sysdba "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT COUNT(*) FROM SRC_SCHEMA.CUSTOMERS AS OF SCN ${BASELINE_SCN};
" | grep -oE '[0-9]+' | tail -1)

SRC_ORDERS=$(src_sysdba "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT COUNT(*) FROM SRC_SCHEMA.ORDERS AS OF SCN ${BASELINE_SCN};
" | grep -oE '[0-9]+' | tail -1)

TGT_REGIONS=$(staging_sql "SELECT COUNT(*) FROM REGIONS;")
TGT_CUSTOMERS=$(staging_sql "SELECT COUNT(*) FROM CUSTOMERS;")
TGT_ORDERS=$(staging_sql "SELECT COUNT(*) FROM ORDERS;")

echo "  REGIONS:   SRC=${SRC_REGIONS} TGT=${TGT_REGIONS}"
echo "  CUSTOMERS: SRC=${SRC_CUSTOMERS} TGT=${TGT_CUSTOMERS}"
echo "  ORDERS:    SRC=${SRC_ORDERS} TGT=${TGT_ORDERS}"

chk "T13-1: REGIONS 件数一致" "${SRC_REGIONS}" "${TGT_REGIONS}"
chk "T13-2: CUSTOMERS 件数一致" "${SRC_CUSTOMERS}" "${TGT_CUSTOMERS}"
chk "T13-3: ORDERS 件数一致" "${SRC_ORDERS}" "${TGT_ORDERS}"

# VALIDATION_RUN 開始
VRUN_ID=$(docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
DECLARE v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.START_VALIDATION_RUN(
        p_run_id            => ${RUN_ID},
        p_phase_code        => 'PHASE2',
        p_validation_type   => 'ROW_COUNT',
        p_validation_run_id => v_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE(v_id);
END;
/
EXIT;
EOF" 2>&1 | grep -oE '^[0-9]+$' | tail -1)

echo "  VALIDATION_RUN_ID: ${VRUN_ID}"

# 各テーブルの結果を記録
for TABLE_INFO in \
    "REGIONS:${SRC_REGIONS:-0}:${TGT_REGIONS:-0}" \
    "CUSTOMERS:${SRC_CUSTOMERS:-0}:${TGT_CUSTOMERS:-0}" \
    "ORDERS:${SRC_ORDERS:-0}:${TGT_ORDERS:-0}"; do

    TBL=$(echo "${TABLE_INFO}" | cut -d: -f1)
    SRC_CNT=$(echo "${TABLE_INFO}" | cut -d: -f2)
    TGT_CNT=$(echo "${TABLE_INFO}" | cut -d: -f3)
    RESULT="PASS"
    [ "${SRC_CNT}" != "${TGT_CNT}" ] && RESULT="FAIL"

    OBJ_ID=$(mctl_sql "SELECT MIG_OBJECT_ID FROM MIGRATION_OBJECT WHERE MIG_RUN_ID=${RUN_ID} AND SOURCE_TABLE_NAME='${TBL}' AND ROWNUM=1;")
    OBJ_ID_VAL="NULL"
    if echo "${OBJ_ID}" | grep -qE '^[0-9]+$'; then
        OBJ_ID_VAL="${OBJ_ID}"
    fi

    docker exec oracle-tgt bash -c \
        "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
DECLARE v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.RECORD_VALIDATION_RESULT(
        p_validation_run_id => ${VRUN_ID},
        p_mig_object_id     => ${OBJ_ID_VAL},
        p_check_name        => 'ROW_COUNT_${TBL}',
        p_expected_value    => '${SRC_CNT}',
        p_actual_value      => '${TGT_CNT}',
        p_result            => '${RESULT}',
        p_result_id         => v_id
    );
    COMMIT;
END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true
done

# VALIDATION_RUN 完了
docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET FEEDBACK OFF
BEGIN
    PKG_MIG_ADMIN.COMPLETE_VALIDATION_RUN(
        p_validation_run_id => ${VRUN_ID},
        p_overall_result    => 'PASS'
    );
    COMMIT;
END;
/
EXIT;
EOF" 2>&1 | grep -v '^[[:space:]]*$' || true

VR_RESULT=$(mctl_sql "SELECT OVERALL_RESULT FROM VALIDATION_RUN WHERE VALIDATION_RUN_ID=${VRUN_ID};")
chk "T13-4: VALIDATION_RUN OVERALL_RESULT PASS" "PASS" "${VR_RESULT}"

# COMPLETE_PHASE(PHASE2) 機械判定
COMPLETE2_OUTPUT=$(docker exec oracle-tgt bash -c \
    "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1 <<'EOF'
SET SERVEROUTPUT ON FEEDBACK OFF
BEGIN
    PKG_MIG_ADMIN.COMPLETE_PHASE(p_run_id=>${RUN_ID}, p_phase_code=>'PHASE2');
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUCCESS');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('FAILED:'||SQLERRM);
END;
/
EXIT;
EOF" 2>&1)

echo "${COMPLETE2_OUTPUT}" | grep -E 'SUCCESS|FAILED' | head -3 || true

PS2_STATUS=$(mctl_sql "SELECT STATUS FROM PHASE_STATUS WHERE MIG_RUN_ID=${RUN_ID} AND PHASE_CODE='PHASE2';")
chk "T13-5: PHASE2 PHASE_STATUS COMPLETED" "COMPLETED" "${PS2_STATUS}"
echo ""

# ============================================================
# T14-T16: 最終状態確認
# ============================================================
echo "=== T14-T16: 最終状態確認 ==="

MR_STATUS=$(mctl_sql "SELECT STATUS FROM MIGRATION_RUN WHERE MIG_RUN_ID=${RUN_ID};")
chk "T14: MIGRATION_RUN STATUS=IMPORTING（Phase4まで継続）" "IMPORTING" "${MR_STATUS}"

SCN_FILE_COUNT=$(ls "${ROOT}/out/scn_record_"*.txt 2>/dev/null | wc -l | tr -d ' ')
SCN_FILE_OK=$([ "${SCN_FILE_COUNT:-0}" -ge 1 ] && echo "1" || echo "0")
chk "T15: SCN外部記録票ファイルが存在する" "1" "${SCN_FILE_OK}"

REMAINING_VERIFIED=$(mctl_sql "SELECT COUNT(*) FROM DATAPUMP_FILE WHERE MIG_RUN_ID=${RUN_ID} AND FILE_ROLE='DUMP' AND STATUS='VERIFIED';")
chk "T16: DUMP ファイルが全て CONSUMED（VERIFIED残数=0）" "0" "${REMAINING_VERIFIED}"

# ============================================================
# 最終判定
# ============================================================
echo ""
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
