#!/usr/bin/env bash
# 適用した変更（REDO）ログ 確認ページ生成
# 移行先へ適用された変更（LogMiner が取り出した INSERT/UPDATE/DELETE の SQL 全文）を
# 直近 N 日ぶん、日付ごとの HTML として書き出す。ダッシュボード(50)の「F」セクションの
# 日付ボタンから開く想定。HTML は自己完結（サイバーパンク配色・簡易フィルタ付き）。
#
# 使い方:
#   bash scripts/52_redo_log_view.sh [出力ディレクトリ] [日数] [1日あたり最大件数]
#   既定: out/redo  7日  2000件/日
# 標準出力に、生成した日付(YYYY-MM-DD)を1行ずつ返す（50 がボタン生成に使用）。

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TGT="oracle-tgt"
OUTDIR="${1:-${ROOT}/out/redo}"
DAYS="${2:-7}"
MAXROWS="${3:-2000}"
mkdir -p "${OUTDIR}"

sqltgt() {
  docker exec -i -u oracle "${TGT}" bash -c "export NLS_LANG=American_America.AL32UTF8; sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 32767 LONG 8000
SET DEFINE OFF
ALTER SESSION SET CONTAINER = XEPDB1;
$(cat)
EOF" 2>/dev/null
}

# 共通CSS（ダッシュボードと統一したサイバーパンク）
read -r -d '' CSS <<'CSS' || true
<style>
 /* 落ち着いたサイバーパンク（ダッシュボードと統一） */
 :root{--cyan:#79c0cf;--pink:#cf86a4;--purple:#9183c0;--green:#73c79a;--yellow:#cfb978}
 *{box-sizing:border-box}
 body{font-family:-apple-system,"Segoe UI","Noto Sans CJK JP","Noto Sans JP",Meiryo,sans-serif;margin:0;
   color:#c2ccdf;background:#11141d;
   background-image:radial-gradient(circle at 10% -12%,rgba(145,131,192,.12),transparent 45%),
     linear-gradient(rgba(121,192,207,.025) 1px,transparent 1px),
     linear-gradient(90deg,rgba(121,192,207,.025) 1px,transparent 1px);
   background-size:auto,34px 34px,34px 34px}
 .wrap{padding:20px 24px;max-width:1280px;margin:0 auto}
 h1{font-size:19px;letter-spacing:.08em;color:#e6edf7;text-shadow:0 0 6px rgba(121,192,207,.25)}
 .muted{color:#7b86a0;font-size:12px}
 table{width:100%;border-collapse:collapse;border-radius:8px;overflow:hidden;
   border:1px solid rgba(121,192,207,.14);margin-top:10px}
 th,td{padding:7px 10px;text-align:left;font-size:12px;border-bottom:1px solid rgba(121,192,207,.09);vertical-align:top}
 tr{background:#171b27}
 th{background:linear-gradient(90deg,rgba(207,134,164,.16),rgba(145,131,192,.14));color:#dfe6f2;
   letter-spacing:.04em;position:sticky;top:0}
 td.num{text-align:right;font-variant-numeric:tabular-nums;font-family:"Consolas",monospace}
 td.sql{font-family:"Consolas","SFMono-Regular",monospace;color:#a9c6cf;white-space:pre-wrap;word-break:break-all;max-width:680px}
 .op{font-weight:700;border-radius:4px;padding:1px 7px;font-size:11px}
 .ins{color:#0d2419;background:var(--green)} .upd{color:#2a2207;background:var(--yellow)} .del{color:#2a0d16;background:var(--pink)}
 .neonbtn{display:inline-block;text-decoration:none;font-size:13px;font-weight:700;letter-spacing:.03em;
   padding:8px 14px;border-radius:6px;color:#9fd0da;border:1px solid rgba(121,192,207,.55);
   background:rgba(121,192,207,.05)}
 .neonbtn.pink{color:#d9a3b8;border-color:rgba(207,134,164,.55);background:rgba(207,134,164,.05)}
 #flt{background:#1a1f2c;border:1px solid rgba(121,192,207,.5);color:#dde6f4;border-radius:6px;
   padding:8px 12px;font-size:13px;width:340px;margin-top:8px}
</style>
<script>
function fltRows(){var q=document.getElementById('flt').value.toLowerCase();
 document.querySelectorAll('tbody tr').forEach(function(r){
   r.style.display = r.innerText.toLowerCase().indexOf(q)>=0 ? '' : 'none';});}
</script>
CSS

# 対象日（直近DAYS日で適用変更がある日。新しい順）
DAYLIST=$(printf "SELECT TO_CHAR(extracted_at,'YYYY-MM-DD') d FROM staging_ctl.delta_queue WHERE extracted_at >= TRUNC(SYSDATE) - %s GROUP BY TO_CHAR(extracted_at,'YYYY-MM-DD') ORDER BY d DESC;" "${DAYS}" | sqltgt | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')

# 日付一覧ページ用の行を貯める
INDEX_ROWS=""

for day in ${DAYLIST}; do
  # その日の件数
  CNT=$(printf "SELECT COUNT(*) FROM staging_ctl.delta_queue WHERE TO_CHAR(extracted_at,'YYYY-MM-DD')='%s';" "${day}" | sqltgt | grep -oE '[0-9]+' | tail -1)
  CNT=${CNT:-0}

  # 明細行（commit順・最大MAXROWS件）。SQL内でHTMLエスケープ・操作/テーブルを日本語化
  ROWS=$(printf "%s\n" "SELECT * FROM (
    SELECT '<tr><td>'||TO_CHAR(extracted_at,'HH24:MI:SS')||'</td>'||
      '<td class=num>'||commit_scn||'</td>'||
      '<td>'||xid||'</td>'||
      '<td>'||CASE table_name WHEN 'REGIONS' THEN '地域' WHEN 'CUSTOMERS' THEN '顧客' WHEN 'ORDERS' THEN '注文' WHEN 'ORDER_ENRICHED' THEN '注文（拡張）' WHEN 'SYSTEM_EVENTS' THEN 'システムイベント' ELSE table_name END||'</td>'||
      '<td><span class=\"op '||CASE operation WHEN 'INSERT' THEN 'ins' WHEN 'UPDATE' THEN 'upd' WHEN 'DELETE' THEN 'del' ELSE '' END||'\">'||
        CASE operation WHEN 'INSERT' THEN '追加' WHEN 'UPDATE' THEN '更新' WHEN 'DELETE' THEN '削除' ELSE operation END||'</span></td>'||
      '<td class=sql>'||REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(NVL(sql_redo,'(本文なし)'),'&','&amp;'),'<','&lt;'),'>','&gt;'),CHR(10),' '),CHR(13),' ')||'</td></tr>'
    FROM staging_ctl.delta_queue
    WHERE TO_CHAR(extracted_at,'YYYY-MM-DD')='${day}'
    ORDER BY commit_scn, xid, seq_in_tx
  ) WHERE ROWNUM <= ${MAXROWS};" | sqltgt | grep '<tr>')

  TRUNC_NOTE=""
  [ "${CNT}" -gt "${MAXROWS}" ] 2>/dev/null && TRUNC_NOTE="（全 ${CNT} 件のうち先頭 ${MAXROWS} 件を表示）"

  {
    echo "<!DOCTYPE html><html lang=\"ja\"><head><meta charset=\"UTF-8\"><title>適用REDO ${day}</title>"
    echo "${CSS}"
    echo "</head><body><div class=\"wrap\">"
    echo "<h1>適用した変更（REDO）ログ — ${day}</h1>"
    echo "<p class=\"muted\">移行先へ適用された変更を時系列で表示。${day} の適用件数: ${CNT} 件 ${TRUNC_NOTE}</p>"
    echo "<p><a class=\"neonbtn pink\" href=\"../migration_dashboard.html\">← ダッシュボードに戻る</a> <a class=\"neonbtn\" href=\"index.html\">日付一覧</a></p>"
    echo "<input id=\"flt\" placeholder=\"絞り込み（テーブル名・SQL本文などで検索）\" oninput=\"fltRows()\">"
    echo "<table><thead><tr><th>時刻</th><th>変更番号</th><th>取引ID(XID)</th><th>テーブル</th><th>操作</th><th>変更内容（SQL全文）</th></tr></thead><tbody>"
    echo "${ROWS}"
    echo "</tbody></table></div></body></html>"
  } > "${OUTDIR}/redo_${day}.html"

  INDEX_ROWS+="<tr><td><a class=\"neonbtn\" href=\"redo_${day}.html\">${day}</a></td><td class=num>${CNT}</td></tr>"
  echo "${day}"   # 標準出力（50 がボタン生成に使用）
done

# 日付一覧ページ
{
  echo "<!DOCTYPE html><html lang=\"ja\"><head><meta charset=\"UTF-8\"><title>適用REDO 日付一覧</title>"
  echo "${CSS}"
  echo "</head><body><div class=\"wrap\">"
  echo "<h1>適用した変更（REDO）ログ — 日付一覧（直近${DAYS}日）</h1>"
  echo "<p><a class=\"neonbtn pink\" href=\"../migration_dashboard.html\">← ダッシュボードに戻る</a></p>"
  if [ -n "${INDEX_ROWS}" ]; then
    echo "<table><thead><tr><th>日付</th><th>適用件数</th></tr></thead><tbody>${INDEX_ROWS}</tbody></table>"
  else
    echo "<p class=\"muted\">直近${DAYS}日に適用された変更はありません。</p>"
  fi
  echo "</div></body></html>"
} > "${OUTDIR}/index.html"
