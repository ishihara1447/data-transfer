#!/usr/bin/env bash
# Phase 1: Data Pump Export 実行ラッパー
# 管理テーブル連携: MIGRATION_RUN / PHASE_STATUS / DATAPUMP_JOB / DATAPUMP_FILE への記録
#
# 使い方: bash scripts/63_run_expdp.sh <RUN_ID> [GRP01|GRP02|ALL]
#   例: bash scripts/63_run_expdp.sh 1 ALL
#       bash scripts/63_run_expdp.sh 1 GRP01
#
# 前提:
#   - oracle-src / oracle-tgt が稼働中
#   - /migfs が oracle:oinstall 権限で設定済み（00_init_migfs_perms.sh 実行済み）
#   - PKG_MIG_ADMIN.CREATE_RUN / MARK_ARCHIVE_READY / FIX_BASELINE_SCN が完了済み
#
# 本番では別途確認が必要な項目:
#   - PARALLEL 値（本番環境のCPU数・ライセンス要確認）
#   - COMPRESSION オプション（Advanced Compression Option 要ライセンス）

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/.env"

# ============================================================
# 設定
# ============================================================
RUN_ID="${1:-}"
TARGET_GROUP="${2:-ALL}"

# oracle-src 接続情報（expdp は oracle-src コンテナ内部から localhost 経由で接続）
SRC_HOST="oracle-src"
SRC_PORT="1521"
SRC_SVC="XEPDB1"
EXPDP_USER="SRC_SCHEMA"
EXPDP_PASS="${SRC_SCHEMA_PASS}"

# oracle-tgt 接続情報（MIGRATION_CTL スキーマへの管理記録用）
MCTL_HOST="oracle-tgt"
MCTL_PORT="1521"
MCTL_SVC="XEPDB1"
MCTL_USER="MIGRATION_CTL"
MCTL_PASS="${MIGRATION_CTL_PASS}"

# ============================================================
# ユーティリティ関数
# ============================================================
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# oracle-src で SYSDBA 接続して SQL を実行（PDB コンテキスト切替え済み）
src_sysdba() {
    docker exec -u oracle "${SRC_HOST}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
ALTER SESSION SET CONTAINER = XEPDB1;
$1
EXIT;
SQLEOF" 2>&1
}

# oracle-tgt で MIGRATION_CTL として SQL を実行し、純数値を返す
# SQLPlus の出力は先頭/末尾に空白が入るため tr で除去してから数値行を抽出する
mctl_query() {
    docker exec "${MCTL_HOST}" bash -c \
        "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${MCTL_PORT}/${MCTL_SVC} <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
$1
EXIT;
SQLEOF" 2>&1 | tr -d ' \t' | grep -E '^[0-9]+$' | tail -1
}

# oracle-tgt で MIGRATION_CTL として DML を実行（出力は捨てる）
mctl_exec() {
    docker exec "${MCTL_HOST}" bash -c \
        "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${MCTL_PORT}/${MCTL_SVC} <<'SQLEOF'
SET FEEDBACK OFF SERVEROUTPUT ON SIZE UNLIMITED
$1
EXIT;
SQLEOF" 2>&1
}

# ============================================================
# 引数チェック
# ============================================================
if [ -z "${RUN_ID}" ]; then
    log "[ERROR] RUN_ID が指定されていません。"
    echo "使い方: bash scripts/63_run_expdp.sh <RUN_ID> [GRP01|GRP02|ALL]"
    exit 1
fi

if [[ ! "${TARGET_GROUP}" =~ ^(GRP01|GRP02|ALL)$ ]]; then
    log "[ERROR] TARGET_GROUP は GRP01 / GRP02 / ALL のいずれかを指定してください。"
    exit 1
fi

log "=== Phase 1 Export 開始 (RUN_ID=${RUN_ID}, TARGET_GROUP=${TARGET_GROUP}) ==="

# ============================================================
# Step 0: 前提確認
# ============================================================
log "--- Step 0: 前提確認 ---"

