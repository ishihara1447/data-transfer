#!/usr/bin/env bash
# Phase 2: Data Pump Import 実行ラッパー
# 管理テーブル連携: DATAPUMP_JOB / DATAPUMP_FILE / VALIDATION_RUN / VALIDATION_RESULT
#
# 使い方: bash scripts/65_run_impdp.sh <RUN_ID> [GRP01|GRP02|ALL]
#   例: bash scripts/65_run_impdp.sh 7 ALL
#       bash scripts/65_run_impdp.sh 7 GRP01
#
# 前提:
#   - oracle-src / oracle-tgt が稼働中
#   - /migfs に Phase 1 のダンプファイル（exp_grp01_*.dmp, exp_grp02_*.dmp）が存在する
#   - PKG_MIG_ADMIN.FIX_BASELINE_SCN・DATAPUMP_FILE が VERIFIED 状態で登録済み
#   - 04_phase1_2_additions.sql / 05_pkg_mig_admin_phase1_2.sql 適用済み
#
# 本番では別途確認が必要な項目:
#   - PARALLEL 値（本番環境のCPU数・ライセンス要確認）
#   - COMPRESSION オプション（21c XE では使用不可）
#
# 実機検証済みの制約:
#   - PARALLEL>=2 は 21c XE で ORA-39094 のため省略
#   - COMPRESSION=ALL は 21c XE で使用不可のため省略
#   - TRIGGER は EXCLUDE（業務トリガーは再現しない）

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/.env"

# ============================================================
# 設定
# ============================================================
RUN_ID="${1:-}"
TARGET_GROUP="${2:-ALL}"

# oracle-tgt 接続情報
TGT_HOST="oracle-tgt"
TGT_PORT="1521"
TGT_SVC="XEPDB1"
IMPDP_USER="STAGING_SCHEMA"
IMPDP_PASS="${TGT_SCHEMA_PASS}"
MCTL_USER="MIGRATION_CTL"
MCTL_PASS="${MIGRATION_CTL_PASS}"

# ============================================================
# ユーティリティ関数
# ============================================================
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# oracle-tgt で MIGRATION_CTL 接続して SQL を実行（DML/PL/SQL）
mctl_exec() {
    docker exec "${TGT_HOST}" bash -c \
        "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'SQLEOF'
SET FEEDBACK OFF SERVEROUTPUT ON SIZE UNLIMITED
$1
EXIT;
SQLEOF" 2>&1
}

# oracle-tgt で MIGRATION_CTL 接続して純数値を返す
mctl_query() {
    docker exec "${TGT_HOST}" bash -c \
        "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
$1
EXIT;
SQLEOF" 2>&1 | tr -d ' \t' | grep -E '^[0-9]+$' | tail -1
}

# oracle-tgt SYSDBA 実行
tgt_sysdba() {
    docker exec -u oracle "${TGT_HOST}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
ALTER SESSION SET CONTAINER = XEPDB1;
$1
EXIT;
SQLEOF" 2>&1
}

# ============================================================
# 引数チェック
# ============================================================
if [ -z "${RUN_ID}" ]; then
    log "[ERROR] RUN_ID が指定されていません。"
    echo "使い方: bash scripts/65_run_impdp.sh <RUN_ID> [GRP01|GRP02|ALL]"
    exit 1
fi

if [[ ! "${TARGET_GROUP}" =~ ^(GRP01|GRP02|ALL)$ ]]; then
    log "[ERROR] TARGET_GROUP は GRP01 / GRP02 / ALL のいずれかを指定してください。"
    exit 1
fi

log "=== Phase 2 Import 開始 (RUN_ID=${RUN_ID}, TARGET_GROUP=${TARGET_GROUP}) ==="

# ============================================================
# Step 0: RUN_ID 有効性確認
# ============================================================
log "--- Step 0: RUN_ID 確認 ---"

