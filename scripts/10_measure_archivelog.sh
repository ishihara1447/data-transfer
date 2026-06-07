#!/usr/bin/env bash
# Archive log 生成量 / UNDO 保持の計測スクリプト
# PoC: 移行期間中の archive log 生成量を把握し、保持容量・搬送頻度を見積もる
#
# 使い方:
#   bash scripts/10_measure_archivelog.sh           # oracle-src を計測
#   bash scripts/10_measure_archivelog.sh oracle-tgt # 任意コンテナを計測

set -euo pipefail

CONTAINER="${1:-oracle-src}"

echo "=============================================="
echo " Archive Log / UNDO 計測: ${CONTAINER}"
echo "=============================================="

docker exec -u oracle "${CONTAINER}" bash -c \
  "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 100 LINESIZE 140 FEEDBACK OFF

PROMPT ===== 1. ARCHIVELOG モード =====
SELECT log_mode FROM v\$database;

PROMPT
PROMPT ===== 2. UNDO 設定（ORA-01555 リスク評価）=====
SELECT name, value FROM v\$parameter WHERE name IN ('undo_retention','undo_tablespace');
SELECT tablespace_name, ROUND(SUM(bytes)/1024/1024,1) AS mb,
       SUM(DECODE(autoextensible,'YES',1,0)) AS autoext_files
FROM dba_data_files WHERE tablespace_name LIKE 'UNDO%'
GROUP BY tablespace_name;

PROMPT
PROMPT === 2b. 実効UNDO保持(tuned)とロングクエリ最大秒数（直近6計測=約1h）===
SELECT * FROM (
  SELECT TO_CHAR(begin_time,'MM-DD HH24:MI') AS interval_begin,
         tuned_undoretention AS tuned_retention_sec,
         maxquerylen          AS max_query_sec,
         ssolderrcnt          AS ora01555_count
  FROM v\$undostat ORDER BY begin_time DESC
) WHERE rownum <= 6;

PROMPT
PROMPT ===== 3. 時間帯別 archive log 生成量（直近24h, UTC）=====
SELECT TO_CHAR(first_time,'MM-DD HH24') AS hour_utc,
       COUNT(*)                                  AS log_count,
       ROUND(SUM(blocks*block_size)/1024/1024,1) AS mb_generated
FROM v\$archived_log
WHERE first_time > SYSDATE - 1 AND dest_id = 1
GROUP BY TO_CHAR(first_time,'MM-DD HH24')
ORDER BY hour_utc;

PROMPT
PROMPT ===== 4. 日次 archive log 生成量（保持容量見積り用）=====
SELECT TO_CHAR(first_time,'YYYY-MM-DD') AS day_utc,
       COUNT(*)                                  AS log_count,
       ROUND(SUM(blocks*block_size)/1024/1024,1) AS mb_per_day
FROM v\$archived_log
WHERE dest_id = 1
GROUP BY TO_CHAR(first_time,'YYYY-MM-DD')
ORDER BY day_utc;

PROMPT
PROMPT ===== 5. archive log 総量・保持期間 =====
SELECT COUNT(*) AS total_logs,
       ROUND(SUM(blocks*block_size)/1024/1024,1) AS total_mb,
       TO_CHAR(MIN(first_time),'YYYY-MM-DD HH24:MI') AS oldest,
       TO_CHAR(MAX(first_time),'YYYY-MM-DD HH24:MI') AS newest
FROM v\$archived_log WHERE dest_id = 1 AND deleted = 'NO';
EXIT;
SQLEOF" 2>&1

echo ""
echo "=== FRA 物理容量 ==="
docker exec "${CONTAINER}" bash -c 'du -sh /opt/oracle/oradata 2>/dev/null; df -h /opt/oracle 2>/dev/null | tail -1'

echo "=============================================="
echo " 完了"
echo "=============================================="
