#!/usr/bin/env bash
# DDL凍結検知（G7）: 移行期間中に移行元の追跡対象テーブルへ DDL が発生していないか検知
#
# 背景: LogMiner は辞書(テーブル定義)で REDO を SQL に復元する。移行期間中に ALTER TABLE 等の
#   DDL が走ると辞書とデータがズレ、差分が復元不能になりサイレント破損する。
#   そこで「DDL凍結」を運用ルールとし、破られたら検知する安全弁。
#
# 検知方式: dba_objects.last_ddl_time を基準(snapshot)と比較。基準より新しければ DDL 発生。
#
# 使い方:
#   bash scripts/60_ddl_freeze.sh snapshot   # 凍結基準を現在の last_ddl_time で記録（G1時/凍結開始時）
#   bash scripts/60_ddl_freeze.sh check      # 基準以降に DDL があったか検査（既定）
#   bash scripts/60_ddl_freeze.sh count      # 違反テーブル数のみ出力（ダッシュボード等から）
#
# 終了コード: check は違反ありで 2、なしで 0

set -uo pipefail
SRC="oracle-src"
MODE="${1:-check}"

src_sql() { docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'EOF'
$1
EOF" 2>&1; }

case "${MODE}" in
  snapshot)
    echo "[DDL凍結] 基準スナップショット記録（現在の last_ddl_time を baseline に）"
    src_sql "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
MERGE INTO cdc_schema.cdc_table_catalog c
USING (SELECT object_name, last_ddl_time FROM dba_objects
       WHERE owner='SRC_SCHEMA' AND object_type='TABLE') o
ON (c.table_name = o.object_name)
WHEN MATCHED THEN UPDATE SET c.baseline_ddl_time = o.last_ddl_time;
COMMIT;
EXIT;" >/dev/null
    src_sql "
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 120
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT '  '||table_name||' baseline='||TO_CHAR(baseline_ddl_time,'YYYY-MM-DD HH24:MI:SS')
FROM cdc_schema.cdc_table_catalog WHERE is_active='Y' ORDER BY sort_order;"
    echo "[DDL凍結] スナップショット完了"
    ;;

  count)
    # 違反テーブル数のみ（ダッシュボード用）
    src_sql "
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT COUNT(*) FROM cdc_schema.cdc_table_catalog c
JOIN dba_objects o ON o.owner='SRC_SCHEMA' AND o.object_type='TABLE' AND o.object_name=c.table_name
WHERE c.is_active='Y'
  AND (c.baseline_ddl_time IS NULL OR o.last_ddl_time > c.baseline_ddl_time);" | grep -oE '[0-9]+' | tail -1
    ;;

  check)
    echo "=============================================="
    echo " DDL凍結検知（G7）: SRC_SCHEMA 追跡対象テーブル"
    echo "=============================================="
    RES=$(src_sql "
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 160 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT RPAD(c.table_name,16)||' base='||NVL(TO_CHAR(c.baseline_ddl_time,'MM-DD HH24:MI:SS'),'(未設定)')
       ||' now='||TO_CHAR(o.last_ddl_time,'MM-DD HH24:MI:SS')
       ||' '||CASE WHEN c.baseline_ddl_time IS NULL THEN '[基準未設定]'
                   WHEN o.last_ddl_time > c.baseline_ddl_time THEN '[VIOLATION]'
                   ELSE '[OK]' END
FROM cdc_schema.cdc_table_catalog c
JOIN dba_objects o ON o.owner='SRC_SCHEMA' AND o.object_type='TABLE' AND o.object_name=c.table_name
WHERE c.is_active='Y' ORDER BY c.sort_order;")
    echo "${RES}" | sed 's/^/  /'
    VIOL=$(echo "${RES}" | grep -c "VIOLATION" || true)
    echo "----------------------------------------------"
    if [ "${VIOL}" -eq 0 ]; then
      echo "  [PASS] DDL凍結 維持（違反なし）"
      exit 0
    else
      echo "  [ALERT] DDL違反 ${VIOL} 件検出 → 差分が復元不能の恐れ。再初期ロードを検討。"
      exit 2
    fi
    ;;

  *)
    echo "usage: $0 {snapshot|check|count}"; exit 1 ;;
esac
