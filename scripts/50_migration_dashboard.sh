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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
-- 運用閾値（ops_config）：警告色の判定に使用
SELECT 'CFG_TR_AGE_WARN='||param_value     FROM cdc_schema.ops_config WHERE param_key='transform_age_warn_sec';
SELECT 'CFG_TR_AGE_CRIT='||param_value     FROM cdc_schema.ops_config WHERE param_key='transform_age_crit_sec';
SELECT 'CFG_PENDING_WARN='||param_value    FROM cdc_schema.ops_config WHERE param_key='pending_xfer_warn';
SELECT 'CFG_ARCH_WARN_DAYS='||param_value  FROM cdc_schema.ops_config WHERE param_key='arch_retention_warn_days';
SELECT 'CFG_ARCH_CRIT_DAYS='||param_value  FROM cdc_schema.ops_config WHERE param_key='arch_retention_crit_days';
SELECT 'CFG_FRA_WARN='||param_value        FROM cdc_schema.ops_config WHERE param_key='fra_warn_pct';
SELECT 'CFG_FRA_CRIT='||param_value        FROM cdc_schema.ops_config WHERE param_key='fra_crit_pct';
SELECT 'CFG_INTERVAL='||param_value        FROM cdc_schema.ops_config WHERE param_key='cdc_interval_sec';
SELECT 'CFG_BATCH='||param_value           FROM cdc_schema.ops_config WHERE param_key='transform_batch_rows';
-- FRA(リドログ/アーカイブ領域)使用率
SELECT 'FRA_LIMIT_MB='||ROUND(NVL(space_limit,0)/1024/1024,1) FROM v\$recovery_file_dest WHERE rownum=1;
SELECT 'FRA_USED_MB='||ROUND(NVL(space_used,0)/1024/1024,1)   FROM v\$recovery_file_dest WHERE rownum=1;
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
-- LOB再同期状況（11章）
SELECT 'LOB_PENDING='||NVL(COUNT(*),0) FROM staging_ctl.lob_resync_target WHERE resync_status='PENDING';
SELECT 'LOB_INTRANSIT='||NVL(COUNT(*),0) FROM staging_ctl.lob_resync_target WHERE resync_status='IN_TRANSIT';
SELECT 'LOB_DONE='||NVL(COUNT(*),0) FROM staging_ctl.lob_resync_target WHERE resync_status='DONE';
SELECT 'LOB_LAST_RESOLVED='||NVL(TO_CHAR(MAX(resolved_at),'MM-DD HH24:MI:SS'),'-') FROM staging_ctl.lob_resync_target WHERE resync_status='DONE';
SELECT 'LOB_REVIEW_PENDING='||NVL(COUNT(*),0) FROM staging_ctl.delta_manual_review_queue WHERE review_status='PENDING' AND fallback_reason='TABLE_HAS_LOB';
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

# ---- 閾値判定（ops_config 由来）----
# fcls: 値を warn/crit と比較し ok/warn/ng/muted を返す（float対応・awk）
#   direction=high → 大きいほど悪い（鮮度・未搬送）/ low → 小さいほど悪い（保持日数）
fcls() { awk -v v="$1" -v w="$2" -v c="$3" -v d="$4" 'BEGIN{
  if(v==""||v=="-"||w==""||c==""){print "muted"; exit}
  if(d=="high"){ if(v+0>=c+0)print"ng"; else if(v+0>=w+0)print"warn"; else print"ok" }
  else        { if(v+0<=c+0)print"ng"; else if(v+0<=w+0)print"warn"; else print"ok" }
}'; }

# FRA 使用率（%）。limit<=0（FRA未構成）は NA
FRA_LIMIT=$(gv FRA_LIMIT_MB); FRA_USED=$(gv FRA_USED_MB)
FRA_PCT=$(awk -v u="${FRA_USED:-0}" -v l="${FRA_LIMIT:-0}" 'BEGIN{ if(l+0<=0){print "NA"} else {printf "%.1f", u/l*100} }')

