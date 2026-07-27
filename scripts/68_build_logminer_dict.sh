#!/usr/bin/env bash
# LogMiner 辞書ビルド・マーカー確認・ARCHIVE_LOG 更新スクリプト
#
# 目的: oracle-src の CDB$ROOT で LogMiner Dictionary を Redo に埋め込み、
#       マーカー付きログを収集・台帳登録する。
#
# 引数: --run-id <MIG_RUN_ID>  (必須)
#
# 処理フロー (docs/phase3-design.md §6.2):
#   1. oracle-src CDB$ROOT で DBMS_LOGMNR_D.BUILD を実行
#      （ALTER SESSION SET CONTAINER は絶対に使用しない）
#   2. ALTER SYSTEM ARCHIVE LOG CURRENT でログスイッチ
#   3. V$ARCHIVED_LOG で DICTIONARY_BEGIN/DICTIONARY_END マーカーを確認
#   4. マーカーなし = エラー出力して exit 1（RAISE_ERROR_EVENT で記録）
#   5. マーカー付きログを /migfs/archivelogs/ へコピー（コンテナ内 cp）
#   6. REGISTER_ARCHIVE_LOG -> RECEIVE -> REGISTER_COPY -> VERIFY
#   7. SET_DICT_MARKERS で DICTIONARY_BEGIN_FLAG/DICTIONARY_END_FLAG を 'Y' に更新
#
# 最も危険な罠（docs/phase3-design.md §7 ノウハウ #1）:
#   PDB 内（XEPDB1）で BUILD を実行すると PL/SQL は正常終了するが
#   辞書が Redo に書き込まれない。V$ARCHIVED_LOG の DICTIONARY_BEGIN/DICTIONARY_END
#   マーカーで必ず確認すること。

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

echo "=== 68_build_logminer_dict.sh: RUN_ID=${RUN_ID} ==="

# ============================================================
# /migfs/archivelogs/ ディレクトリの確認・作成（コンテナ内で作成）
# ============================================================
docker exec oracle-src bash -c "mkdir -p /migfs/archivelogs" 2>/dev/null || true

# ============================================================
# ヘルパー関数
# ============================================================

mctl_sql() {
    printf 'SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON\n%s\nEXIT;\n' "$1" | \
        docker exec -i oracle-tgt sqlplus -S "migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1" 2>&1 \
        | grep -v '^[[:space:]]*$' | tail -1 | tr -d ' \t'
}

mctl_sql_raw() {
    printf 'SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON SERVEROUTPUT ON SIZE UNLIMITED\n%s\nEXIT;\n' "$1" | \
        docker exec -i oracle-tgt sqlplus -S "migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1" 2>&1
}

raise_error() {
    local msg="$1"
    echo "  [ERROR] ${msg}"
    mctl_sql_raw "
DECLARE v_id NUMBER;
BEGIN
    PKG_MIG_ADMIN.RAISE_ERROR_EVENT(
        p_run_id         => ${RUN_ID},
        p_phase_code     => 'PHASE3',
        p_severity       => 'ERROR',
        p_component_name => 'LOGMINER_DICT',
        p_error_message  => '${msg:0:200}',
        p_event_id       => v_id
    );
    COMMIT;
END;
/" > /dev/null 2>&1 || true
}

# ============================================================
# Step 1: oracle-src CDB$ROOT で DBMS_LOGMNR_D.BUILD を実行
#
# 重要: CDB$ROOT 接続（sysdba）で実行する。
#       ALTER SESSION SET CONTAINER は絶対に実行しない。
# ============================================================
echo "--- Step 1: CDB\$ROOT で DBMS_LOGMNR_D.BUILD 実行 ---"

