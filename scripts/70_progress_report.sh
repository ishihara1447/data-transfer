#!/usr/bin/env bash
# 進捗レポート生成
#
# docs/progress.yml（唯一の正）から docs/master-checklist.md を再生成し、
# docs/progress-history.tsv に当日の件数スナップショットを記録する。
#
# 使い方:
#   bash scripts/70_progress_report.sh          # 生成＋履歴記録
#   bash scripts/70_progress_report.sh --check   # 生成せず件数だけ表示（CI/確認用）
#
# 注意: docs/master-checklist.md は自動生成物。直接編集しないこと。
#       進捗を変えるときは docs/progress.yml の status / evidence / note を編集する。

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

MODE="${1:-generate}"

python3 - "${MODE}" <<'PY'
import sys, os, yaml, datetime
from collections import Counter, defaultdict

MODE = sys.argv[1] if len(sys.argv) > 1 else "generate"
YML  = "docs/progress.yml"
MD   = "docs/master-checklist.md"
HIST = "docs/progress-history.tsv"

doc   = yaml.safe_load(open(YML, encoding="utf-8"))
items = doc["items"]

MARK  = {"done":"✅","in_progress":"🟡","todo":"❌","blocked_env":"🔴"}
ORDER = ["done","in_progress","todo","blocked_env"]
PHASE = {
 "P1":"フェーズ1：初回全量 Data Pump Export",
 "P2":"フェーズ2：初回全量 Data Pump Import",
 "P3":"フェーズ3：Archived Redo Log 出力・収集",
 "P4":"フェーズ4：Archived Redo 解析・1.0スキーマ差分反映",
 "P5":"フェーズ5：1.0スキーマ→2.0スキーマ 変換投入",
}

# --- 妥当性チェック -------------------------------------------------------
errs = []
seen = set()
for it in items:
    if it["id"] in seen: errs.append(f"{it['id']}: ID重複")
    seen.add(it["id"])
    if it["status"] not in MARK: errs.append(f"{it['id']}: 不正なstatus '{it['status']}'")
    if it["status"] == "done" and not str(it.get("evidence","")).strip():
        errs.append(f"{it['id']}: status=done だが evidence が空（どのスクリプトでいつ確認したかを書くこと）")
if errs:
    print("[NG] progress.yml に問題があります:")
    for e in errs: print("   -", e)
    sys.exit(1)

cnt = Counter(it["status"] for it in items)
per = defaultdict(Counter)
for it in items: per[it["phase"]][it["status"]] += 1
total = len(items)
deliv = sum(len(it.get("deliverables") or []) for it in items)
actionable = total - cnt["blocked_env"]
done_rate  = cnt["done"] * 100.0 / total

print(f"決定・検証事項 {total}件 / 成果物 {deliv}件")
print(f"  ✅完了 {cnt['done']}  🟡着手 {cnt['in_progress']}  ❌未着手 {cnt['todo']}  🔴本環境不可 {cnt['blocked_env']}")
print(f"  完了率 {done_rate:.1f}%  この環境で進められる母数 {actionable}件")

if MODE == "--check":
    sys.exit(0)

# --- 履歴の記録（同日は上書き） -------------------------------------------
today = datetime.date.today().isoformat()
rows = []
if os.path.exists(HIST):
    for line in open(HIST, encoding="utf-8").read().splitlines():
        if line.strip() and not line.startswith("date\t"):
            rows.append(line.split("\t"))
rows = [r for r in rows if r[0] != today]
rows.append([today, str(cnt["done"]), str(cnt["in_progress"]), str(cnt["todo"]),
             str(cnt["blocked_env"]), str(total), f"{done_rate:.1f}"])
rows.sort(key=lambda r: r[0])
with open(HIST, "w", encoding="utf-8") as f:
    f.write("date\tdone\tin_progress\ttodo\tblocked_env\ttotal\tdone_pct\n")
    for r in rows: f.write("\t".join(r) + "\n")