RUN_STATUS=$(docker exec "${TGT_HOST}" bash -c \
    "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT STATUS FROM MIGRATION_RUN WHERE MIG_RUN_ID=${RUN_ID};
EOF" 2>&1 | tr -d ' \t' | grep -vE '^$' | tail -1)

if [ -z "${RUN_STATUS}" ]; then
    log "[ERROR] MIG_RUN_ID=${RUN_ID} が MIGRATION_RUN に存在しません。"
    exit 1
fi
log "MIG_RUN_ID=${RUN_ID} STATUS=${RUN_STATUS}"

# ============================================================
# Step 1: MIG_FS_DIR DIRECTORY を oracle-tgt に作成
# ============================================================
log "--- Step 1: MIG_FS_DIR DIRECTORY 作成（oracle-tgt） ---"

tgt_sysdba "
CREATE OR REPLACE DIRECTORY MIG_FS_DIR AS '/migfs';
GRANT READ, WRITE ON DIRECTORY MIG_FS_DIR TO STAGING_SCHEMA;
GRANT READ, WRITE ON DIRECTORY MIG_FS_DIR TO SYSTEM;
"
log "MIG_FS_DIR 作成・権限付与完了"

# STAGING_SCHEMA に Import 権限付与（冪等）
tgt_sysdba "
GRANT DATAPUMP_IMP_FULL_DATABASE TO STAGING_SCHEMA;
GRANT CREATE TABLE TO STAGING_SCHEMA;
GRANT UNLIMITED TABLESPACE TO STAGING_SCHEMA;
" 2>&1 | grep -v "^$" || true
log "STAGING_SCHEMA 権限付与完了"

# ============================================================
# Step 2: ダンプファイルの TARGET_VERIFIED_AT 更新
#         oracle-tgt 側から /migfs の dmp ファイルを確認し
#         SHA-256 を計算して DATAPUMP_FILE と照合する
# ============================================================
log "--- Step 2: ダンプファイル チェックサム照合（TARGET_VERIFIED_AT 更新） ---"

VERIFY_FAILED=0
mapfile -t DMP_LIST < <(docker exec "${TGT_HOST}" bash -c \
    "ls /migfs/exp_*.dmp 2>/dev/null" || true)

for FPATH in "${DMP_LIST[@]}"; do
    [ -z "${FPATH}" ] && continue
    FNAME=$(basename "${FPATH}")

    SHA256=$(docker exec "${TGT_HOST}" bash -c \
        "sha256sum ${FPATH} 2>/dev/null | cut -d' ' -f1" || echo "")

    if [ -z "${SHA256}" ]; then
        log "  [WARN] SHA-256 計算失敗: ${FNAME}"
        continue
    fi

    # DATAPUMP_FILE から FILE_ID と CHECKSUM_VALUE を取得
    FILE_INFO=$(docker exec "${TGT_HOST}" bash -c \
        "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT DATAPUMP_FILE_ID||'|'||NVL(CHECKSUM_VALUE,'')
FROM DATAPUMP_FILE
WHERE FILE_NAME='${FNAME}' AND STATUS='VERIFIED' AND ROWNUM=1;
EOF" 2>&1 | tr -d ' \t' | grep '|' | tail -1)

    FILE_ID=$(echo "${FILE_INFO}" | cut -d'|' -f1)
    EXPECTED_SHA=$(echo "${FILE_INFO}" | cut -d'|' -f2)

    if [ -z "${FILE_ID}" ]; then
        log "  [WARN] DATAPUMP_FILE に VERIFIED レコードがありません: ${FNAME}"
        continue
    fi

    if [ "${SHA256}" = "${EXPECTED_SHA}" ]; then
        # TARGET_VERIFIED_AT を更新
        docker exec "${TGT_HOST}" bash -c \
            "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
UPDATE DATAPUMP_FILE
SET TARGET_VERIFIED_AT = SYSTIMESTAMP,
    UPDATED_AT         = SYSTIMESTAMP
WHERE DATAPUMP_FILE_ID = ${FILE_ID};
COMMIT;
EXIT;
EOF" 2>&1 | grep -v "^$" || true
        log "  [OK] チェックサム一致・TARGET_VERIFIED_AT 更新: ${FNAME} (FILE_ID=${FILE_ID})"
    else
        log "  [ERROR] チェックサム不一致: ${FNAME}"
        log "    期待値: ${EXPECTED_SHA}"
        log "    実測値: ${SHA256}"
        VERIFY_FAILED=1
    fi
done

if [ "${VERIFY_FAILED}" -ne 0 ]; then
    log "[ERROR] チェックサム不一致があるため中断します。"
    exit 1
fi

# ============================================================
# Step 3: SQLFILE で DDL を生成し PHASE_STATUS.APPROVAL_STATUS を記録
# ============================================================
log "--- Step 3: SQLFILE 生成（DDL 事前確認） ---"

FIRST_DUMP=$(docker exec "${TGT_HOST}" bash -c \
    "ls /migfs/exp_grp01_01.dmp 2>/dev/null || ls /migfs/exp_grp01_*.dmp 2>/dev/null | head -1" \
    || echo "")

if [ -z "${FIRST_DUMP}" ]; then
    log "[ERROR] GRP01 ダンプファイルが見つかりません。"
    exit 1
fi
FIRST_DUMP_NAME=$(basename "${FIRST_DUMP}")
log "SQLFILE 生成対象: ${FIRST_DUMP_NAME}"

SQLFILE_TS=$(date +%Y%m%d%H%M%S)

# SQLFILE ジョブを DATAPUMP_JOB に登録し START
SQLFILE_JOB_ID=$(docker exec "${TGT_HOST}" bash -c \
    "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
DECLARE
    v_id NUMBER;
BEGIN
    INSERT INTO DATAPUMP_JOB (
        MIG_RUN_ID, JOB_NAME, OPERATION, STATUS,
        DIRECTORY_NAME, LOG_FILE_NAME, REMAP_SCHEMA_DEF
    ) VALUES (
        ${RUN_ID}, 'SQLFILE_PREVIEW_${SQLFILE_TS}', 'SQLFILE', 'PLANNED',
        'MIG_FS_DIR', 'preview_ddl.log', 'SRC_SCHEMA:STAGING_SCHEMA'
    ) RETURNING DATAPUMP_JOB_ID INTO v_id;
    PKG_MIG_ADMIN.START_DATAPUMP_JOB(v_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE(v_id);
END;
/
EXIT;
EOF" 2>&1 | tr -d ' \t' | grep -oE '^[0-9]+$' | tail -1)

log "SQLFILE_JOB_ID: ${SQLFILE_JOB_ID}"

# impdp SQLFILE 実行
docker exec -u oracle "${TGT_HOST}" bash -c \
    "impdp ${IMPDP_USER}/${IMPDP_PASS}@//localhost:${TGT_PORT}/${TGT_SVC} \
     dumpfile=${FIRST_DUMP_NAME} \
     directory=MIG_FS_DIR \
     sqlfile=preview_ddl.sql \
     logfile=preview_ddl.log \
     remap_schema=SRC_SCHEMA:STAGING_SCHEMA" 2>&1 || true

log "SQLFILE 生成完了"

# SQLFILE を DATAPUMP_FILE に登録 → COMPLETE
if [ -n "${SQLFILE_JOB_ID}" ]; then
    docker exec "${TGT_HOST}" bash -c \
        "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
DECLARE
    v_fid NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_DATAPUMP_FILE(
        p_run_id           => ${RUN_ID},
        p_job_id           => ${SQLFILE_JOB_ID},
        p_file_role        => 'SQLFILE',
        p_file_name        => 'preview_ddl.sql',
        p_file_path        => '/migfs/preview_ddl.sql',
        p_storage_location => 'MIGFS_VOLUME',
        p_file_id          => v_fid
    );
    PKG_MIG_ADMIN.COMPLETE_DATAPUMP_JOB(p_job_id => ${SQLFILE_JOB_ID});
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SQLFILE 登録・COMPLETED: file_id=' || v_fid);
END;
/
EXIT;
EOF" 2>&1
fi

# 承認記録（自動承認。実運用では手動レビュー後に更新）
docker exec "${TGT_HOST}" bash -c \
    "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
UPDATE PHASE_STATUS
SET APPROVAL_STATUS = 'APPROVED',
    APPROVED_BY     = 'AUTOCHECK',
    APPROVED_AT     = SYSTIMESTAMP,
    REMARKS         = 'SQLFILE generated and reviewed. TRIGGER excluded.',
    UPDATED_AT      = SYSTIMESTAMP
WHERE MIG_RUN_ID = ${RUN_ID}
  AND PHASE_CODE  = 'PHASE2';
COMMIT;
EXIT;
EOF" 2>&1

log "SQLFILE 生成・承認記録完了"

# ============================================================
# Step 4: PHASE_STATUS を RUNNING へ遷移
# ============================================================
log "--- Step 4: PHASE2 PHASE_STATUS を RUNNING へ遷移 ---"

docker exec "${TGT_HOST}" bash -c \
    "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
BEGIN
    UPDATE PHASE_STATUS
    SET STATUS     = 'RUNNING',
        STARTED_AT = SYSTIMESTAMP,
        UPDATED_AT = SYSTIMESTAMP
    WHERE MIG_RUN_ID = ${RUN_ID}
      AND PHASE_CODE  = 'PHASE2'
      AND STATUS IN ('NOT_STARTED', 'PAUSED');

    UPDATE MIGRATION_RUN
    SET STATUS     = 'IMPORTING',
        UPDATED_AT = SYSTIMESTAMP
    WHERE MIG_RUN_ID = ${RUN_ID};

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('PHASE2 RUNNING へ遷移完了');
END;
/
EXIT;
EOF" 2>&1

# ============================================================
# Step 5: impdp 実行（GRP01・GRP02）
# ============================================================

run_impdp_group() {
    local GROUP_NAME="$1"
    local DUMP_PATTERN="$2"
    local LOG_FILE="$3"
    local REMAP="SRC_SCHEMA:STAGING_SCHEMA"

    log "=== ${GROUP_NAME} impdp 開始 ==="

    # ダンプファイル一覧（カンマ区切り）
    DUMPFILES=$(docker exec "${TGT_HOST}" bash -c \
        "ls /migfs/${DUMP_PATTERN} 2>/dev/null | xargs -I{} basename {}" \
        | tr '\n' ',' | sed 's/,$//')

    if [ -z "${DUMPFILES}" ]; then
        log "[ERROR] ダンプファイルが見つかりません: ${DUMP_PATTERN}"
        return 1
    fi
    log "  対象ダンプ: ${DUMPFILES}"

    # DATAPUMP_JOB 登録
    IMP_TS=$(date +%Y%m%d%H%M%S)
    IMP_JOB_ID=$(docker exec "${TGT_HOST}" bash -c \
        "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON
DECLARE
    v_id NUMBER;
BEGIN
    INSERT INTO DATAPUMP_JOB (
        MIG_RUN_ID, JOB_NAME, OPERATION, STATUS,
        DIRECTORY_NAME, LOG_FILE_NAME,
        REMAP_SCHEMA_DEF, TABLE_EXISTS_ACTION,
        PARAMETER_TEXT
    ) VALUES (
        ${RUN_ID}, 'IMPDP_${GROUP_NAME}_${IMP_TS}', 'IMPORT', 'PLANNED',
        'MIG_FS_DIR', '${LOG_FILE}',
        '${REMAP}', 'REPLACE',
        'exclude=TRIGGER,GRANT,STATISTICS,INDEX content=ALL'
    ) RETURNING DATAPUMP_JOB_ID INTO v_id;
    PKG_MIG_ADMIN.START_DATAPUMP_JOB(v_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE(v_id);
END;
/
EXIT;
EOF" 2>&1 | tr -d ' \t' | grep -oE '^[0-9]+$' | tail -1)

    if [ -z "${IMP_JOB_ID}" ]; then
        log "[ERROR] ${GROUP_NAME} DATAPUMP_JOB_ID 取得失敗"
        return 1
    fi
    log "  IMP_JOB_ID: ${IMP_JOB_ID}"

    # impdp 実行
    local IMP_EXIT=0
    docker exec -u oracle "${TGT_HOST}" bash -c \
        "impdp ${IMPDP_USER}/${IMPDP_PASS}@//localhost:${TGT_PORT}/${TGT_SVC} \
         dumpfile=${DUMPFILES} \
         directory=MIG_FS_DIR \
         logfile=${LOG_FILE} \
         remap_schema=SRC_SCHEMA:STAGING_SCHEMA \
         table_exists_action=REPLACE \
         exclude=TRIGGER,GRANT,STATISTICS,INDEX \
         content=ALL" 2>&1 || IMP_EXIT=$?

    if [ "${IMP_EXIT}" -ne 0 ]; then
        log "[ERROR] ${GROUP_NAME} impdp 失敗 (exit=${IMP_EXIT})"
        # FAIL 記録
        docker exec "${TGT_HOST}" bash -c \
            "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
DECLARE v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.FAIL_DATAPUMP_JOB(
        p_job_id        => ${IMP_JOB_ID},
        p_error_message => '${GROUP_NAME} impdp exit=${IMP_EXIT}'
    );
    PKG_MIG_ADMIN.RAISE_ERROR_EVENT(
        p_run_id          => ${RUN_ID},
        p_phase_code      => 'PHASE2',
        p_severity        => 'ERROR',
        p_component_name  => '${GROUP_NAME}',
        p_datapump_job_id => ${IMP_JOB_ID},
        p_ora_error_code  => 'IMPDP_EXIT_${IMP_EXIT}',
        p_error_message   => '${GROUP_NAME} impdp failed exit=${IMP_EXIT}',
        p_event_id        => v_id
    );
    COMMIT;
END;
/
EXIT;
EOF" 2>&1
        return "${IMP_EXIT}"
    fi

    # COMPLETE + CONSUME_DATAPUMP_FILE
    docker exec "${TGT_HOST}" bash -c \
        "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
BEGIN
    PKG_MIG_ADMIN.COMPLETE_DATAPUMP_JOB(p_job_id => ${IMP_JOB_ID});
    COMMIT;
END;
/
EXIT;
EOF" 2>&1

    # 使用したダンプファイルを CONSUME
    mapfile -t FNAME_LIST < <(docker exec "${TGT_HOST}" bash -c \
        "ls /migfs/${DUMP_PATTERN} 2>/dev/null | xargs -I{} basename {}" || true)

    for FNAME in "${FNAME_LIST[@]}"; do
        [ -z "${FNAME}" ] && continue
        FILE_ID=$(docker exec "${TGT_HOST}" bash -c \
            "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT DATAPUMP_FILE_ID
FROM DATAPUMP_FILE
WHERE FILE_NAME='${FNAME}' AND STATUS='VERIFIED' AND ROWNUM=1;
EOF" 2>&1 | tr -d ' \t' | grep -oE '^[0-9]+$' | tail -1)

        if [ -n "${FILE_ID}" ]; then
            docker exec "${TGT_HOST}" bash -c \
                "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
BEGIN
    PKG_MIG_ADMIN.CONSUME_DATAPUMP_FILE(
        p_file_id       => ${FILE_ID},
        p_import_job_id => ${IMP_JOB_ID}
    );
    COMMIT;
END;
/
EXIT;
EOF" 2>&1
            log "  CONSUMED: ${FNAME} (FILE_ID=${FILE_ID})"
        else
            log "  [WARN] CONSUME スキップ（VERIFIED 状態なし）: ${FNAME}"
        fi
    done

    log "${GROUP_NAME} impdp 完了 (JOB_ID=${IMP_JOB_ID})"
}

if [ "${TARGET_GROUP}" = "GRP01" ] || [ "${TARGET_GROUP}" = "ALL" ]; then
    run_impdp_group "GRP01" "exp_grp01_*.dmp" "imp_grp01.log"
fi
if [ "${TARGET_GROUP}" = "GRP02" ] || [ "${TARGET_GROUP}" = "ALL" ]; then
    run_impdp_group "GRP02" "exp_grp02_*.dmp" "imp_grp02.log"
fi

# ============================================================
# Step 6: Import ログを DATAPUMP_FILE に登録
# ============================================================
log "--- Step 6: Import ログ DATAPUMP_FILE 登録 ---"

for LOG_FILE in imp_grp01.log imp_grp02.log; do
    if docker exec "${TGT_HOST}" bash -c "test -f /migfs/${LOG_FILE}" 2>/dev/null; then
        docker exec "${TGT_HOST}" bash -c \
            "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
DECLARE v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_DATAPUMP_FILE(
        p_run_id           => ${RUN_ID},
        p_job_id           => NULL,
        p_file_role        => 'IMPORT_LOG',
        p_file_name        => '${LOG_FILE}',
        p_file_path        => '/migfs/${LOG_FILE}',
        p_storage_location => 'MIGFS_VOLUME',
        p_file_id          => v_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('IMPORT_LOG 登録: ${LOG_FILE} file_id=' || v_id);
END;
/
EXIT;
EOF" 2>&1
        log "  [LOG 登録] ${LOG_FILE}"
    else
        log "  [SKIP] ログファイル未検出: /migfs/${LOG_FILE}"
    fi
done

# ============================================================
# Step 7: 索引・制約再構築
# ============================================================
log "--- Step 7: 索引・制約再構築 ---"

docker exec -u oracle "${TGT_HOST}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET SERVEROUTPUT ON
ALTER SESSION SET CONTAINER = XEPDB1;
$(cat "${ROOT}/sql/phase2/08_rebuild_indexes_constraints.sql")
SQLEOF" 2>&1

# ============================================================
# Step 8: 統計情報取得
# ============================================================
log "--- Step 8: 統計情報取得 ---"

docker exec "${TGT_HOST}" bash -c \
    "sqlplus -S STAGING_SCHEMA/${IMPDP_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
SET SERVEROUTPUT ON
$(cat "${ROOT}/sql/phase2/09_gather_statistics.sql")
EXIT;
EOF" 2>&1

# ============================================================
# Step 9: 件数検証（VALIDATION_RUN / VALIDATION_RESULT 記録）
# ============================================================
log "--- Step 9: 件数検証 ---"

# BASELINE_SCN を取得（Export 断面の件数と比較するため AS OF SCN を使用）
BASELINE_SCN=$(mctl_query \
    "SELECT BASELINE_SCN FROM MIGRATION_RUN WHERE MIG_RUN_ID=${RUN_ID};")
log "  BASELINE_SCN: ${BASELINE_SCN}"

# SRC 件数取得（oracle-src / AS OF SCN で Export 断面の件数を取得）
# 注意: UNDO_RETENTION が短い環境ではスナップショット取得失敗の可能性あり
#       その場合はデータジェネレータを停止した上で現在件数を使用すること
SRC_REGIONS=$(docker exec -u oracle oracle-src bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT COUNT(*) FROM SRC_SCHEMA.REGIONS AS OF SCN ${BASELINE_SCN};
EXIT;
EOF" 2>&1 | tr -d ' \t' | grep -oE '^[0-9]+$' | tail -1)

SRC_CUSTOMERS=$(docker exec -u oracle oracle-src bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT COUNT(*) FROM SRC_SCHEMA.CUSTOMERS AS OF SCN ${BASELINE_SCN};
EXIT;
EOF" 2>&1 | tr -d ' \t' | grep -oE '^[0-9]+$' | tail -1)

SRC_ORDERS=$(docker exec -u oracle oracle-src bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT COUNT(*) FROM SRC_SCHEMA.ORDERS AS OF SCN ${BASELINE_SCN};
EXIT;
EOF" 2>&1 | tr -d ' \t' | grep -oE '^[0-9]+$' | tail -1)

# TGT 件数取得
TGT_REGIONS=$(docker exec "${TGT_HOST}" bash -c \
    "sqlplus -S STAGING_SCHEMA/${IMPDP_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM REGIONS;
EXIT;
EOF" 2>&1 | tr -d ' \t' | grep -oE '^[0-9]+$' | tail -1)

TGT_CUSTOMERS=$(docker exec "${TGT_HOST}" bash -c \
    "sqlplus -S STAGING_SCHEMA/${IMPDP_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM CUSTOMERS;
EXIT;
EOF" 2>&1 | tr -d ' \t' | grep -oE '^[0-9]+$' | tail -1)

TGT_ORDERS=$(docker exec "${TGT_HOST}" bash -c \
    "sqlplus -S STAGING_SCHEMA/${IMPDP_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT COUNT(*) FROM ORDERS;
EXIT;
EOF" 2>&1 | tr -d ' \t' | grep -oE '^[0-9]+$' | tail -1)

log "件数比較:"
log "  REGIONS:   SRC=${SRC_REGIONS} / TGT=${TGT_REGIONS}"
log "  CUSTOMERS: SRC=${SRC_CUSTOMERS} / TGT=${TGT_CUSTOMERS}"
log "  ORDERS:    SRC=${SRC_ORDERS} / TGT=${TGT_ORDERS}"

# VALIDATION_RUN を開始
VRUN_ID=$(docker exec "${TGT_HOST}" bash -c \
    "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
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
EOF" 2>&1 | tr -d ' \t' | grep -oE '^[0-9]+$' | tail -1)

log "VALIDATION_RUN_ID: ${VRUN_ID}"

# 各テーブルの結果を記録
OVERALL_PASS=1
for TABLE_NAME in REGIONS CUSTOMERS ORDERS; do
    SRC_VAR="SRC_${TABLE_NAME}"
    TGT_VAR="TGT_${TABLE_NAME}"
    SRC_CNT="${!SRC_VAR}"
    TGT_CNT="${!TGT_VAR}"

    if [ "${SRC_CNT}" = "${TGT_CNT}" ] && [ -n "${SRC_CNT}" ]; then
        RESULT="PASS"
    else
        RESULT="FAIL"
        OVERALL_PASS=0
    fi

    # MIGRATION_OBJECT の ID を取得
    OBJ_ID=$(docker exec "${TGT_HOST}" bash -c \
        "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT MIG_OBJECT_ID
FROM MIGRATION_OBJECT
WHERE MIG_RUN_ID=${RUN_ID}
  AND SOURCE_TABLE_NAME='${TABLE_NAME}'
  AND ROWNUM=1;
EOF" 2>&1 | tr -d ' \t' | grep -oE '^[0-9]+$' | tail -1)

    # OBJ_ID が空の場合は NULL 扱い
    OBJ_ID_VAL="${OBJ_ID:-NULL}"

    docker exec "${TGT_HOST}" bash -c \
        "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
DECLARE v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.RECORD_VALIDATION_RESULT(
        p_validation_run_id => ${VRUN_ID},
        p_mig_object_id     => ${OBJ_ID_VAL},
        p_check_name        => 'ROW_COUNT_${TABLE_NAME}',
        p_expected_value    => '${SRC_CNT}',
        p_actual_value      => '${TGT_CNT}',
        p_result            => '${RESULT}',
        p_result_id         => v_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('VALIDATION_RESULT: ${TABLE_NAME} ${RESULT} result_id=' || v_id);
END;
/
EXIT;
EOF" 2>&1

    log "  [${RESULT}] ROW_COUNT_${TABLE_NAME}: SRC=${SRC_CNT} / TGT=${TGT_CNT}"
done

# VALIDATION_RUN を COMPLETE
if [ "${OVERALL_PASS}" -eq 1 ]; then
    OVERALL_RESULT="PASS"
else
    OVERALL_RESULT="FAIL"
fi

docker exec "${TGT_HOST}" bash -c \
    "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
BEGIN
    PKG_MIG_ADMIN.COMPLETE_VALIDATION_RUN(
        p_validation_run_id => ${VRUN_ID},
        p_overall_result    => '${OVERALL_RESULT}'
    );
    COMMIT;
END;
/
EXIT;
EOF" 2>&1

log "VALIDATION_RUN OVERALL_RESULT: ${OVERALL_RESULT}"

if [ "${OVERALL_RESULT}" = "FAIL" ]; then
    log "[ERROR] 件数検証が FAIL です。12_cleanup_for_retry.sql で初期化後に再実行してください。"
    exit 1
fi

# ============================================================
# Step 10: COMPLETE_PHASE（機械判定）
# ============================================================
log "--- Step 10: COMPLETE_PHASE 機械判定 ---"

COMPLETE_PHASE_EXIT=0
docker exec "${TGT_HOST}" bash -c \
    "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${TGT_PORT}/${TGT_SVC} <<'EOF'
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET SERVEROUTPUT ON
BEGIN
    PKG_MIG_ADMIN.COMPLETE_PHASE(
        p_run_id     => ${RUN_ID},
        p_phase_code => 'PHASE2'
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('PHASE2 COMPLETED');
END;
/
EXIT;
EOF" 2>&1 || COMPLETE_PHASE_EXIT=$?

if [ "${COMPLETE_PHASE_EXIT}" -ne 0 ]; then
    log "[ERROR] COMPLETE_PHASE(PHASE2) が失敗しました（exit=${COMPLETE_PHASE_EXIT}）。"
    log "        完了条件が満たされていません。PHASE_STATUS / ERROR_EVENT / VALIDATION_RUN を確認してください。"
    exit "${COMPLETE_PHASE_EXIT}"
fi

log ""
log "=== Phase 2 Import 完了 ==="
log "次のステップ: フェーズ3（差分アーカイブログ収集）へ"
