#!/usr/bin/env bash
# Archived Redo Log 収集・台帳登録・チェックサム検証スクリプト
#
# 目的: oracle-src の Archived Redo を /migfs/archivelogs/ へ収集し、
#       oracle-tgt の MIGRATION_CTL 台帳へ登録・検証する。
#
# 引数: --run-id <MIG_RUN_ID>  (必須)
#
# 処理フロー (docs/phase3-design.md §6.1):
#   1. oracle-src V$ARCHIVED_LOG から未収集 Sequence を一覧取得
#   2. REGISTER_ARCHIVE_LOG (EXPECTED)
#   3. docker exec cp でファイルを /migfs/archivelogs/ へコピー（コンテナ内 cp）
#   4. RECEIVE_ARCHIVE_LOG (EXPECTED -> RECEIVED)
#   5. sha256sum でチェックサム算出（docker exec で実行）
#   6. REGISTER_ARCHIVE_LOG_COPY (RECEIVED)
#   7. VERIFY_ARCHIVE_LOG_COPY (RECEIVED -> VERIFIED)
#   8. UPSERT_CHECKPOINT (連続した検証済み位置のみ前進)
#   9. エラー時は RAISE_ERROR_EVENT、次の Sequence へ続行

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/.env"

# ============================================================
# 引数解析
# ============================================================
RUN_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)
            RUN_ID="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "${RUN_ID}" ]]; then
    echo "Usage: $0 --run-id <MIG_RUN_ID>" >&2
    exit 1
fi

echo "=== 67_collect_archivelogs.sh: RUN_ID=${RUN_ID} ==="

# ============================================================
# /migfs/archivelogs/ ディレクトリの確認・作成（コンテナ内で作成）
# ============================================================
docker exec oracle-src bash -c "mkdir -p /migfs/archivelogs" 2>/dev/null || true

# ============================================================
# ヘルパー関数
# ============================================================

# oracle-tgt migration_ctl 接続（最終非空行を返す）
# 注意: / は独立した行に置かないと sqlplus が PL/SQL ブロックを実行しない
mctl_sql() {
    printf 'SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON\n%s\nEXIT;\n' "$1" | \
        docker exec -i oracle-tgt sqlplus -S "migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1" 2>&1 \
        | grep -v '^[[:space:]]*$' | tail -1 | tr -d ' \t'
}

# oracle-tgt migration_ctl 接続（全出力を返す）
mctl_sql_raw() {
    printf 'SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON SIZE UNLIMITED\n%s\nEXIT;\n' "$1" | \
        docker exec -i oracle-tgt sqlplus -S "migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1" 2>&1
}

# RAISE_ERROR_EVENT を呼び出す
raise_error() {
    local msg="$1"
    local component="${2:-ARCHIVE_COLLECTOR}"
    echo "  [ERROR] ${msg}"
    mctl_sql_raw "
DECLARE v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.RAISE_ERROR_EVENT(
        p_run_id         => ${RUN_ID},
        p_phase_code     => 'PHASE3',
        p_severity       => 'ERROR',
        p_component_name => 'ARCHIVE_COLLECTOR',
        p_error_message  => '${msg:0:200}',
        p_event_id       => v_id
    );
    COMMIT;
END;
/" > /dev/null 2>&1 || true
}

# ============================================================
# Step 1: oracle-src の V$ARCHIVED_LOG から未収集 Sequence を取得
# ============================================================
echo "--- Step 1: V\$ARCHIVED_LOG から未収集 Sequence 一覧取得 ---"

