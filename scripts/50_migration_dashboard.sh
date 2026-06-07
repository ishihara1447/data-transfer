#!/usr/bin/env bash
# 移行状況 HTML ダッシュボード生成
# 両DB(oracle-src / oracle-tgt)を照会し、自己完結の HTML を生成する。
# 可視化項目:
#   A. 遅延/鮮度  : SCN差(抽出/適用)・transform鮮度・未搬送delta
#   B. 件数照合   : SRC/STAGING/TARGET 件数 + OK/NG（★移行判断基準）
#   C. 健全性     : パイプライン状態・エラー件数・直近run_log
#   D. 変換カタログ: テーブル別 分類/最終変換時刻
#   E. 保持リスク : archive log 最古/最新/総量/保持日数
#
# 使い方: bash scripts/50_migration_dashboard.sh [出力HTMLパス]
# 既定出力: out/migration_dashboard.html

set -uo pipefail
ROOT="/home/ishihara1447/projects/data-transfer"
SRC="oracle-src"; TGT="oracle-tgt"; RUN="delta_run_01"
OUT="${1:-${ROOT}/out/migration_dashboard.html}"
REFRESH="${2:-0}"   # >0 なら HTML に meta refresh を埋め込み自動更新
mkdir -p "$(dirname "${OUT}")"
GEN_AT=$(date '+%Y-%m-%d %H:%M:%S')
META_REFRESH=""
[ "${REFRESH}" -gt 0 ] 2>/dev/null && META_REFRESH="<meta http-equiv=\"refresh\" content=\"${REFRESH}\">"