BUILD_OUT=$(docker exec -u oracle oracle-src bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET FEEDBACK OFF SERVEROUTPUT ON SIZE UNLIMITED
BEGIN
    DBMS_LOGMNR_D.BUILD(
        OPTIONS => DBMS_LOGMNR_D.STORE_IN_REDO_LOGS
    );
    DBMS_OUTPUT.PUT_LINE('BUILD_DONE');
END;
/
EXIT;
SQLEOF" 2>&1)

if ! echo "${BUILD_OUT}" | grep -q 'BUILD_DONE'; then
    raise_error "DBMS_LOGMNR_D.BUILD failed: ${BUILD_OUT}"
    echo "FAILED: DBMS_LOGMNR_D.BUILD に失敗しました。" >&2
    exit 1
fi
echo "  DBMS_LOGMNR_D.BUILD 完了"

# ============================================================
# Step 2: ALTER SYSTEM ARCHIVE LOG CURRENT でログスイッチ
# ============================================================
echo "--- Step 2: ALTER SYSTEM ARCHIVE LOG CURRENT ---"
docker exec -u oracle oracle-src bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET FEEDBACK OFF
ALTER SYSTEM ARCHIVE LOG CURRENT;
SQLEOF" 2>&1 | grep -v '^[[:space:]]*$' | grep -v '^Session' || true
echo "  ログスイッチ完了"
sleep 2

# ============================================================
# Step 3: V$ARCHIVED_LOG でマーカーを確認
# ============================================================
echo "--- Step 3: DICTIONARY_BEGIN/DICTIONARY_END マーカー確認 ---"

MARKER_DATA=$(docker exec -u oracle oracle-src bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 600
SELECT TRIM(TO_CHAR(SEQUENCE#))||'|'||TRIM(NAME)||'|'||TRIM(DICTIONARY_BEGIN)||'|'||TRIM(DICTIONARY_END)||'|'||TRIM(TO_CHAR(FIRST_CHANGE#))||'|'||TRIM(TO_CHAR(NEXT_CHANGE#))||'|'||TRIM(TO_CHAR(RESETLOGS_ID))||'|'||TRIM(TO_CHAR(THREAD#))
FROM V\$ARCHIVED_LOG
WHERE STATUS='A'
  AND NAME IS NOT NULL
  AND (DICTIONARY_BEGIN='YES' OR DICTIONARY_END='YES')
ORDER BY SEQUENCE#;
EXIT;
SQLEOF" 2>&1 | grep -v '^[[:space:]]*$' | grep '|')

if [[ -z "${MARKER_DATA}" ]]; then
    raise_error "LogMiner dictionary markers not found. Possible cause: BUILD was run inside PDB instead of CDB root."
    echo "" >&2
    echo "=== エラー: DICTIONARY_BEGIN/DICTIONARY_END マーカーが付きませんでした ===" >&2
    echo "原因: DBMS_LOGMNR_D.BUILD を PDB（XEPDB1）内で実行した可能性があります。" >&2
    echo "対処: CDB\$ROOT（sysdba 接続、ALTER SESSION SET CONTAINER なし）で再実行してください。" >&2
    exit 1
fi

echo "  マーカー付きログ:"
while IFS='|' read -r SEQ_NO FILE_PATH D_BGN D_END FC_SCN NC_SCN RST_ID THR_NO; do
    echo "    Seq=${SEQ_NO} D_BGN=${D_BGN} D_END=${D_END} Path=$(basename ${FILE_PATH})"
done <<< "${MARKER_DATA}"

# ============================================================
# SOURCE_DBID を取得
# ============================================================
SOURCE_DBID=$(docker exec -u oracle oracle-src bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SELECT DBID FROM V\$DATABASE;
EXIT;
SQLEOF" 2>&1 | grep -v '^[[:space:]]*$' | tail -1 | tr -d ' \t')

# ============================================================
# Step 5-7: マーカー付きログの収集・台帳登録
# ============================================================
echo "--- Step 5-7: マーカー付きログの収集・台帳登録 ---"

while IFS='|' read -r SEQ_NO FILE_PATH D_BGN D_END FIRST_SCN NEXT_SCN RESETLOGS_ID THREAD_NO; do
    [[ -z "${SEQ_NO}" ]] && continue

    FILE_NAME=$(basename "${FILE_PATH}")
    DEST_PATH="/migfs/archivelogs/${FILE_NAME}"

    echo ""
    echo "  処理中: Seq=${SEQ_NO} D_BGN=${D_BGN} D_END=${D_END}"

    # Step 5: REGISTER_ARCHIVE_LOG（重複は -20002 → 再取得）
    REGISTER_OUT=$(mctl_sql_raw "
DECLARE v_id NUMBER;
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
        ARCHIVE_LOG_ID=$(mctl_sql "
SELECT ARCHIVE_LOG_ID FROM ARCHIVE_LOG
WHERE MIG_RUN_ID=${RUN_ID} AND SOURCE_RESETLOGS_ID=${RESETLOGS_ID}
  AND THREAD_NO=${THREAD_NO} AND SEQUENCE_NO=${SEQ_NO} AND ROWNUM=1;")
        echo "    既登録: ARCHIVE_LOG_ID=${ARCHIVE_LOG_ID}"
    elif [[ -z "${ARCHIVE_LOG_ID}" ]]; then
        raise_error "REGISTER_ARCHIVE_LOG failed: Seq=${SEQ_NO}"
        continue
    else
        echo "    ARCHIVE_LOG_ID=${ARCHIVE_LOG_ID}"
    fi

    # ファイルコピー（コンテナ内 cp）
    if ! docker exec oracle-src bash -c "cp '${FILE_PATH}' '${DEST_PATH}'" 2>/dev/null; then
        raise_error "cp failed: ${FILE_PATH}"
        continue
    fi

    # RECEIVE_ARCHIVE_LOG
    CURRENT_STATUS=$(mctl_sql "SELECT COLLECT_STATUS FROM ARCHIVE_LOG WHERE ARCHIVE_LOG_ID=${ARCHIVE_LOG_ID};")
    if [[ "${CURRENT_STATUS}" == "EXPECTED" ]]; then
        # 注意: / は独立した行に置かないと sqlplus が PL/SQL ブロックを実行しない
        mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.RECEIVE_ARCHIVE_LOG(${ARCHIVE_LOG_ID});
    COMMIT;
END;
/" > /dev/null 2>&1 || true
    fi

    # sha256sum（コンテナ内で実行）
    CHECKSUM=$(docker exec oracle-src bash -c "sha256sum '${DEST_PATH}'" 2>/dev/null | cut -d' ' -f1)
    FILE_SIZE=$(docker exec oracle-src bash -c "stat -c%s '${DEST_PATH}'" 2>/dev/null || echo 0)

    if [[ -z "${CHECKSUM}" ]]; then
        raise_error "sha256sum failed: ${DEST_PATH}"
        continue
    fi

    # REGISTER_ARCHIVE_LOG_COPY
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

    # VERIFY_ARCHIVE_LOG_COPY
    if [[ -n "${COPY_ID}" ]]; then
        COPY_STATUS=$(mctl_sql "SELECT COPY_STATUS FROM ARCHIVE_LOG_COPY WHERE ARCHIVE_LOG_COPY_ID=${COPY_ID};")
        if [[ "${COPY_STATUS}" != "VERIFIED" ]]; then
            # 注意: / は独立した行に置かないと sqlplus が PL/SQL ブロックを実行しない
            mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.VERIFY_ARCHIVE_LOG_COPY(
        p_copy_id  => ${COPY_ID},
        p_checksum => '${CHECKSUM}'
    );
    COMMIT;
END;
/" > /dev/null 2>&1 || true
        fi
    fi

    # Step 7: SET_DICT_MARKERS
    if [[ "${D_BGN}" == "YES" || "${D_END}" == "YES" ]]; then
        DICT_BEGIN_FLAG="N"
        DICT_END_FLAG="N"
        [[ "${D_BGN}" == "YES" ]] && DICT_BEGIN_FLAG="Y"
        [[ "${D_END}" == "YES" ]] && DICT_END_FLAG="Y"

        MARKER_OUT=$(mctl_sql_raw "
BEGIN
    PKG_MIG_ADMIN.SET_DICT_MARKERS(
        p_archive_log_id => ${ARCHIVE_LOG_ID},
        p_dict_begin     => '${DICT_BEGIN_FLAG}',
        p_dict_end       => '${DICT_END_FLAG}'
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('DICT_MARKERS_SET');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('MARKER_ERR='||SQLERRM);
END;
/")
        if echo "${MARKER_OUT}" | grep -q 'DICT_MARKERS_SET'; then
            echo "    SET_DICT_MARKERS: D_BGN=${DICT_BEGIN_FLAG} D_END=${DICT_END_FLAG}"
        else
            echo "    SET_DICT_MARKERS 警告: ${MARKER_OUT}"
        fi
    fi

done <<< "${MARKER_DATA}"

echo ""
echo "=== 68_build_logminer_dict.sh 完了 ==="