# --- master-checklist.md の生成 -------------------------------------------
o = []
o.append(f"""# マスターチェックリスト — 決定・検証事項と成果物の全件一覧

<!-- このファイルは scripts/70_progress_report.sh による自動生成物です。直接編集しないでください。 -->
<!-- 進捗を変更するときは docs/progress.yml を編集し、上記スクリプトを再実行してください。 -->

最終更新: {today}
出典: {doc['meta']['source']}
目的: **母数を把握する**。本番移行までに決めること・検証すること・作ることの総量と、現時点の消化状況を1か所に集約する。

> 各項目の中身は出典の設計メモを参照してください（原典はこのリポジトリに含まれません。[`handoff-guide.md`](handoff-guide.md) §7）。
> 信頼度の考え方（✅検証済み / 🟡仮決定 / 🔴本番未検証）は [`handoff-guide.md`](handoff-guide.md) を参照。

---

## 1. 母数サマリ

| 区分 | 件数 |
|---|---:|
| **決定・検証事項** | **{total} 件** |
| **成果物（延べ）** | **{deliv} 件** |
| 完了率 | **{done_rate:.1f}%** |
| この環境で進められる母数 | {actionable} 件（{total} − 本環境では不可 {cnt['blocked_env']}） |

### 1.1 フェーズ別の内訳

| フェーズ | 件数 | ✅完了 | 🟡着手・部分 | ❌未着手 | 🔴本環境では不可 |
|---|---:|---:|---:|---:|---:|""")
for p in ["P1","P2","P3","P4","P5"]:
    c = per[p]
    o.append(f"| {PHASE[p]} | {sum(c.values())} | {c['done']} | {c['in_progress']} | {c['todo']} | {c['blocked_env']} |")
o.append(f"| **合計** | **{total}** | **{cnt['done']}** | **{cnt['in_progress']}** | **{cnt['todo']}** | **{cnt['blocked_env']}** |")

pri = Counter(it["priority"] for it in items)
pri_done = Counter(it["priority"] for it in items if it["status"] == "done")
o.append(f"""
### 1.2 優先度別（設計メモの定義）

| 優先度 | 意味 | 件数 | うち完了 |
|---|---|---:|---:|
| A | 移行方式の成立、データ欠落防止、早期着手を左右する | {pri['A']} | {pri_done['A']} |
| B | 性能、停止期間、再実行性、運用品質へ大きく影響する | {pri['B']} | {pri_done['B']} |
| C | 詳細実装または長期運用として必要になる | {pri['C']} | {pri_done['C']} |

---

## 2. 推移（バーンダウン）

`scripts/70_progress_report.sh` を実行するたびに記録されます（同日は上書き）。

| 日付 | ✅完了 | 🟡着手 | ❌未着手 | 🔴不可 | 完了率 |
|---|---:|---:|---:|---:|---:|""")
for r in rows:
    o.append(f"| {r[0]} | {r[1]} | {r[2]} | {r[3]} | {r[4]} | {r[6]}% |")

if len(rows) >= 2:
    d = int(rows[-1][1]) - int(rows[0][1])
    o.append(f"\n> 記録開始（{rows[0][0]}）からの完了件数の増加: **{d:+d}件**")
else:
    o.append("\n> 記録は開始されたばかりです。2回目以降の実行で推移が見えます。")

o.append(f"""
---

## 3. 決定・検証事項 一覧（{total}件）

凡例: ✅完了 / 🟡着手・部分的 / ❌未着手 / 🔴本環境では検証不可
""")
for p in ["P1","P2","P3","P4","P5"]:
    o.append(f"\n### 3.{p[1]} {PHASE[p]}\n")
    o.append("| ID | 優 | 種別 | 決めること・検証すること | 現状 | 根拠・補足 |")
    o.append("|---|:-:|---|---|:-:|---|")
    for it in items:
        if it["phase"] != p: continue
        note = it.get("note") or ""
        ev   = str(it.get("evidence") or "").strip()
        if ev: note = (note + " ／ " if note else "") + f"**根拠**: {ev}"
        o.append(f"| {it['id']} | {it['priority']} | {it['kind']} | {it['title']} | {MARK[it['status']]} | {note} |")

o.append(f"""
---

## 4. 成果物 一覧（延べ {deliv} 件）

各決定・検証事項が要求する成果物です。**同名・類似のものは実務上まとめられる**ため、
実際に作るファイル数はこれより少なくなります（母数の把握用）。
""")
for p in ["P1","P2","P3","P4","P5"]:
    sub = [it for it in items if it["phase"] == p]
    n = sum(len(it.get("deliverables") or []) for it in sub)
    o.append(f"\n### 4.{p[1]} {PHASE[p]}（{n}件）\n")
    o.append("| 出典ID | 現状 | 成果物 |")
    o.append("|---|:-:|---|")
    for it in sub:
        dl = it.get("deliverables") or []
        o.append(f"| {it['id']} | {MARK[it['status']]} | {' ／ '.join(dl) if dl else '（記載なし）'} |")