# 各カードの状態クラス
TR_AGE_CLS=$(fcls "${TR_AGE}"    "$(gv CFG_TR_AGE_WARN)"  "$(gv CFG_TR_AGE_CRIT)" high)
PENDING_CLS=$(fcls "${PENDING_XFER}" "$(gv CFG_PENDING_WARN)" "$(gv CFG_PENDING_WARN)" high)
ARCH_CLS=$(fcls "$(gv ARCH_DAYS)" "$(gv CFG_ARCH_WARN_DAYS)" "$(gv CFG_ARCH_CRIT_DAYS)" low)
if [ "${FRA_PCT}" = "NA" ]; then FRA_CLS="muted"; else FRA_CLS=$(fcls "${FRA_PCT}" "$(gv CFG_FRA_WARN)" "$(gv CFG_FRA_CRIT)" high); fi
# クラス→日本語ラベル
clslabel() { case "$1" in ok) echo "正常";; warn) echo "警告";; ng) echo "危険";; *) echo "—";; esac; }

# 技術名 → IT初心者向けの日本語名
jp_table() { case "${1^^}" in
  REGIONS) echo "地域";; CUSTOMERS) echo "顧客";; ORDERS) echo "注文";;
  ORDER_ENRICHED) echo "注文（拡張）";; SYSTEM_EVENTS) echo "システムイベント";;
  *) echo "$1";; esac; }
jp_class() { case "$1" in
  PASS_THROUGH) echo "そのままコピー";; LIGHT_TRANSFORM) echo "軽い変換";;
  HEAVY_TRANSFORM) echo "重い変換";; *) echo "$1";; esac; }
jp_mode()  { case "$1" in INITIAL) echo "全件";; DELTA) echo "差分";; *) echo "${1:--}";; esac; }
jp_stat()  { case "$1" in SUCCESS) echo "成功";; FAILED) echo "失敗";; RUNNING) echo "実行中";; *) echo "${1:--}";; esac; }

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
# 派生表（注文（拡張）は 注文 件数と比較）
recon_derived() { # label tgt expect
  local label="$1" t="$2" e="$3" cls badge
  if [ "$t" = "$e" ]; then cls="ok"; badge="一致"; else cls="ng"; badge="不一致"; fi
  echo "<tr><td>${label}</td><td class=num>-</td><td class=num>-</td><td class=num>${t}</td><td class=\"badge ${cls}\">${badge} (=注文 ${e})</td></tr>"
}

RECON_ROWS="$(recon_row 地域 "$(gv SRC_REGIONS)"   "$(gv STG_REGIONS)"   "$(gv TGT_REGIONS)")
$(recon_row 顧客 "$(gv SRC_CUSTOMERS)" "$(gv STG_CUSTOMERS)" "$(gv TGT_CUSTOMERS)")
$(recon_row 注文 "$(gv SRC_ORDERS)"    "$(gv STG_ORDERS)"    "$(gv TGT_ORDERS)")
$(recon_derived "注文（拡張）" "$(gv TGT_ORDER_ENRICHED)" "$(gv TGT_ORDERS)")"

# LOB再同期状況の整理
LOB_PENDING=$(gv LOB_PENDING)
LOB_INTRANSIT=$(gv LOB_INTRANSIT)
LOB_DONE=$(gv LOB_DONE)
LOB_LAST_RESOLVED=$(gs LOB_LAST_RESOLVED)
LOB_REVIEW_PENDING=$(gv LOB_REVIEW_PENDING)
LOB_STATUS_CLS="ok"
if [ "${LOB_INTRANSIT:-0}" -gt 0 ] 2>/dev/null; then LOB_STATUS_CLS="warn"; fi
if [ "${LOB_REVIEW_PENDING:-0}" -gt 100 ] 2>/dev/null; then LOB_STATUS_CLS="ng"; fi

# 変換ルール表（テーブル名・種類を日本語化）
CATALOG_ROWS=""
while IFS='|' read -r tbl cls last so; do
  [ -z "$tbl" ] && continue
  CATALOG_ROWS+="<tr><td>$(jp_table "$tbl")</td><td>$(jp_class "$cls")</td><td>${last}</td><td class=num>${so}</td></tr>"
done < <(echo "${CATALOG}")

# 直近の変換実行 表（種別・状態を日本語化）
RUNLOG_ROWS=""
while IFS='|' read -r rid rname rmode rstat rstart rcnt; do
  [ -z "$rid" ] && continue
  local_cls="ok"; [ "$rstat" != "SUCCESS" ] && local_cls="ng"
  RUNLOG_ROWS+="<tr><td class=num>${rid}</td><td>${rname}</td><td>$(jp_mode "$rmode")</td><td class=\"badge ${local_cls}\">$(jp_stat "$rstat")</td><td>${rstart}</td><td class=num>${rcnt}</td></tr>"
done < <(echo "${RUNLOG}")