# /migfs への書き込み権限確認
if ! docker exec "${SRC_HOST}" bash -c "test -w /migfs" 2>/dev/null; then
    log "[ERROR] /migfs への書き込み権限がありません。scripts/00_init_migfs_perms.sh を実行してください。"
    exit 1
fi
log "/migfs 書き込み権限: OK"

# ============================================================
# Step 1: MIG_FS_DIR DIRECTORY 作成・権限付与・expdp 権限付与
# ============================================================
log "--- Step 1: MIG_FS_DIR DIRECTORY 作成および権限付与 ---"

src_sysdba "
CREATE OR REPLACE DIRECTORY MIG_FS_DIR AS '/migfs';
GRANT READ, WRITE ON DIRECTORY MIG_FS_DIR TO SRC_SCHEMA;
GRANT READ, WRITE ON DIRECTORY MIG_FS_DIR TO SYSTEM;
GRANT DATAPUMP_EXP_FULL_DATABASE TO SRC_SCHEMA;
"
log "MIG_FS_DIR 作成・権限付与完了"

# ============================================================
# Step 2: MIGRATION_RUN の確認と BASELINE_SCN 取得
# ============================================================
log "--- Step 2: MIGRATION_RUN・BASELINE_SCN 確認 ---"

BASELINE_SCN=$(mctl_query \
    "SELECT BASELINE_SCN FROM MIGRATION_RUN WHERE MIG_RUN_ID=${RUN_ID};")

if [ -z "${BASELINE_SCN}" ] || [ "${BASELINE_SCN}" = "0" ]; then
    log "[ERROR] BASELINE_SCN が設定されていません。PKG_MIG_ADMIN.FIX_BASELINE_SCN を先に実行してください。"
    exit 1
fi
log "BASELINE_SCN: ${BASELINE_SCN}"

# ============================================================
# Step 3: PHASE_STATUS を RUNNING へ遷移
# ============================================================
log "--- Step 3: PHASE1 PHASE_STATUS を RUNNING へ遷移 ---"

mctl_exec "
BEGIN
    UPDATE PHASE_STATUS
    SET STATUS     = 'RUNNING',
        STARTED_AT = SYSTIMESTAMP,
        UPDATED_AT = SYSTIMESTAMP
    WHERE MIG_RUN_ID = ${RUN_ID}
      AND PHASE_CODE = 'PHASE1'
      AND STATUS IN ('NOT_STARTED','PAUSED');

    UPDATE MIGRATION_RUN
    SET STATUS     = 'EXPORTING',
        UPDATED_AT = SYSTIMESTAMP
    WHERE MIG_RUN_ID = ${RUN_ID};

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('PHASE1 RUNNING へ遷移完了');
END;
/"

# ============================================================
# Step 4: MIGRATION_OBJECT 登録（未登録の場合のみ）
# ============================================================
log "--- Step 4: MIGRATION_OBJECT 登録確認 ---"

OBJ_COUNT=$(mctl_query \
    "SELECT COUNT(*) FROM MIGRATION_OBJECT WHERE MIG_RUN_ID=${RUN_ID};")

if [ "${OBJ_COUNT:-0}" -lt 3 ]; then
    log "MIGRATION_OBJECT 未登録のため登録します（現在: ${OBJ_COUNT:-0} 件）"
    mctl_exec "
DECLARE
    v_cnt NUMBER;
