#!/usr/bin/env bash
# 移行管理ダッシュボード生成
#
# migration_ctl スキーマ（移行管理スキーマ）の内容を読み取り、
#   1) 自己完結の単一 HTML  … out/migration_ctl_dashboard.html
#   2) テーブル別 CSV       … out/migration_ctl_csv/*.csv
# を生成する。
#
# HTML は外部参照ゼロ（CDN・API 呼び出しなし）のためインストール不要・Webサーバ不要。
# ダブルクリックでブラウザが開き、メール添付でそのまま配布できる。
# CSV は Excel でピボット等の分析をしたい場合に使う。
#
# 使い方:
#   bash scripts/71_migration_ctl_dashboard.sh            # 最新の移行実行を表示
#   bash scripts/71_migration_ctl_dashboard.sh 3          # MIG_RUN_ID=3 を表示
#   bash scripts/71_migration_ctl_dashboard.sh 3 out.html # 出力先を指定
#
# 本番での注意: 本スクリプトは検証環境の docker exec 経由で接続する。
#               本番では sqlplus の接続文字列を環境に合わせて置き換えること。

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
# shellcheck disable=SC1091
source ./.env

RUN_ID="${1:-}"
OUT="${2:-${ROOT}/out/migration_ctl_dashboard.html}"
CSVDIR="${ROOT}/out/migration_ctl_csv"
TGT="${TGT_CONTAINER:-oracle-tgt}"
mkdir -p "$(dirname "${OUT}")" "${CSVDIR}"

# migration_ctl へ SQL を投げ、結果をパイプ区切りで返す
mctl() {
    docker exec -i "${TGT}" bash -c \
      "sqlplus -S migration_ctl/${MIGRATION_CTL_PASS}@localhost:1521/XEPDB1" <<SQLEOF 2>/dev/null
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 32767 LONG 4000 COLSEP '|'
SET MARKUP CSV ON DELIMITER | QUOTE OFF
$1
EXIT
SQLEOF
}

echo "[1/3] migration_ctl からデータを取得中..."

TABLES="MIGRATION_RUN PHASE_STATUS MIGRATION_OBJECT DATAPUMP_JOB DATAPUMP_JOB_OBJECT DATAPUMP_FILE ARCHIVE_LOG ARCHIVE_LOG_COPY MIG_STATUS_HISTORY ERROR_EVENT VALIDATION_RUN VALIDATION_RESULT"