# 鮮度のバー幅（遅延が小さいほど良い。視覚用に簡易スケール）
age_bar() { local s="${1:-0}"; [[ "$s" =~ ^[0-9]+$ ]] || s=0; local w=$((s>120?100:s*100/120)); echo "$w"; }
TR_BARW=$(age_bar "${TR_AGE}")

# ---- 適用REDOログ 確認ページ（直近7日）を生成し、日付ボタンを組み立てる ----
REDO_DIR="$(dirname "${OUT}")/redo"
REDO_BUTTONS=""
if [ -f "${ROOT}/scripts/52_redo_log_view.sh" ]; then
  REDO_DAYS=$(bash "${ROOT}/scripts/52_redo_log_view.sh" "${REDO_DIR}" 7 2000 2>/dev/null)
  for d in ${REDO_DAYS}; do
    REDO_BUTTONS+="<a class=\"neonbtn\" href=\"redo/redo_${d}.html\" target=\"_blank\">${d}</a>"
  done
  [ -n "${REDO_DAYS}" ] && REDO_BUTTONS+="<a class=\"neonbtn pink\" href=\"redo/index.html\" target=\"_blank\">日付一覧をすべて開く ▸</a>"
fi
[ -z "${REDO_BUTTONS}" ] && REDO_BUTTONS="<span class=\"muted\">直近7日に適用された変更はありません</span>"