# ---- SRC 照会 ----
SRC_RAW=$(docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 200
SELECT 'ARCH_COUNT='||COUNT(*) FROM v\$archived_log WHERE deleted='NO' AND dest_id=1;
SELECT 'ARCH_MB='||ROUND(NVL(SUM(blocks*block_size),0)/1024/1024,1) FROM v\$archived_log WHERE deleted='NO' AND dest_id=1;
SELECT 'ARCH_OLDEST='||NVL(TO_CHAR(MIN(first_time),'MM-DD HH24:MI'),'-') FROM v\$archived_log WHERE deleted='NO' AND dest_id=1;
SELECT 'ARCH_NEWEST='||NVL(TO_CHAR(MAX(first_time),'MM-DD HH24:MI'),'-') FROM v\$archived_log WHERE deleted='NO' AND dest_id=1;
SELECT 'ARCH_DAYS='||ROUND(NVL(MAX(first_time)-MIN(first_time),0),1) FROM v\$archived_log WHERE deleted='NO' AND dest_id=1;
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'SRC_CURRENT_SCN='||current_scn FROM v\$database;
SELECT 'EXTRACT_SCN='||last_extracted_commit_scn FROM cdc_schema.delta_extract_state WHERE run_name='${RUN}';
SELECT 'BASELINE='||NVL(TO_CHAR(baseline_scn),'NA') FROM cdc_schema.delta_extract_state WHERE run_name='${RUN}';
SELECT 'EXTRACT_STATUS='||status FROM cdc_schema.delta_extract_state WHERE run_name='${RUN}';
SELECT 'EXTRACT_LASTRUN='||NVL(TO_CHAR(last_run_at,'MM-DD HH24:MI:SS'),'-') FROM cdc_schema.delta_extract_state WHERE run_name='${RUN}';
SELECT 'SRC_DELTA_MAX='||NVL(MAX(delta_id),0) FROM cdc_schema.delta_queue;
SELECT 'SRC_REGIONS='||COUNT(*) FROM src_schema.regions;
SELECT 'SRC_CUSTOMERS='||COUNT(*) FROM src_schema.customers;
SELECT 'SRC_ORDERS='||COUNT(*) FROM src_schema.orders;
SELECT 'DDL_VIOLATIONS='||COUNT(*) FROM cdc_schema.cdc_table_catalog c
 JOIN dba_objects o ON o.owner='SRC_SCHEMA' AND o.object_type='TABLE' AND o.object_name=c.table_name
 WHERE c.is_active='Y' AND (c.baseline_ddl_time IS NULL OR o.last_ddl_time > c.baseline_ddl_time);
EXIT;
EOF" 2>/dev/null)

# ---- TGT 照会 ----
TGT_RAW=$(docker exec -u oracle ${TGT} bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 250
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'APPLY_SCN='||last_applied_commit_scn FROM staging_ctl.delta_apply_state WHERE run_name='${RUN}';
SELECT 'APPLY_FAILED='||NVL(failed_tx_count,0) FROM staging_ctl.delta_apply_state WHERE run_name='${RUN}';
SELECT 'APPLY_LASTRUN='||NVL(TO_CHAR(last_run_at,'MM-DD HH24:MI:SS'),'-') FROM staging_ctl.delta_apply_state WHERE run_name='${RUN}';
SELECT 'TGT_DELTA_MAX='||NVL(MAX(delta_id),0) FROM staging_ctl.delta_queue;
SELECT 'LEDGER_APPLIED='||COUNT(*) FROM staging_ctl.apply_ledger WHERE status='APPLIED';
SELECT 'LEDGER_FAILED='||COUNT(*) FROM staging_ctl.apply_ledger WHERE status='FAILED';
SELECT 'STG_REGIONS='||COUNT(*) FROM staging_schema.regions;
SELECT 'STG_CUSTOMERS='||COUNT(*) FROM staging_schema.customers;
SELECT 'STG_ORDERS='||COUNT(*) FROM staging_schema.orders;
SELECT 'TGT_REGIONS='||COUNT(*) FROM target_schema.regions;
SELECT 'TGT_CUSTOMERS='||COUNT(*) FROM target_schema.customers;
SELECT 'TGT_ORDERS='||COUNT(*) FROM target_schema.orders;
SELECT 'TGT_ORDER_ENRICHED='||COUNT(*) FROM target_schema.order_enriched;
SELECT 'ERROR_COUNT='||COUNT(*) FROM log_schema.migration_error_log;
SELECT 'TRANSFORM_AGE_SEC='||NVL(ROUND((CAST(SYSTIMESTAMP AS DATE)-CAST(MIN(last_transform_at) AS DATE))*86400),0) FROM log_schema.transform_state;
SELECT 'TRANSFORM_MIN_AT='||NVL(TO_CHAR(MIN(last_transform_at),'MM-DD HH24:MI:SS'),'-') FROM log_schema.transform_state;
SELECT 'CATALOG_ROW='||c.tgt_table_name||'|'||c.transform_class||'|'||NVL(TO_CHAR(ts.last_transform_at,'MM-DD HH24:MI:SS'),'-')||'|'||c.sort_order
  FROM log_schema.transform_catalog c LEFT JOIN log_schema.transform_state ts ON ts.tgt_table_name=c.tgt_table_name
  WHERE c.is_active='Y' ORDER BY c.sort_order;
SELECT 'RUNLOG_ROW='||run_id||'|'||run_name||'|'||NVL(run_mode,'-')||'|'||status||'|'||TO_CHAR(started_at,'MM-DD HH24:MI:SS')||'|'||NVL(TO_CHAR(tgt_count),'-')
  FROM (SELECT * FROM log_schema.migration_run_log ORDER BY run_id DESC) WHERE ROWNUM<=8;
EXIT;
EOF" 2>/dev/null)

# ---- パース ----
declare -A M
while IFS='=' read -r k v; do [ -n "$k" ] && M[$k]="$v"; done < <(printf '%s\n%s\n' "${SRC_RAW}" "${TGT_RAW}" | grep -E '^[A-Z_]+=' | grep -vE '^(CATALOG_ROW|RUNLOG_ROW)=')
CATALOG=$(echo "${TGT_RAW}" | grep '^CATALOG_ROW=' | sed 's/^CATALOG_ROW=//')
RUNLOG=$(echo "${TGT_RAW}" | grep '^RUNLOG_ROW=' | sed 's/^RUNLOG_ROW=//')

gv() { echo "${M[$1]:-0}"; }
gs() { echo "${M[$1]:--}"; }
# 整数差（非数値は0）
idiff() { local a="${M[$1]:-0}" b="${M[$2]:-0}"; [[ "$a" =~ ^[0-9]+$ ]] || a=0; [[ "$b" =~ ^[0-9]+$ ]] || b=0; echo $((a-b)); }

EXTRACT_LAG=$(idiff SRC_CURRENT_SCN EXTRACT_SCN)
APPLY_LAG=$(idiff EXTRACT_SCN APPLY_SCN)
PENDING_XFER=$(idiff SRC_DELTA_MAX TGT_DELTA_MAX)
TR_AGE=$(gv TRANSFORM_AGE_SEC)

# 健全性判定（DDL違反も含める）
APPLY_FAILED=$(gv APPLY_FAILED); LEDGER_FAILED=$(gv LEDGER_FAILED); ERROR_COUNT=$(gv ERROR_COUNT)
DDL_VIOL=$(gv DDL_VIOLATIONS)
if [ "${APPLY_FAILED:-0}" = "0" ] && [ "${LEDGER_FAILED:-0}" = "0" ] && [ "${ERROR_COUNT:-0}" = "0" ] && [ "${DDL_VIOL:-0}" = "0" ]; then
  HEALTH="正常"; HEALTH_CLS="ok"
else
  HEALTH="要確認"; HEALTH_CLS="ng"
fi
# DDL凍結バッジ
if [ "${DDL_VIOL:-0}" = "0" ]; then DDL_STATUS="凍結維持"; DDL_CLS="ok"; else DDL_STATUS="違反 ${DDL_VIOL}件"; DDL_CLS="ng"; fi

# 件数照合行 HTML（3way: SRC/STAGING/TARGET）
recon_row() {  # label src stg tgt
  local label="$1" s="$2" g="$3" t="$4" cls badge
  if [ "$s" = "$g" ] && [ "$g" = "$t" ]; then cls="ok"; badge="一致"; else cls="ng"; badge="不一致"; fi
  echo "<tr><td>${label}</td><td class=num>${s}</td><td class=num>${g}</td><td class=num>${t}</td><td class=\"badge ${cls}\">${badge}</td></tr>"
}
# 派生表（order_enriched は orders 件数と比較）
recon_derived() { # label tgt expect
  local label="$1" t="$2" e="$3" cls badge
  if [ "$t" = "$e" ]; then cls="ok"; badge="一致"; else cls="ng"; badge="不一致"; fi
  echo "<tr><td>${label}</td><td class=num>-</td><td class=num>-</td><td class=num>${t}</td><td class=\"badge ${cls}\">${badge} (=orders ${e})</td></tr>"
}

RECON_ROWS="$(recon_row regions   "$(gv SRC_REGIONS)"   "$(gv STG_REGIONS)"   "$(gv TGT_REGIONS)")
$(recon_row customers "$(gv SRC_CUSTOMERS)" "$(gv STG_CUSTOMERS)" "$(gv TGT_CUSTOMERS)")
$(recon_row orders    "$(gv SRC_ORDERS)"    "$(gv STG_ORDERS)"    "$(gv TGT_ORDERS)")
$(recon_derived order_enriched "$(gv TGT_ORDER_ENRICHED)" "$(gv TGT_ORDERS)")"

# カタログ表
CATALOG_ROWS=""
while IFS='|' read -r tbl cls last so; do
  [ -z "$tbl" ] && continue
  CATALOG_ROWS+="<tr><td>${tbl}</td><td>${cls}</td><td>${last}</td><td class=num>${so}</td></tr>"
done < <(echo "${CATALOG}")

# run_log 表
RUNLOG_ROWS=""
while IFS='|' read -r rid rname rmode rstat rstart rcnt; do
  [ -z "$rid" ] && continue
  local_cls="ok"; [ "$rstat" != "SUCCESS" ] && local_cls="ng"
  RUNLOG_ROWS+="<tr><td class=num>${rid}</td><td>${rname}</td><td>${rmode}</td><td class=\"badge ${local_cls}\">${rstat}</td><td>${rstart}</td><td class=num>${rcnt}</td></tr>"
done < <(echo "${RUNLOG}")

# 鮮度のバー幅（遅延が小さいほど良い。視覚用に簡易スケール）
age_bar() { local s="${1:-0}"; [[ "$s" =~ ^[0-9]+$ ]] || s=0; local w=$((s>120?100:s*100/120)); echo "$w"; }
TR_BARW=$(age_bar "${TR_AGE}")

# ---- HTML 生成 ----
cat > "${OUT}" <<HTML
<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
${META_REFRESH}
<title>移行状況ダッシュボード</title>
<style>
 body{font-family:-apple-system,"Segoe UI",Meiryo,sans-serif;margin:0;background:#0f172a;color:#e2e8f0}
 header{background:#1e293b;padding:16px 24px;border-bottom:2px solid #334155}
 h1{margin:0;font-size:20px} .sub{color:#94a3b8;font-size:13px;margin-top:4px}
 .wrap{padding:20px 24px;max-width:1100px;margin:0 auto}
 h2{font-size:15px;color:#cbd5e1;border-left:4px solid #38bdf8;padding-left:10px;margin:26px 0 12px}
 .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px}
 .card{background:#1e293b;border:1px solid #334155;border-radius:8px;padding:14px}
 .card .k{font-size:12px;color:#94a3b8} .card .v{font-size:22px;font-weight:700;margin-top:4px}
 .card .u{font-size:12px;color:#64748b;margin-left:4px}
 table{width:100%;border-collapse:collapse;background:#1e293b;border-radius:8px;overflow:hidden}
 th,td{padding:8px 12px;text-align:left;font-size:13px;border-bottom:1px solid #334155}
 th{background:#334155;color:#cbd5e1} td.num{text-align:right;font-variant-numeric:tabular-nums}
 .badge{font-weight:700;border-radius:4px;padding:2px 8px;font-size:12px}
 .ok{color:#bbf7d0;background:#14532d} .ng{color:#fecaca;background:#7f1d1d} .warn{color:#fde68a;background:#78350f}
 .status-big{display:inline-block;font-size:16px;font-weight:700;border-radius:6px;padding:6px 14px}
 .bar{height:8px;background:#334155;border-radius:4px;overflow:hidden;margin-top:6px}
 .bar>i{display:block;height:100%;background:#38bdf8}
 .muted{color:#64748b;font-size:12px}
</style></head><body>
<header><h1>🔄 移行状況ダッシュボード</h1>
<div class="sub">生成: ${GEN_AT}　|　run: ${RUN}　|　パイプライン: <span class="status-big ${HEALTH_CLS}">${HEALTH}</span>　|　DDL凍結: <span class="status-big ${DDL_CLS}">${DDL_STATUS}</span>$([ "${REFRESH}" -gt 0 ] 2>/dev/null && echo "　|　自動更新 ${REFRESH}s")</div></header>
<div class="wrap">

<h2>A. 遅延 / 鮮度（ニアリアルタイム健全性）</h2>
<div class="cards">
 <div class="card"><div class="k">抽出ラグ (SRC最新SCN − 抽出済)</div><div class="v">${EXTRACT_LAG}<span class="u">SCN</span></div></div>
 <div class="card"><div class="k">適用ラグ (抽出済 − 適用済SCN)</div><div class="v">${APPLY_LAG}<span class="u">SCN</span></div></div>
 <div class="card"><div class="k">未搬送 delta (src − tgt delta_id)</div><div class="v">${PENDING_XFER}<span class="u">件</span></div></div>
 <div class="card"><div class="k">TARGET 鮮度 (最終変換からの経過)</div><div class="v">${TR_AGE}<span class="u">秒</span></div>
   <div class="bar"><i style="width:${TR_BARW}%"></i></div>
   <div class="muted">最終変換: $(gs TRANSFORM_MIN_AT)</div></div>
</div>

<h2>B. 件数照合（★移行判断基準: SRC = STAGING = TARGET）</h2>
<table><tr><th>テーブル</th><th class=num>SRC</th><th class=num>STAGING</th><th class=num>TARGET</th><th>判定</th></tr>
${RECON_ROWS}
</table>

<h2>C. パイプライン健全性</h2>
<div class="cards">
 <div class="card"><div class="k">適用失敗 Tx</div><div class="v">$(gv APPLY_FAILED)</div></div>
 <div class="card"><div class="k">台帳 FAILED</div><div class="v">$(gv LEDGER_FAILED)</div></div>
 <div class="card"><div class="k">変換エラー件数</div><div class="v">$(gv ERROR_COUNT)</div></div>
 <div class="card"><div class="k">DDL凍結違反 (G7)</div><div class="v"><span class="badge ${DDL_CLS}">${DDL_STATUS}</span></div>
   <div class="muted">移行期間中の ALTER 等を検知</div></div>
</div>
<h2 style="font-size:13px;border:none;color:#94a3b8;margin:14px 0 6px">直近の変換実行 (migration_run_log)</h2>
<table><tr><th class=num>run</th><th>名称</th><th>mode</th><th>状態</th><th>開始</th><th class=num>tgt件数</th></tr>
${RUNLOG_ROWS}
</table>

<h2>D. テーブル別 変換カタログ</h2>
<table><tr><th>TARGET表</th><th>変換分類</th><th>最終変換時刻</th><th class=num>順序</th></tr>
${CATALOG_ROWS}
</table>

<h2>E. archive log 保持リスク（差分が読める期間）</h2>
<div class="cards">
 <div class="card"><div class="k">保持本数</div><div class="v">$(gv ARCH_COUNT)</div></div>
 <div class="card"><div class="k">総量</div><div class="v">$(gv ARCH_MB)<span class="u">MB</span></div></div>
 <div class="card"><div class="k">保持期間</div><div class="v">$(gv ARCH_DAYS)<span class="u">日</span></div></div>
 <div class="card"><div class="k">最古 → 最新</div><div class="v" style="font-size:14px">$(gs ARCH_OLDEST) → $(gs ARCH_NEWEST)</div></div>
</div>

<p class="muted" style="margin-top:30px">SRC現在SCN=$(gs SRC_CURRENT_SCN) / 抽出済=$(gs EXTRACT_SCN) / 適用済=$(gs APPLY_SCN) / baseline=$(gs BASELINE)　|　抽出状態=$(gs EXTRACT_STATUS) (最終 $(gs EXTRACT_LASTRUN)) / 適用最終 $(gs APPLY_LASTRUN)</p>
</div></body></html>
HTML

echo "ダッシュボード生成: ${OUT}"