# 各テーブルを CSV としてホスト側に保存（Excel 用 + HTML 埋め込み元データ）
for t in ${TABLES}; do
    # 存在しないテーブルはスキップ（段階的にテーブルが増えるため）
    exists=$(mctl "SELECT COUNT(*) FROM user_tables WHERE table_name='${t}';" | tr -d ' \r\n')
    if [ "${exists}" != "1" ]; then
        echo "    [skip] ${t}（未作成）"
        continue
    fi
    cols=$(mctl "SELECT LISTAGG(column_name,',') WITHIN GROUP (ORDER BY column_id)
                 FROM user_tab_columns WHERE table_name='${t}';" | tr -d ' \r\n')
    {
        echo "${cols}" | tr '|' ','
        mctl "SET MARKUP CSV ON DELIMITER , QUOTE ON
              SELECT * FROM ${t} ORDER BY 1;" | sed '/^$/d' | sed '1d'
    } > "${CSVDIR}/${t}.csv"
    n=$(($(wc -l < "${CSVDIR}/${t}.csv") - 1))
    echo "    ${t}: ${n} 行 → out/migration_ctl_csv/${t}.csv"
done

echo "[2/3] HTML を生成中..."

python3 - "${RUN_ID}" "${OUT}" "${CSVDIR}" <<'PY'
import sys, os, csv, json, io, datetime

run_id_arg, OUT, CSVDIR = sys.argv[1], sys.argv[2], sys.argv[3]

def load(name):
    p = os.path.join(CSVDIR, name + ".csv")
    if not os.path.exists(p): return []
    with io.open(p, encoding="utf-8", newline="") as f:
        return [dict(r) for r in csv.DictReader(f)]

T = {n: load(n) for n in [
    "MIGRATION_RUN","PHASE_STATUS","MIGRATION_OBJECT","DATAPUMP_JOB","DATAPUMP_JOB_OBJECT",
    "DATAPUMP_FILE","ARCHIVE_LOG","ARCHIVE_LOG_COPY","MIG_STATUS_HISTORY","ERROR_EVENT",
    "VALIDATION_RUN","VALIDATION_RESULT"]}

runs = T["MIGRATION_RUN"]
if not runs:
    print("[NG] MIGRATION_RUN にデータがありません。先に PKG_MIG_ADMIN.CREATE_RUN で実行を作成してください。")
    sys.exit(1)

def rid(r): return str(r.get("MIG_RUN_ID","")).strip()
run = None
if run_id_arg.strip():
    run = next((r for r in runs if rid(r) == run_id_arg.strip()), None)
    if run is None:
        print(f"[NG] MIG_RUN_ID={run_id_arg} が見つかりません。存在する ID: {[rid(r) for r in runs]}")
        sys.exit(1)
else:
    run = sorted(runs, key=lambda r: int(rid(r) or 0))[-1]
RID = rid(run)

def by_run(rows):
    return [r for r in rows if str(r.get("MIG_RUN_ID","")).strip() == RID]

data = {k: by_run(v) for k, v in T.items()}
data["MIGRATION_RUN"] = [run]

PHASES = [("PREP_A","先行準備A 管理スキーマ"),("PREP_B","先行準備B Redo収集開始"),
          ("PHASE1","フェーズ1 全量Export"),("PHASE2","フェーズ2 全量Import"),
          ("PHASE3","フェーズ3 Redo収集"),("PHASE4","フェーズ4 差分反映"),
          ("PHASE5","フェーズ5 1.0→2.0変換")]

payload = {
    "generated": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "run": run, "runs": [{"id": rid(r), "name": r.get("RUN_NAME",""), "type": r.get("RUN_TYPE","")} for r in runs],
    "phases": PHASES, "tables": data,
}

HTML = """<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>移行管理ダッシュボード</title>
<style>
 :root{--bg:#0a0f17;--panel:#101826;--line:rgba(120,160,200,.14);
   --green:#3fd17a;--green-dim:#2fae64;--text:#c4cedd;--muted:#6f7c8f;
   --ok:#3fd17a;--warn:#d6a429;--ng:#e0584f;--idle:#54637a}
 *{box-sizing:border-box}
 body{font-family:-apple-system,"Segoe UI","Noto Sans CJK JP","Noto Sans JP",Meiryo,sans-serif;margin:0;
   color:var(--text);background:var(--bg);
   background-image:linear-gradient(rgba(120,160,200,.035) 1px,transparent 1px),
     linear-gradient(90deg,rgba(120,160,200,.035) 1px,transparent 1px);
   background-size:36px 36px}
 header{padding:18px 24px;border-bottom:1px solid var(--line);background:#0c121c}
 h1{margin:0;font-size:20px;letter-spacing:.10em;color:#e6edf7;border-left:3px solid var(--green);padding-left:12px}
 .sub{color:var(--muted);font-size:13px;margin-top:6px}
 .wrap{padding:20px 24px;max-width:1180px;margin:0 auto}
 h2{font-size:13px;color:var(--green);border-left:3px solid var(--green);padding:3px 0 3px 12px;
   margin:30px 0 12px;letter-spacing:.10em;text-transform:uppercase}
 .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px}
 .card{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:14px}
 .card .k{font-size:12px;color:#8a97ac}
 .card .v{font-size:21px;font-weight:700;margin-top:6px;
   font-family:"Consolas","SFMono-Regular",monospace;color:#e3eaf4;word-break:break-all}
 .card .u{font-size:12px;color:var(--muted);margin-left:5px}
 .tw{overflow-x:auto;border:1px solid var(--line);border-radius:6px}
 table{width:100%;border-collapse:collapse;min-width:640px}
 th,td{padding:8px 12px;text-align:left;font-size:13px;border-bottom:1px solid var(--line);white-space:nowrap}
 tr{background:#0f1622}
 th{background:#16202e;color:#aebccd;letter-spacing:.05em;font-size:12px;
   border-bottom:1px solid rgba(63,209,122,.35);cursor:pointer;user-select:none;position:sticky;top:0}
 th:hover{color:var(--green)}
 td.num{text-align:right;font-variant-numeric:tabular-nums;font-family:"Consolas","SFMono-Regular",monospace}
 .badge{font-weight:700;border-radius:3px;padding:2px 9px;font-size:12px;display:inline-block}
 .b-ok{color:#06210f;background:var(--ok)} .b-ng{color:#fff;background:var(--ng)}
 .b-warn{color:#241b04;background:var(--warn)} .b-run{color:#04121f;background:#54b8e0}
 .b-idle{color:#cdd6e2;background:#2a3648}
 .ph{display:grid;grid-template-columns:220px 1fr 120px;gap:10px;align-items:center;margin-bottom:7px}
 .ph .nm{font-size:13px;color:#aebccd}
 .ph .tr{height:20px;background:rgba(120,160,200,.10);border-radius:3px;overflow:hidden;position:relative}
 .ph .tr>i{display:block;height:100%;width:0}
 .muted{color:var(--muted);font-size:12px}
 .note{background:#0d1420;border:1px solid var(--line);border-left:3px solid var(--warn);
   border-radius:5px;padding:12px 14px;font-size:13px;margin:14px 0;color:#b9c5d4}
 input[type=search]{background:#0d1420;border:1px solid var(--line);color:var(--text);
   border-radius:5px;padding:7px 11px;font-size:13px;width:260px}
 .row{display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin-bottom:10px}
 .empty{padding:16px;color:var(--muted);font-size:13px;background:#0f1622}
 footer{padding:18px 24px;border-top:1px solid var(--line);color:var(--muted);font-size:12px}
 code{background:#0d1420;border:1px solid var(--line);border-radius:3px;padding:1px 5px;font-size:12px}
</style></head><body>
<header>
  <h1>移行管理ダッシュボード</h1>
  <div class="sub" id="hdr"></div>
</header>
<div class="wrap" id="app"></div>
<footer>
  migration_ctl スキーマの内容を静的HTMLに埋め込んだものです。外部通信は行いません。<br>
  再生成: <code>bash scripts/71_migration_ctl_dashboard.sh</code> ／
  Excel 用CSV: <code>out/migration_ctl_csv/</code>
</footer>
<script id="data" type="application/json">__DATA__</script>
<script>
const D = JSON.parse(document.getElementById('data').textContent);
const $ = (h) => { const d=document.createElement('div'); d.innerHTML=h.trim(); return d.firstChild; };
const esc = (s) => (s==null?'':String(s)).replace(/[&<>"]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

const CLS = {
  COMPLETED:'b-ok', DONE:'b-ok', VERIFIED:'b-ok', PASS:'b-ok', ARCHIVE_READY:'b-ok', BASELINE_FIXED:'b-ok',
  RUNNING:'b-run', EXPORTING:'b-run', IMPORTING:'b-run', IN_PROGRESS:'b-run', RECEIVED:'b-run',
  FAILED:'b-ng', CORRUPT:'b-ng', LOST:'b-ng', MISSING:'b-ng', ABORTED:'b-ng', FAIL:'b-ng',
  RETRY:'b-warn', PAUSED:'b-warn', WARN:'b-warn', EXPECTED:'b-idle', PLANNED:'b-idle',
  NOT_STARTED:'b-idle', PENDING:'b-idle', CREATED:'b-idle', IN_SCOPE:'b-idle', READY:'b-idle'
};
const badge = (v) => v ? `<span class="badge ${CLS[v]||'b-idle'}">${esc(v)}</span>` : '';
const NUMCOL = /(_ID|_SCN|COUNT|ROWS|BYTES|_NO|SIZE|SEQUENCE|THREAD)/;

function table(rows, cols, opts={}) {
  if (!rows || !rows.length) return `<div class="empty">データがありません</div>`;
  cols = cols || Object.keys(rows[0]);
  const head = cols.map(c=>`<th>${esc(c)}</th>`).join('');
  const body = rows.map(r=>'<tr>'+cols.map(c=>{
    const v = r[c];
    if (/STATUS|RESULT|FLAG$/.test(c) && v && /^[A-Z_]+$/.test(v) && v!=='Y' && v!=='N') return `<td>${badge(v)}</td>`;
    return `<td class="${NUMCOL.test(c)?'num':''}">${esc(v)}</td>`;
  }).join('')+'</tr>').join('');
  const id = 'T'+Math.random().toString(36).slice(2,8);
  return `<div class="row">${opts.search!==false?`<input type="search" placeholder="絞り込み…" oninput="filt('${id}',this.value)">`:''}
    <span class="muted">${rows.length} 件</span></div>
    <div class="tw"><table id="${id}"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
}
function filt(id, q){
  q = q.toLowerCase();
  document.querySelectorAll(`#${id} tbody tr`).forEach(tr=>{
    tr.style.display = tr.textContent.toLowerCase().includes(q) ? '' : 'none';
  });
}
document.addEventListener('click', e=>{
  if (e.target.tagName!=='TH') return;
  const th=e.target, tb=th.closest('table'), i=[...th.parentNode.children].indexOf(th);
  const asc = tb.dataset.sc==String(i) ? tb.dataset.sa!=='1' : true;
  tb.dataset.sc=i; tb.dataset.sa=asc?'1':'0';
  const rows=[...tb.querySelectorAll('tbody tr')];
  rows.sort((a,b)=>{
    const x=a.children[i].textContent.trim(), y=b.children[i].textContent.trim();
    const nx=parseFloat(x), ny=parseFloat(y);
    const c = (!isNaN(nx)&&!isNaN(ny)) ? nx-ny : x.localeCompare(y,'ja');
    return asc?c:-c;
  });
  rows.forEach(r=>tb.querySelector('tbody').appendChild(r));
});

const run = D.run, T = D.tables;
document.getElementById('hdr').innerHTML =
  `生成 ${esc(D.generated)} ／ 実行 <b>${esc(run.RUN_NAME)}</b>（MIG_RUN_ID=${esc(run.MIG_RUN_ID)}・${esc(run.RUN_TYPE)}）`
  + (D.runs.length>1 ? ` ／ 他 ${D.runs.length-1} 件の実行あり（<code>bash scripts/71_migration_ctl_dashboard.sh &lt;ID&gt;</code> で切替）` : '');

const app = document.getElementById('app');
const sec = (t,h)=>app.appendChild($(`<section><h2>${t}</h2>${h}</section>`));
const card = (k,v,u)=>`<div class="card"><div class="k">${k}</div><div class="v">${v||'—'}${u?`<span class="u">${u}</span>`:''}</div></div>`;

// A. 実行サマリ
sec('A. 移行実行サマリ', `<div class="cards">
  ${card('全体状態', badge(run.STATUS))}
  ${card('基準SCN <span class="u">BASELINE</span>', esc(run.BASELINE_SCN))}
  ${card('解析開始SCN <span class="u">MINING_START</span>', esc(run.MINING_START_SCN))}
  ${card('最終同期SCN <span class="u">TARGET_END</span>', esc(run.TARGET_END_SCN))}
  ${card('最終適用SCN <span class="u">LAST_APPLIED</span>', esc(run.LAST_APPLIED_SCN))}
</div>
<div class="note"><b>SCNの読み方</b>：<b>解析開始SCN ≦ 基準SCN</b> でなければなりません。
基準SCNを跨ぐ長時間トランザクションを取りこぼさないため、解析は基準SCNより前から始めます。
最終適用SCNが最終同期SCNに到達した時点で差分反映は完了です。</div>`);

// B. フェーズ進捗
const ps = {}; (T.PHASE_STATUS||[]).forEach(r=>ps[r.PHASE_CODE]=r);
const W = {NOT_STARTED:0, RUNNING:55, PAUSED:55, COMPLETED:100, FAILED:100};
const C = {COMPLETED:'var(--ok)', RUNNING:'var(--green-dim)', PAUSED:'var(--warn)',
           FAILED:'var(--ng)', NOT_STARTED:'transparent'};
sec('B. フェーズ進捗', D.phases.map(([code,label])=>{
  const r = ps[code], st = r ? r.STATUS : 'NOT_STARTED';
  return `<div class="ph"><div class="nm">${esc(label)}</div>
    <div class="tr"><i style="width:${W[st]||0}%;background:${C[st]||'transparent'}"></i></div>
    <div>${badge(st)}</div></div>`;
}).join('') + `<div class="muted" style="margin-top:8px">
  先行準備B とフェーズ3（Redo収集）は最終切替まで RUNNING のまま継続します。</div>`);

// C. 対象オブジェクト
sec('C. 移行対象オブジェクト', table(T.MIGRATION_OBJECT,
  ['MIG_OBJECT_ID','SOURCE_OWNER','SOURCE_TABLE_NAME','STAGE_TABLE_NAME','TARGET_TABLE_NAME',
   'FULL_LOAD_FLAG','CDC_FLAG','TRANSFORM_FLAG','HAS_LOB_FLAG','EXPORT_GROUP_CODE',
   'ESTIMATED_ROWS','STATUS'].filter(c=>(T.MIGRATION_OBJECT[0]||{}).hasOwnProperty(c))));

// D. Data Pump
sec('D. Data Pump ジョブ', table(T.DATAPUMP_JOB,
  ['DATAPUMP_JOB_ID','JOB_NAME','OPERATION','STATUS','BASELINE_SCN','PARALLEL',
   'DIRECTORY_NAME','PROCESSED_ROWS','ERROR_COUNT','STARTED_AT','FINISHED_AT']
  .filter(c=>(T.DATAPUMP_JOB[0]||{}).hasOwnProperty(c))));
sec('D-2. Data Pump ファイル', table(T.DATAPUMP_FILE,
  ['DATAPUMP_FILE_ID','DATAPUMP_JOB_ID','FILE_ROLE','FILE_NAME','STORAGE_LOCATION',
   'FILE_SIZE_BYTES','CHECKSUM_VALUE','STATUS']
  .filter(c=>(T.DATAPUMP_FILE[0]||{}).hasOwnProperty(c))));

// E. アーカイブログ
sec('E. アーカイブログ（論理）', table(T.ARCHIVE_LOG,
  ['ARCHIVE_LOG_ID','THREAD_NO','SEQUENCE_NO','FIRST_CHANGE_SCN','NEXT_CHANGE_SCN',
   'DICTIONARY_BEGIN_FLAG','DICTIONARY_END_FLAG','COLLECT_STATUS','MINING_STATUS']
  .filter(c=>(T.ARCHIVE_LOG[0]||{}).hasOwnProperty(c))));
sec('E-2. アーカイブログ（物理コピー）', table(T.ARCHIVE_LOG_COPY,
  ['ARCHIVE_LOG_COPY_ID','ARCHIVE_LOG_ID','STORAGE_LOCATION','FILE_PATH',
   'CHECKSUM_VALUE','COPY_STATUS']
  .filter(c=>(T.ARCHIVE_LOG_COPY[0]||{}).hasOwnProperty(c))));

// F. 検証・エラー
if ((T.VALIDATION_RUN||[]).length) sec('F. 検証実行', table(T.VALIDATION_RUN));
if ((T.VALIDATION_RESULT||[]).length) sec('F-2. 検証結果', table(T.VALIDATION_RESULT));
sec('G. エラーイベント', (T.ERROR_EVENT||[]).length
  ? table(T.ERROR_EVENT)
  : `<div class="empty">未解消のエラーはありません</div>`);

// H. 履歴
sec('H. 状態変更履歴', table(T.MIG_STATUS_HISTORY,
  ['HISTORY_ID','TABLE_NAME','RECORD_ID','OLD_STATUS','NEW_STATUS','CHANGED_BY','CHANGED_AT','NOTE']
  .filter(c=>(T.MIG_STATUS_HISTORY[0]||{}).hasOwnProperty(c))));
</script></body></html>"""

html = HTML.replace("__DATA__", json.dumps(payload, ensure_ascii=False).replace("</", "<\\/"))
io.open(OUT, "w", encoding="utf-8").write(html)
print(f"    実行 MIG_RUN_ID={RID} ({run.get('RUN_NAME','')}) を出力")
print(f"    HTML: {OUT}  ({len(html)//1024} KB)")
PY

rc=$?
if [ ${rc} -ne 0 ]; then
    echo "[NG] HTML 生成に失敗しました"
    exit ${rc}
fi

echo "[3/3] 完了"
echo ""
echo "  ダッシュボード : ${OUT}"
echo "                   （Webサーバ不要。ダブルクリックでブラウザが開きます）"
echo "  Excel 用 CSV   : ${CSVDIR}/"