# ---- HTML 生成 ----
cat > "${OUT}" <<HTML
<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
${META_REFRESH}
<title>移行状況ダッシュボード</title>
<style>
 /* シンプルなサイバー系：黒青ベース＋緑アクセント（ネオン/グロー・赤紫なし） */
 :root{--bg:#0a0f17;--panel:#101826;--line:rgba(120,160,200,.14);
   --green:#3fd17a;--green-dim:#2fae64;--text:#c4cedd;--muted:#6f7c8f;
   --ok:#3fd17a;--warn:#d6a429;--ng:#e0584f}
 *{box-sizing:border-box}
 body{font-family:-apple-system,"Segoe UI","Noto Sans CJK JP","Noto Sans JP",Meiryo,sans-serif;margin:0;
   color:var(--text);background:var(--bg);
   background-image:linear-gradient(rgba(120,160,200,.035) 1px,transparent 1px),
     linear-gradient(90deg,rgba(120,160,200,.035) 1px,transparent 1px);
   background-size:36px 36px}
 header{padding:18px 24px;border-bottom:1px solid var(--line);background:#0c121c}
 h1{margin:0;font-size:20px;letter-spacing:.10em;color:#e6edf7;
   border-left:3px solid var(--green);padding-left:12px}
 .sub{color:var(--muted);font-size:13px;margin-top:6px}
 .wrap{padding:20px 24px;max-width:1100px;margin:0 auto}
 h2{font-size:13px;color:var(--green);border-left:3px solid var(--green);padding:3px 0 3px 12px;margin:28px 0 12px;
   letter-spacing:.10em;text-transform:uppercase}
 .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px}
 .card{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:14px}
 .card .k{font-size:12px;color:#8a97ac;letter-spacing:.02em}
 .card .v{font-size:23px;font-weight:700;margin-top:6px;font-family:"Consolas","SFMono-Regular",monospace;color:#e3eaf4}
 .card .u{font-size:12px;color:var(--muted);margin-left:5px}
 table{width:100%;border-collapse:collapse;border-radius:6px;overflow:hidden;border:1px solid var(--line)}
 th,td{padding:9px 12px;text-align:left;font-size:13px;border-bottom:1px solid var(--line)}
 tr{background:#0f1622}
 th{background:#16202e;color:#aebccd;letter-spacing:.06em;text-transform:uppercase;font-size:12px;
   border-bottom:1px solid rgba(63,209,122,.35)}
 td.num{text-align:right;font-variant-numeric:tabular-nums;font-family:"Consolas","SFMono-Regular",monospace}
 .badge{font-weight:700;border-radius:3px;padding:2px 9px;font-size:12px;letter-spacing:.03em}
 .ok{color:#06210f;background:var(--ok)}
 .ng{color:#fff;background:var(--ng)}
 .warn{color:#241b04;background:var(--warn)}
 .status-big{display:inline-block;font-size:15px;font-weight:700;border-radius:5px;padding:5px 14px;letter-spacing:.03em}
 .bar{height:8px;background:rgba(120,160,200,.12);border-radius:3px;overflow:hidden;margin-top:8px}
 .bar>i{display:block;height:100%;background:var(--green)}
 .muted{color:var(--muted);font-size:12px}
 .btnrow{display:flex;flex-wrap:wrap;gap:10px;margin-top:4px}
 .neonbtn{display:inline-block;text-decoration:none;font-size:13px;font-weight:700;letter-spacing:.03em;
   padding:9px 16px;border-radius:5px;color:var(--green);border:1px solid var(--green-dim);
   background:rgba(63,209,122,.07);transition:.15s}
 .neonbtn:hover{color:#06210f;background:var(--green)}
 .neonbtn.pink{color:#aebccd;border-color:var(--line);background:#16202e}
 .neonbtn.pink:hover{color:#06210f;background:var(--green);border-color:var(--green)}
 code{color:var(--green);background:rgba(63,209,122,.08);padding:1px 5px;border-radius:3px}
</style></head><body>
<header><h1>データ移行 状況ダッシュボード</h1>
<div class="sub">生成時刻: ${GEN_AT}　|　実行名: ${RUN}　|　連携処理の状態: <span class="status-big ${HEALTH_CLS}">${HEALTH}</span>　|　テーブル構成の凍結: <span class="status-big ${DDL_CLS}">${DDL_STATUS}</span>$([ "${REFRESH}" -gt 0 ] 2>/dev/null && echo "　|　自動更新 ${REFRESH}秒ごと")</div>
<div class="sub" style="margin-top:6px">移行元データベース（1.0）→ 移行先データベース（2.0）｜ スキーマ: 1.0（移行元）→ 1.0（移行先の写し）→ 2.0（変換後）</div></header>
<div class="wrap">

<h2>A. 反映の遅れ・鮮度（どれだけ最新の状態か）</h2>
<div class="cards">
 <div class="card"><div class="k">抽出の遅れ（移行元1.0の最新 − 抽出済み）</div><div class="v">${EXTRACT_LAG}<span class="u">変更番号</span></div></div>
 <div class="card"><div class="k">適用の遅れ（抽出済み − 移行先へ適用済み）</div><div class="v">${APPLY_LAG}<span class="u">変更番号</span></div></div>
 <div class="card"><div class="k">未搬送の差分（移行元 − 移行先） <span class="badge ${PENDING_CLS}">$(clslabel ${PENDING_CLS})</span></div><div class="v">${PENDING_XFER}<span class="u">件</span></div>
   <div class="muted">警告ライン: $(gv CFG_PENDING_WARN) 件</div></div>
 <div class="card"><div class="k">移行先2.0の鮮度（最終変換からの経過） <span class="badge ${TR_AGE_CLS}">$(clslabel ${TR_AGE_CLS})</span></div><div class="v">${TR_AGE}<span class="u">秒</span></div>
   <div class="bar"><i style="width:${TR_BARW}%"></i></div>
   <div class="muted">最終変換: $(gs TRANSFORM_MIN_AT) ｜ 警告:$(gv CFG_TR_AGE_WARN)秒 / 危険:$(gv CFG_TR_AGE_CRIT)秒</div></div>
</div>

<h2>B. 件数の突き合わせ（★移行OKの判断基準：移行元1.0 ＝ 移行先1.0 ＝ 移行先2.0）</h2>
<table><tr><th>テーブル</th><th class=num>移行元1.0</th><th class=num>移行先1.0</th><th class=num>移行先2.0</th><th>判定</th></tr>
${RECON_ROWS}
</table>

<h2>C. 連携処理の健全性</h2>
<div class="cards">
 <div class="card"><div class="k">適用に失敗した処理（取引単位）</div><div class="v">$(gv APPLY_FAILED)</div></div>
 <div class="card"><div class="k">適用台帳の失敗</div><div class="v">$(gv LEDGER_FAILED)</div></div>
 <div class="card"><div class="k">変換エラー件数</div><div class="v">$(gv ERROR_COUNT)</div></div>
 <div class="card"><div class="k">テーブル構成の変更検知</div><div class="v"><span class="badge ${DDL_CLS}">${DDL_STATUS}</span></div>
   <div class="muted">移行中にテーブル定義が変わっていないか監視</div></div>
</div>
<h2 style="font-size:13px;border:none;color:#94a3b8;margin:14px 0 6px">直近の変換実行（履歴）</h2>
<table><tr><th class=num>実行番号</th><th>名称</th><th>種別</th><th>状態</th><th>開始時刻</th><th class=num>移行先件数</th></tr>
${RUNLOG_ROWS}
</table>

<h2>D. テーブルごとの変換ルール</h2>
<table><tr><th>対象テーブル</th><th>変換の種類</th><th>最終変換時刻</th><th class=num>順序</th></tr>
${CATALOG_ROWS}
</table>

<h2>E. LOBテーブル差分再同期の状況</h2>
<div class="cards">
 <div class="card"><div class="k">再同期 待機中(PENDING)</div><div class="v">${LOB_PENDING}</div>
   <div class="muted">scripts/43_lob_resync_cycle.sh を実行すると消化されます</div></div>
 <div class="card"><div class="k">搬送中(IN_TRANSIT)</div><div class="v">${LOB_INTRANSIT}</div>
   <div class="muted">前回のサイクルが途中で終了した行。0になっていれば正常</div></div>
 <div class="card"><div class="k">再同期完了(DONE)</div><div class="v">${LOB_DONE}</div>
   <div class="muted">最終完了: ${LOB_LAST_RESOLVED}</div></div>
 <div class="card"><div class="k">手動キュー内 LOB待ち</div><div class="v">${LOB_REVIEW_PENDING}</div>
   <div class="muted">review_queue で TABLE_HAS_LOB かつ PENDING な件数。lob_resync_build_targets で集約されます</div></div>
</div>

<h2>F. アーカイブログ / リドログ領域(FRA) の保持リスク（過去の変更をさかのぼれる範囲・空き）</h2>
<div class="cards">
 <div class="card"><div class="k">いま残っている変更履歴ファイル数</div><div class="v">$(gv ARCH_COUNT)<span class="u">本</span></div>
   <div class="muted">削除されずに残っているアーカイブログ（変更履歴）の本数</div></div>
 <div class="card"><div class="k">変更履歴の合計サイズ</div><div class="v">$(gv ARCH_MB)<span class="u">MB</span></div></div>
 <div class="card"><div class="k">さかのぼれる期間 <span class="badge ${ARCH_CLS}">$(clslabel ${ARCH_CLS})</span></div><div class="v">$(gv ARCH_DAYS)<span class="u">日分</span></div>
   <div class="muted">最古〜最新の履歴がカバーする日数。短いと差分の取りこぼしリスク（警告:$(gv CFG_ARCH_WARN_DAYS)日 / 危険:$(gv CFG_ARCH_CRIT_DAYS)日 未満）</div></div>
 <div class="card"><div class="k">リドログ領域(FRA)の使用率 <span class="badge ${FRA_CLS}">$(clslabel ${FRA_CLS})</span></div><div class="v">${FRA_PCT}<span class="u">%</span></div>
   <div class="muted">$([ "${FRA_PCT}" = "NA" ] && echo "FRA未設定" || echo "${FRA_USED}/${FRA_LIMIT} MB ｜ 警告:$(gv CFG_FRA_WARN)% / 危険:$(gv CFG_FRA_CRIT)%")</div></div>
 <div class="card"><div class="k">最古 → 最新</div><div class="v" style="font-size:14px">$(gs ARCH_OLDEST) → $(gs ARCH_NEWEST)</div></div>
</div>
<p class="muted" style="margin-top:8px">【設定】警告のしきい値・反映の間隔（$(gv CFG_INTERVAL)秒）・変換のまとめ件数（$(gv CFG_BATCH)件）は <code>scripts/61_ops_config.sh</code> で変更できます。</p>

<h2>G. 適用した変更（REDO）ログの確認 — 直近7日</h2>
<p class="muted" style="margin-top:-4px">日付ボタンを押すと、その日に移行先へ適用した変更（追加／更新／削除の SQL 全文）を別画面で開きます。画面内で絞り込み検索もできます。</p>
<div class="btnrow">${REDO_BUTTONS}</div>

<p class="muted" style="margin-top:30px">移行元1.0 現在番号=$(gs SRC_CURRENT_SCN) / 抽出済み=$(gs EXTRACT_SCN) / 移行先へ適用済み=$(gs APPLY_SCN) / 基準点(baseline)=$(gs BASELINE)　|　抽出の状態=$(gs EXTRACT_STATUS)（最終 $(gs EXTRACT_LASTRUN)）/ 適用の最終 $(gs APPLY_LASTRUN)</p>
</div></body></html>
HTML

echo "ダッシュボード生成: ${OUT}"