o.append("""
---

## 5. 成果物の性質別まとめ

作るものの「種類」で見ると、大きく4つに分かれます。着手順を考える際の目安にしてください。

| 性質 | 例 | この環境で作れるか |
|---|---|---|
| **① 一覧・台帳** | 移行対象テーブル一覧、特殊データ型一覧、ジョブ分割一覧、テーブル依存関係図 | 🟡 形式は作れるが、**中身は本番の実データを見ないと埋まらない** |
| **② 設計文書・仕様** | SCN境界設計、DML適用共通仕様、チェックポイント仕様、エラー管理仕様 | ✅ 作れる。この環境の主戦場 |
| **③ SQL・スクリプト** | DIRECTORY作成SQL、権限付与SQL、検証SQL、監視手順、初期化SQL | ✅ 作れる。動作確認まで可能 |
| **④ 試験結果・実測値** | 容量実測、性能測定、並列度、追付き可否、UNDO試算、リハーサル結果 | 🔴 **作れない。** 規模・構成が違うため数値に意味がない |

> **④は本番相当環境が必要**です。この環境で出した数値を本番設計に使わないでください。
> ①は「様式（フォーマット）」だけ先に作っておき、本番データで埋める運用が現実的です。

---

## 6. 運用ルール

- **`docs/progress.yml` が唯一の正**。このMarkdownは自動生成物なので直接編集しない
- 進捗を変えるときは `progress.yml` の `status` / `evidence` / `note` を更新し、
  `bash scripts/70_progress_report.sh` を実行してからコミットする
- **`status: done` にするには `evidence` が必須**（空だとスクリプトがエラーで止まる）。
  「どのスクリプトで・いつ確認したか」を書くこと
- 🟡の項目は [`handoff-guide.md`](handoff-guide.md) §4 の仮決定台帳と対応する。社内で決め直す対象
- 🔴の項目は本番相当環境での実施計画に載せる
- 設計メモ §9.1「直ちに合意する事項」17項目、§14「直近の判断ポイント」5項目もこの一覧に含まれている。
  個別管理せず、この表を正とする

---

## 7. 関連文書

- [`handoff-guide.md`](handoff-guide.md) — 信頼度の区別・仮決定台帳・本番未検証台帳
- [`phase1-2-deliverables-and-flow.md`](phase1-2-deliverables-and-flow.md) — フェーズ1・2の実行資材とプロセスフロー
- [`gap-analysis-5phase-schema.md`](gap-analysis-5phase-schema.md) — 新設計と現行実装のギャップ
- [`migration-control-schema-design.md`](migration-control-schema-design.md) — 移行管理スキーマ設計書
""")

open(MD, "w", encoding="utf-8").write("\n".join(o))
print(f"[OK] {MD} を再生成しました")
print(f"[OK] {HIST} に {today} のスナップショットを記録しました")

# --- README のサマリ差し込み ---------------------------------------------
README = "README.md"
BEG, END = "<!-- PROGRESS:START -->", "<!-- PROGRESS:END -->"
bar_w = 24

def bar(done, total):
    n = int(round(done * bar_w / total)) if total else 0
    return "█" * n + "░" * (bar_w - n)

r = [BEG,
     "",
     f"本番移行までに必要な**決定・検証事項 {total} 件**（成果物 延べ {deliv} 件）の消化状況です。",
     f"一覧は [`docs/master-checklist.md`](docs/master-checklist.md)、判断の根拠は [`docs/handoff-guide.md`](docs/handoff-guide.md) を参照。",
     "",
     f"```",
     f"完了率  {done_rate:5.1f}%   {bar(cnt['done'], total)}  {cnt['done']} / {total}",
     f"```",
     "",
     "| | ✅完了 | 🟡着手・部分 | ❌未着手 | 🔴本環境では不可 | 計 |",
     "|---|---:|---:|---:|---:|---:|"]
for p in ["P1","P2","P3","P4","P5"]:
    c = per[p]
    r.append(f"| {PHASE[p].split('：')[0]} | {c['done']} | {c['in_progress']} | {c['todo']} | {c['blocked_env']} | {sum(c.values())} |")
r.append(f"| **合計** | **{cnt['done']}** | **{cnt['in_progress']}** | **{cnt['todo']}** | **{cnt['blocked_env']}** | **{total}** |")
r += ["",
      f"> 🔴 {cnt['blocked_env']}件は規模・構成の違いにより**この検証環境では実施できません**（本番相当環境が必要）。",
      f"> したがってこの環境で進められる母数は **{actionable}件** です。",
      "",
      f"<sub>最終更新 {today} ／ `bash scripts/70_progress_report.sh` で自動更新（手で編集しないこと）</sub>",
      "",
      END]

if os.path.exists(README):
    src = open(README, encoding="utf-8").read()
    block = "\n".join(r)
    if BEG in src and END in src:
        head, rest = src.split(BEG, 1)
        _, tail = rest.split(END, 1)
        open(README, "w", encoding="utf-8").write(head + block + tail)
        print(f"[OK] {README} の進捗サマリを更新しました")
    else:
        print(f"[--] {README} に {BEG} / {END} マーカーがないためスキップしました")
PY