BEGIN
    -- REGIONS (GRP01)
    SELECT COUNT(*) INTO v_cnt FROM MIGRATION_OBJECT
    WHERE MIG_RUN_ID=${RUN_ID} AND SOURCE_TABLE_NAME='REGIONS';
    IF v_cnt = 0 THEN
        INSERT INTO MIGRATION_OBJECT (
            MIG_RUN_ID, SOURCE_OWNER, SOURCE_TABLE_NAME,
            STAGE_OWNER, STAGE_TABLE_NAME,
            FULL_LOAD_FLAG, CDC_FLAG, TRANSFORM_FLAG,
            PRIMARY_KEY_COLUMNS, HAS_LOB_FLAG,
            EXPORT_GROUP_CODE, APPLY_ORDER_NO, STATUS
        ) VALUES (
            ${RUN_ID}, 'SRC_SCHEMA', 'REGIONS',
            'STAGING_SCHEMA', 'REGIONS',
            'Y', 'Y', 'N',
            'REGION_ID', 'N',
            'GRP01', 1, 'IN_SCOPE'
        );
        DBMS_OUTPUT.PUT_LINE('REGIONS 登録完了');
    END IF;

    -- CUSTOMERS (GRP01)
    SELECT COUNT(*) INTO v_cnt FROM MIGRATION_OBJECT
    WHERE MIG_RUN_ID=${RUN_ID} AND SOURCE_TABLE_NAME='CUSTOMERS';
    IF v_cnt = 0 THEN
        INSERT INTO MIGRATION_OBJECT (
            MIG_RUN_ID, SOURCE_OWNER, SOURCE_TABLE_NAME,
            STAGE_OWNER, STAGE_TABLE_NAME,
            FULL_LOAD_FLAG, CDC_FLAG, TRANSFORM_FLAG,
            PRIMARY_KEY_COLUMNS, HAS_LOB_FLAG,
            EXPORT_GROUP_CODE, APPLY_ORDER_NO, STATUS
        ) VALUES (
            ${RUN_ID}, 'SRC_SCHEMA', 'CUSTOMERS',
            'STAGING_SCHEMA', 'CUSTOMERS',
            'Y', 'Y', 'N',
            'CUSTOMER_ID', 'N',
            'GRP01', 2, 'IN_SCOPE'
        );
        DBMS_OUTPUT.PUT_LINE('CUSTOMERS 登録完了');
    END IF;

    -- ORDERS (GRP02)
    SELECT COUNT(*) INTO v_cnt FROM MIGRATION_OBJECT
    WHERE MIG_RUN_ID=${RUN_ID} AND SOURCE_TABLE_NAME='ORDERS';
    IF v_cnt = 0 THEN
        INSERT INTO MIGRATION_OBJECT (
            MIG_RUN_ID, SOURCE_OWNER, SOURCE_TABLE_NAME,
            STAGE_OWNER, STAGE_TABLE_NAME,
            FULL_LOAD_FLAG, CDC_FLAG, TRANSFORM_FLAG,
            PRIMARY_KEY_COLUMNS, HAS_LOB_FLAG,
            EXPORT_GROUP_CODE, APPLY_ORDER_NO, STATUS
        ) VALUES (
            ${RUN_ID}, 'SRC_SCHEMA', 'ORDERS',
            'STAGING_SCHEMA', 'ORDERS',
            'Y', 'Y', 'N',
            'ORDER_ID', 'N',
            'GRP02', 3, 'IN_SCOPE'
        );
        DBMS_OUTPUT.PUT_LINE('ORDERS 登録完了');
    END IF;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('MIGRATION_OBJECT 登録処理完了');
END;
/"
else
    log "MIGRATION_OBJECT は登録済みです（${OBJ_COUNT} 件）"
fi

# ============================================================
# Step 5: DATAPUMP_JOB を PLANNED で登録
# ============================================================
log "--- Step 5: DATAPUMP_JOB 登録 ---"

GRP01_TS=$(date +%Y%m%d%H%M%S)

GRP01_JOB_ID=$(docker exec "${MCTL_HOST}" bash -c \
    "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${MCTL_PORT}/${MCTL_SVC} <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO DATAPUMP_JOB (
    MIG_RUN_ID, JOB_NAME, OPERATION, STATUS, BASELINE_SCN,
    DIRECTORY_NAME, LOG_FILE_NAME
) VALUES (
    ${RUN_ID}, 'EXPDP_GRP01_${GRP01_TS}', 'EXPORT', 'PLANNED', ${BASELINE_SCN},
    'MIG_FS_DIR', 'exp_grp01.log'
);
COMMIT;
SELECT SEQ_DATAPUMP_JOB.CURRVAL FROM DUAL;
EXIT;
SQLEOF" 2>&1 | tr -d ' \t' | grep -E '^[0-9]+$' | tail -1)