# oracle-src の DBID を取得
SOURCE_DBID=$(docker exec -u oracle oracle-src bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT DBID FROM V\$DATABASE;
EXIT;
SQLEOF" 2>&1 | grep -v '^[[:space:]]*$' | tail -1 | tr -d ' \t')

echo "  SOURCE_DBID: ${SOURCE_DBID}"

# Archived Log 一覧を取得（SEQUENCE#|FIRST_CHANGE#|NEXT_CHANGE#|NAME|RESETLOGS_ID|THREAD#）
SRC_LOG_DATA=$(docker exec -u oracle oracle-src bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 600
SELECT TRIM(TO_CHAR(SEQUENCE#))||'|'||TRIM(TO_CHAR(FIRST_CHANGE#))||'|'||TRIM(TO_CHAR(NEXT_CHANGE#))||'|'||TRIM(NAME)||'|'||TRIM(TO_CHAR(RESETLOGS_ID))||'|'||TRIM(TO_CHAR(THREAD#))
FROM V\$ARCHIVED_LOG
WHERE STATUS='A'
  AND NAME IS NOT NULL
ORDER BY THREAD#, SEQUENCE#;
EXIT;
SQLEOF" 2>&1 | grep -v '^[[:space:]]*$' | grep '|')

if [[ -z "${SRC_LOG_DATA}" ]]; then
    echo "  利用可能な Archived Log が存在しません。"
    exit 0
fi

# ============================================================
# Step 2〜8: 各ログを処理
# ============================================================
echo "--- Step 2-8: 各 Archived Log を処理 ---"

TOTAL_COUNT=0
SUCCESS_COUNT=0
ERROR_COUNT=0

while IFS='|' read -r SEQ_NO FIRST_SCN NEXT_SCN FILE_PATH RESETLOGS_ID THREAD_NO; do
    [[ -z "${SEQ_NO}" ]] && continue

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    FILE_NAME=$(basename "${FILE_PATH}")

    echo ""
    echo "  処理中: Thread=${THREAD_NO} Seq=${SEQ_NO} File=${FILE_NAME}"

    # Step 2: REGISTER_ARCHIVE_LOG（既登録の場合は -20002 → ARCHIVE_LOG_ID を再取得）
    REGISTER_OUT=$(mctl_sql_raw "
DECLARE
    v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_ARCHIVE_LOG(
        p_run_id         => ${RUN_ID},
        p_dbid           => ${SOURCE_DBID},
        p_resetlogs_id   => ${RESETLOGS_ID},
        p_thread_no      => ${THREAD_NO},
        p_seq_no         => ${SEQ_NO},
        p_first_scn      => ${FIRST_SCN},
        p_next_scn       => ${NEXT_SCN},
        p_archive_log_id => v_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('LOG_ID='||v_id);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERRCODE='||SQLCODE);
END;
/")

    ARCHIVE_LOG_ID=$(echo "${REGISTER_OUT}" | grep 'LOG_ID=' | grep -oE '[0-9]+$' | tail -1)
    ERR_CODE=$(echo "${REGISTER_OUT}" | grep 'ERRCODE=' | sed 's/ERRCODE=//')

    if [[ -z "${ARCHIVE_LOG_ID}" && "${ERR_CODE}" == "-20002" ]]; then
        # 既登録: ARCHIVE_LOG_ID を再取得
        ARCHIVE_LOG_ID=$(mctl_sql "
SELECT ARCHIVE_LOG_ID FROM ARCHIVE_LOG
WHERE MIG_RUN_ID=${RUN_ID} AND SOURCE_RESETLOGS_ID=${RESETLOGS_ID}
  AND THREAD_NO=${THREAD_NO} AND SEQUENCE_NO=${SEQ_NO} AND ROWNUM=1;")
        echo "    既登録: ARCHIVE_LOG_ID=${ARCHIVE_LOG_ID}"
    elif [[ -z "${ARCHIVE_LOG_ID}" ]]; then
        raise_error "REGISTER_ARCHIVE_LOG failed: Seq=${SEQ_NO}"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    echo "    ARCHIVE_LOG_ID=${ARCHIVE_LOG_ID}"

    # Step 3: コンテナ内で cp（/migfs は共有ボリューム）
    DEST_PATH="/migfs/archivelogs/${FILE_NAME}"
    if ! docker exec oracle-src bash -c "cp '${FILE_PATH}' '${DEST_PATH}'" 2>/dev/null; then
        raise_error "cp failed: ${FILE_PATH}"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi
    echo "    コピー完了: ${DEST_PATH}"

    # Step 4: RECEIVE_ARCHIVE_LOG（EXPECTED -> RECEIVED）
    CURRENT_STATUS=$(mctl_sql "SELECT COLLECT_STATUS FROM ARCHIVE_LOG WHERE ARCHIVE_LOG_ID=${ARCHIVE_LOG_ID};")
    if [[ "${CURRENT_STATUS}" == "EXPECTED" ]]; then
        mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.RECEIVE_ARCHIVE_LOG(p_archive_log_id => ${ARCHIVE_LOG_ID});
    COMMIT;
END;
/" > /dev/null 2>&1 || true
    fi

    # Step 5: sha256sum（コンテナ内で実行）
    CHECKSUM=$(docker exec oracle-src bash -c "sha256sum '${DEST_PATH}'" 2>/dev/null | cut -d' ' -f1)
    FILE_SIZE=$(docker exec oracle-src bash -c "stat -c%s '${DEST_PATH}'" 2>/dev/null || echo 0)

    if [[ -z "${CHECKSUM}" ]]; then
        raise_error "sha256sum failed: ${DEST_PATH}"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi
    echo "    SHA256=${CHECKSUM:0:16}... SIZE=${FILE_SIZE}"

    # Step 6: REGISTER_ARCHIVE_LOG_COPY
    COPY_OUT=$(mctl_sql_raw "
DECLARE v_copy_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.REGISTER_ARCHIVE_LOG_COPY(
        p_archive_log_id => ${ARCHIVE_LOG_ID},
        p_storage_loc    => 'MIGFS',
        p_file_path      => '${DEST_PATH}',
        p_file_size      => ${FILE_SIZE},
        p_checksum_algo  => 'SHA256',
        p_checksum_val   => '${CHECKSUM}',
        p_copy_id        => v_copy_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('COPY_ID='||v_copy_id);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('COPY_ERR='||SQLERRM);
END;
/")

    COPY_ID=$(echo "${COPY_OUT}" | grep 'COPY_ID=' | grep -oE '[0-9]+$' | tail -1)
    if [[ -z "${COPY_ID}" ]]; then
        COPY_ID=$(mctl_sql "SELECT ARCHIVE_LOG_COPY_ID FROM ARCHIVE_LOG_COPY WHERE ARCHIVE_LOG_ID=${ARCHIVE_LOG_ID} AND STORAGE_LOCATION='MIGFS' AND ROWNUM=1;")
    fi

    # Step 7: VERIFY_ARCHIVE_LOG_COPY
    if [[ -n "${COPY_ID}" ]]; then
        COPY_STATUS=$(mctl_sql "SELECT COPY_STATUS FROM ARCHIVE_LOG_COPY WHERE ARCHIVE_LOG_COPY_ID=${COPY_ID};")
        if [[ "${COPY_STATUS}" != "VERIFIED" ]]; then
            VERIFY_OUT=$(mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.VERIFY_ARCHIVE_LOG_COPY(p_copy_id=>${COPY_ID}, p_checksum=>'${CHECKSUM}');
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('VERIFY_DONE');
END;
/")
            if ! echo "${VERIFY_OUT}" | grep -q 'VERIFY_DONE'; then
                raise_error "VERIFY_ARCHIVE_LOG_COPY failed: COPY_ID=${COPY_ID} output=${VERIFY_OUT}"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                continue
            fi
        fi
        echo "    COPY_ID=${COPY_ID} -> VERIFIED"
    else
        raise_error "REGISTER_ARCHIVE_LOG_COPY failed"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # Step 8: UPSERT_CHECKPOINT（連続した検証済み位置のみ前進）
    CKPT_KEY="THREAD:${THREAD_NO}"
    LAST_CP_SEQ=$(mctl_sql "
SELECT NVL(SEQUENCE_NO,0) FROM MIG_CHECKPOINT
WHERE MIG_RUN_ID=${RUN_ID} AND COMPONENT_NAME='ARCHIVE_COLLECTOR'
  AND CHECKPOINT_KEY='${CKPT_KEY}' AND ROWNUM=1;")
    LAST_CP_SEQ="${LAST_CP_SEQ:-0}"
    EXPECTED_NEXT=$((LAST_CP_SEQ + 1))

    if [[ "${SEQ_NO}" -eq "${EXPECTED_NEXT}" ]]; then
        mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.UPSERT_CHECKPOINT(
        p_run_id    => ${RUN_ID},
        p_component => 'ARCHIVE_COLLECTOR',
        p_key       => '${CKPT_KEY}',
        p_thread_no => ${THREAD_NO},
        p_seq_no    => ${SEQ_NO},
        p_scn       => ${NEXT_SCN}
    );
    COMMIT;
END;
/" > /dev/null 2>&1 || true
        echo "    UPSERT_CHECKPOINT: Seq=${SEQ_NO} SCN=${NEXT_SCN}"
    else
        echo "    UPSERT_CHECKPOINT: SKIP（Seq=${SEQ_NO} > ${EXPECTED_NEXT}、連番欠落あり）"
    fi

    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))

done <<< "${SRC_LOG_DATA}"

echo ""
echo "=== 完了: 総数=${TOTAL_COUNT} 成功=${SUCCESS_COUNT} エラー=${ERROR_COUNT} ==="
