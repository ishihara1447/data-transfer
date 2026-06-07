#!/usr/bin/env bash
# DataPump import (oracle-tgt コンテナ内で実行)
# SRC_SCHEMA のダンプを STAGING_SCHEMA にリマップしてインポートする
#
# 使い方:
#   bash scripts/03_datapump_import.sh

set -euo pipefail

CONTAINER="oracle-tgt"
DUMPFILE_PREFIX="src_export"
PARALLEL=2
STAGING_PASS="${STAGING_SCHEMA_PASS:-stagingpass1}"

echo "=== STAGING_SCHEMA ユーザーを確認・作成 ==="
docker exec -u oracle "${CONTAINER}" bash -c \
  "sqlplus -S '/ as sysdba' <<EOF
SET FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_users WHERE username='STAGING_SCHEMA';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE USER staging_schema IDENTIFIED BY ${STAGING_PASS}';
        EXECUTE IMMEDIATE 'GRANT CONNECT, RESOURCE TO staging_schema';
        EXECUTE IMMEDIATE 'ALTER USER staging_schema QUOTA UNLIMITED ON USERS';
        DBMS_OUTPUT.PUT_LINE('staging_schema created.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('staging_schema already exists.');
    END IF;
END;
/
EXIT;
EOF"

echo "=== DataPump import: SRC_SCHEMA → STAGING_SCHEMA ==="
docker exec -u oracle "${CONTAINER}" bash -c \
  "impdp '/ as sysdba' \
     remap_schema=SRC_SCHEMA:STAGING_SCHEMA \
     parallel=${PARALLEL} \
     dumpfile=${DUMPFILE_PREFIX}_%U.dmp \
     logfile=${DUMPFILE_PREFIX}_import.log \
     directory=DATA_PUMP_DIR \
     table_exists_action=REPLACE"

echo "=== import 後の件数確認 ==="
docker exec -u oracle "${CONTAINER}" bash -c \
  "sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 50 LINESIZE 80
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT table_name, num_rows
FROM   dba_tables
WHERE  owner = 'STAGING_SCHEMA'
ORDER  BY table_name;
EXIT;
EOF"

echo "=== 完了 ==="
echo "次のステップ: bash scripts/04_sync_archivelogs.sh"