# GRP02 は 1 秒後に登録してタイムスタンプの衝突を防ぐ
sleep 1
GRP02_TS=$(date +%Y%m%d%H%M%S)

GRP02_JOB_ID=$(docker exec "${MCTL_HOST}" bash -c \
    "sqlplus -S ${MCTL_USER}/${MCTL_PASS}@localhost:${MCTL_PORT}/${MCTL_SVC} <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
INSERT INTO DATAPUMP_JOB (
    MIG_RUN_ID, JOB_NAME, OPERATION, STATUS, BASELINE_SCN,
    DIRECTORY_NAME, LOG_FILE_NAME
) VALUES (
    ${RUN_ID}, 'EXPDP_GRP02_${GRP02_TS}', 'EXPORT', 'PLANNED', ${BASELINE_SCN},
    'MIG_FS_DIR', 'exp_grp02.log'
);
COMMIT;
SELECT SEQ_DATAPUMP_JOB.CURRVAL FROM DUAL;
EXIT;
SQLEOF" 2>&1 | tr -d ' \t' | grep -E '^[0-9]+$' | tail -1)

if [ -z "${GRP01_JOB_ID}" ]; then
    log "[ERROR] GRP01 の DATAPUMP_JOB_ID 取得に失敗しました。"
    exit 1
fi
if [ -z "${GRP02_JOB_ID}" ]; then
    log "[ERROR] GRP02 の DATAPUMP_JOB_ID 取得に失敗しました。"
    exit 1
fi

log "GRP01_JOB_ID: ${GRP01_JOB_ID}, GRP02_JOB_ID: ${GRP02_JOB_ID}"

# ============================================================
# Step 6: expdp 実行関数
# ============================================================
run_expdp_group() {
    local GROUP_NAME="$1"
    local JOB_ID="$2"
    local DUMP_PATTERN="$3"
    local LOG_FILE="$4"
    local TABLES="$5"

    log "--- ${GROUP_NAME} expdp 開始 (JOB_ID=${JOB_ID}) ---"

    # DATAPUMP_JOB を RUNNING へ遷移（PKG_MIG_ADMIN.START_DATAPUMP_JOB）
    mctl_exec "
BEGIN
    PKG_MIG_ADMIN.START_DATAPUMP_JOB(p_job_id => ${JOB_ID});
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('${GROUP_NAME} JOB_ID=${JOB_ID} RUNNING へ遷移');
END;
/"

    # expdp 実行（oracle-src コンテナ内部から PDB 接続）
    # 注: PARALLEL=1 を明示。COMPRESSION は省略（デフォルト METADATA_ONLY）
    # 注: include と exclude は同時指定不可のため exclude のみ使用
    local EXPDP_EXIT=0
    docker exec -u oracle "${SRC_HOST}" bash -c \
        "expdp ${EXPDP_USER}/${EXPDP_PASS}@//localhost:${SRC_PORT}/${SRC_SVC} \
         tables=${TABLES} \
         flashback_scn=${BASELINE_SCN} \
         dumpfile=${DUMP_PATTERN} \
         logfile=${LOG_FILE} \
         directory=MIG_FS_DIR \
         content=ALL \
         exclude=TRIGGER,GRANT,STATISTICS \
         parallel=1" 2>&1 || EXPDP_EXIT=$?

    if [ "${EXPDP_EXIT}" -ne 0 ]; then
        log "[ERROR] ${GROUP_NAME} expdp 失敗 (exit=${EXPDP_EXIT})"

        # DATAPUMP_JOB を FAILED へ
        mctl_exec "
BEGIN
    PKG_MIG_ADMIN.FAIL_DATAPUMP_JOB(
        p_job_id        => ${JOB_ID},
        p_error_message => '${GROUP_NAME} expdp failed with exit code ${EXPDP_EXIT}'
    );
    COMMIT;
END;
/"

        # ERROR_EVENT を記録
        mctl_exec "
DECLARE
    v_event_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.RAISE_ERROR_EVENT(
        p_run_id          => ${RUN_ID},
        p_phase_code      => 'PHASE1',
        p_severity        => 'ERROR',
        p_component_name  => '${GROUP_NAME}',
        p_datapump_job_id => ${JOB_ID},
        p_ora_error_code  => 'EXPDP_EXIT_${EXPDP_EXIT}',
        p_error_message   => '${GROUP_NAME} expdp failed with exit code ${EXPDP_EXIT}',
        p_event_id        => v_event_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('ERROR_EVENT 登録: event_id=' || v_event_id);
END;
/"
        return "${EXPDP_EXIT}"
    fi

    # DATAPUMP_JOB を COMPLETED へ遷移（PKG_MIG_ADMIN.COMPLETE_DATAPUMP_JOB）
    mctl_exec "
BEGIN
    PKG_MIG_ADMIN.COMPLETE_DATAPUMP_JOB(p_job_id => ${JOB_ID});
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('${GROUP_NAME} JOB_ID=${JOB_ID} COMPLETED へ遷移');
END;
/"

    log "${GROUP_NAME} expdp 完了"
}

# ============================================================
# Step 6a: GRP01 expdp 実行
# ============================================================
if [ "${TARGET_GROUP}" = "GRP01" ] || [ "${TARGET_GROUP}" = "ALL" ]; then
    run_expdp_group \
        "GRP01" "${GRP01_JOB_ID}" \
        "exp_grp01_%U.dmp" "exp_grp01.log" \
        "SRC_SCHEMA.REGIONS,SRC_SCHEMA.CUSTOMERS"
fi

# ============================================================
# Step 6b: GRP02 expdp 実行
# ============================================================
if [ "${TARGET_GROUP}" = "GRP02" ] || [ "${TARGET_GROUP}" = "ALL" ]; then
    run_expdp_group \
        "GRP02" "${GRP02_JOB_ID}" \
        "exp_grp02_%U.dmp" "exp_grp02.log" \
        "SRC_SCHEMA.ORDERS"
fi

# ============================================================
# Step 7: ダンプファイルの DATAPUMP_FILE 登録
# ============================================================
log "--- Step 7: ダンプファイル DATAPUMP_FILE 登録 ---"

register_dump_files() {
    local GROUP_NAME="$1"
    local JOB_ID="$2"
    local GLOB_PATTERN="$3"  # 例: "exp_grp01_*.dmp"
    local LOG_FILE="$4"

    # コンテナ内でグロブ展開してファイル一覧を取得（mapfile でパイプ問題を回避）
    mapfile -t FLIST < <(docker exec "${SRC_HOST}" bash -c \
        "ls /migfs/${GLOB_PATTERN} 2>/dev/null" || true)

    for FPATH in "${FLIST[@]}"; do
        [ -z "${FPATH}" ] && continue
        FNAME=$(basename "${FPATH}")
        FSIZE=$(docker exec "${SRC_HOST}" bash -c "stat -c %s ${FPATH}" 2>/dev/null || echo 0)

        mctl_exec "
DECLARE
    v_file_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_DATAPUMP_FILE(
        p_run_id           => ${RUN_ID},
        p_job_id           => ${JOB_ID},
        p_file_role        => 'DUMP',
        p_file_name        => '${FNAME}',
        p_file_path        => '${FPATH}',
        p_storage_location => 'MIGFS_VOLUME',
        p_file_id          => v_file_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('DUMP 登録: ${FNAME} file_id=' || v_file_id);
END;
/" 2>&1 | grep -v '^$' || true

        log "  [DUMP 登録] ${FNAME} (${FSIZE} bytes)"
    done

    # ログファイルも登録
    local LOG_PATH="/migfs/${LOG_FILE}"
    if docker exec "${SRC_HOST}" bash -c "test -f ${LOG_PATH}" 2>/dev/null; then
        local LSIZE
        LSIZE=$(docker exec "${SRC_HOST}" bash -c "stat -c %s ${LOG_PATH}" 2>/dev/null || echo 0)
        mctl_exec "
DECLARE
    v_file_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_DATAPUMP_FILE(
        p_run_id           => ${RUN_ID},
        p_job_id           => ${JOB_ID},
        p_file_role        => 'EXPORT_LOG',
        p_file_name        => '${LOG_FILE}',
        p_file_path        => '${LOG_PATH}',
        p_storage_location => 'MIGFS_VOLUME',
        p_file_id          => v_file_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('EXPORT_LOG 登録: ${LOG_FILE} file_id=' || v_file_id);
END;
/" 2>&1 | grep -v '^$' || true

        log "  [LOG 登録] ${LOG_FILE} (${LSIZE} bytes)"
    else
        log "  [WARN] ログファイル未検出: ${LOG_PATH}"
    fi
}

if [ "${TARGET_GROUP}" = "GRP01" ] || [ "${TARGET_GROUP}" = "ALL" ]; then
    register_dump_files "GRP01" "${GRP01_JOB_ID}" "exp_grp01_*.dmp" "exp_grp01.log"
fi
if [ "${TARGET_GROUP}" = "GRP02" ] || [ "${TARGET_GROUP}" = "ALL" ]; then
    register_dump_files "GRP02" "${GRP02_JOB_ID}" "exp_grp02_*.dmp" "exp_grp02.log"
fi

# ============================================================
# Step 8: SCN 外部記録票の出力
# ============================================================
log "--- Step 8: SCN 外部記録票出力 ---"

mkdir -p "${ROOT}/out"
SCN_RECORD_FILE="${ROOT}/out/scn_record_$(date +%Y%m%d_%H%M%S).txt"
cat > "${SCN_RECORD_FILE}" <<EOF
==========================================================
 Phase 1 基準SCN 外部記録票
==========================================================
MIG_RUN_ID   : ${RUN_ID}
BASELINE_SCN : ${BASELINE_SCN}
CAPTURED_AT  : $(date '+%Y-%m-%d %H:%M:%S')
TARGET_GROUP : ${TARGET_GROUP}
HOSTNAME     : $(hostname)

【二重記録の目的】
管理DBが一時的に利用不可の場合でも、この外部ファイルから
同一 MIG_RUN_ID でのデータを復元・照合できるようにする。

【用途】
- impdp の FLASHBACK_SCN として使用不可（Export時のSCN）
- LogMiner の解析開始点の参照値

【注記】
5TB/500テーブル規模での所要時間・負荷・容量の実測は
本番相当環境での別途確認が必要。
==========================================================
EOF
log "SCN 外部記録票: ${SCN_RECORD_FILE}"

# ============================================================
# Step 9: 実行結果記録様式の出力
# ============================================================
log "--- Step 9: 実行結果記録様式出力 ---"

RESULT_FILE="${ROOT}/out/phase1_result_$(date +%Y%m%d_%H%M%S).txt"
cat > "${RESULT_FILE}" <<EOF
==========================================================
 Phase 1 Export 実行結果記録
==========================================================
MIG_RUN_ID    : ${RUN_ID}
BASELINE_SCN  : ${BASELINE_SCN}
実行日時      : $(date '+%Y-%m-%d %H:%M:%S')
対象グループ  : ${TARGET_GROUP}
GRP01_JOB_ID  : ${GRP01_JOB_ID}
GRP02_JOB_ID  : ${GRP02_JOB_ID}

【ダンプファイル一覧】
$(docker exec "${SRC_HOST}" bash -c "ls -la /migfs/exp_*.dmp 2>/dev/null || echo '(なし)'")

【注記】
5TB/500テーブル規模での所要時間・負荷・容量の実測は
本番相当環境での別途確認が必要。
PARALLEL 値およびCOMPRESSION オプションは本番ライセンス要確認。
==========================================================
EOF
log "実行結果記録: ${RESULT_FILE}"

log ""
log "=== Phase 1 Export 完了 ==="
log "次のステップ: bash scripts/64_verify_dump_files.sh"
