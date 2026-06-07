#!/usr/bin/env bash
# ==============================================================
# oracle-tgt 上で差分を適用する
#
# 処理概要:
#   1. SYS.cdc_apply_delta を CDB$ROOT コンテキストで呼び出す
#      (LogMiner は CDB$ROOT からのみ実行可能)
#   2. 実行後に sys.redo_sync_state の状態を表示する
#   3. STAGING_SCHEMA の各テーブル件数を表示する
#
# 前提:
#   - 04_sync_archivelogs.sh で oracle-tgt の /opt/oracle/redo_from_src/
#     に archive log を搬送済みであること
#   - sys.arch_log_registry (XEPDB1) にファイルのメタ情報が登録済みであること
#     (file_name / sequence_no / first_change_no / next_change_no を INSERT)
#   - 22_logminer_on_tgt.sql を oracle-tgt にデプロイ済みであること
#
# 使い方:
#   bash scripts/05_apply_delta_on_tgt.sh
# ==============================================================

set -euo pipefail

CONTAINER="oracle-tgt"

echo "=== Step 1: SYS.cdc_apply_delta を実行 ==="
# CDB$ROOT で接続し、プロシージャを呼び出す
# SYS.cdc_apply_delta は AUTHID CURRENT_USER かつ CDB$ROOT に格納されているため
# '/ as sysdba' (= CDB$ROOT 接続) から呼び出す必要がある
docker exec -u oracle "${CONTAINER}" bash -c \
  "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON

BEGIN
    SYS.cdc_apply_delta;
END;
/
SQLEOF"

echo ""
echo "=== Step 2: redo_sync_state の状態確認 ==="
docker exec -u oracle "${CONTAINER}" bash -c \
  "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 30
SET LINESIZE 200
SET FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;

PROMPT --- sys.redo_sync_state ---
SELECT state_id,
       last_applied_scn,
       status,
       TO_CHAR(last_run_at, 'YYYY-MM-DD HH24:MI:SS') AS last_run_at,
       SUBSTR(error_message, 1, 80)                   AS error_message
FROM   sys.redo_sync_state
ORDER  BY state_id;

EXIT;
SQLEOF"

echo ""
echo "=== Step 3: STAGING_SCHEMA テーブル件数確認 ==="
docker exec -u oracle "${CONTAINER}" bash -c \
  "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 30
SET LINESIZE 80
SET FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;

PROMPT --- STAGING_SCHEMA table counts (from dba_tables stats) ---
SELECT table_name,
       TO_CHAR(NVL(num_rows, 0), '999,999,999') AS approx_rows,
       TO_CHAR(last_analyzed, 'YYYY-MM-DD HH24:MI:SS') AS last_analyzed
FROM   dba_tables
WHERE  owner = 'STAGING_SCHEMA'
ORDER  BY table_name;

PROMPT
PROMPT NOTE: approx_rows reflects last ANALYZE / DBMS_STATS.
PROMPT       For exact counts run: SELECT COUNT(*) FROM staging_schema.<table>;

EXIT;
SQLEOF"
