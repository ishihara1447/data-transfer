# Archive Log / UNDO 計測結果と保持ポリシー（G9/G10）

計測日: 2026-06-07　計測対象: oracle-src（検証環境 21c XE）
計測手段: `scripts/10_measure_archivelog.sh`（現状）+ 制御DML負荷による生成レート実測

> 本書は検証環境の実測値から、本番（12c・5TB・移行期間 数日〜数週間）の
> archive log 保持容量・UNDO 設定を見積もる根拠資料。

---

## 1. 現状計測（検証環境）

| 項目 | 値 | 備考 |
|------|----|----|
| ARCHIVELOG モード | 有効 | 差分抽出の前提 |
| undo_retention | 900 秒 | パラメータ値 |
| UNDO 表領域 | UNDOTBS1 / 120 MB（autoextend有） | ★5TB には過小 |
| 実効 UNDO 保持(tuned) | 約 1900〜2524 秒 | `v$undostat.tuned_undoretention` |
| ロングクエリ最大 | 約 1200〜1850 秒 | `maxquerylen` |
| ORA-01555 発生 | 0 | 現状の負荷では未発生 |
| 日次 archive 生成量 | 約 500〜680 MB/日 | 検証env の通常負荷 |

## 2. 生成レート実測（制御負荷）

`src_schema.customers` を 20,000 行 UPDATE（スカラ列）してコミット後、
ログスイッチ＋強制アーカイブで archive 増分を測定。

| 指標 | 実測値 |
|------|--------|
| 20,000 行 UPDATE の archive 生成 | **100.48 MB** |
| 1 行あたり | **約 5.14 KB/行**（UPDATE・supplemental ALL 有効時） |

> 注: supplemental logging を ALL COLUMNS にしているため、UPDATE でも全列が redo に
> 載り、生成量が大きめに出る。これは LogMiner で SQL_REDO を完全復元するための前提で、
> 本番でも同条件のため、この係数は本番見積りに使える。

---

## 3. 本番（5TB）への外挿と保持ポリシー

### 3.1 archive 保持容量

差分抽出は「移行先で最終適用が終わるまで archive を消してはならない」。
移行期間中の総生成量＝保持すべき容量。

- 生成量は **DML 量 × 約 5 KB/行**（supplemental ALL 前提）で概算。
- 例: 1 日あたり更新 100 万行 → 約 5 GB/日。移行期間 14 日 → **約 70 GB** を最低保持。
- ピーク（バッチ更新等）を考慮し **2〜3 倍のマージン**を見込む。
- **連番欠落チェック**（`v$archived_log.sequence#` の連続性）を日次で実施し、
  欠落＝差分再生不能の兆候として検知する（未実装・推奨）。

### 3.2 保持運用ルール（G10）

1. 移行期間中は **RMAN の archive 削除ポリシーを「適用済みになるまで削除しない」**に固定。
   - 検証環境で「10日でarchive消滅しCDC再開不能」を実体験済み → 恒久設定必須。
2. 搬送台帳（`arch_log_registry` 相当）で「どの sequence# まで移行先に適用済みか」を管理し、
   それ未満のみ削除可とする。
3. FRA 容量監視＋アラート（残量 < N% で警告）。

### 3.3 UNDO 設定（G9 / ORA-01555 対策）

- 初期ロードは Data Pump **FLASHBACK_SCN**（= AS OF SCN）で整合点固定エクスポートする。
  5TB の expdp は長時間（数時間〜）かかり、その間 baseline SCN のスナップショットを
  読み続けるため、**UNDO 保持が初期ロード所要時間を上回る必要**がある。
- 検証環境は undo_retention=900s / UNDO 120MB。実効 tuned は約 2500s 程度だが、
  **5TB 初期ロードには明確に不足**。本番では:
  - `undo_retention` を初期ロード想定時間 + マージン（例: 6〜12 時間 = 21600〜43200 秒）に。
  - UNDO 表領域を**十分大きく**（数十〜数百 GB）し、`RETENTION GUARANTEE` を検討。
  - 初期ロード中の `v$undostat`（tuned_undoretention / ssolderrcnt）を監視。
- ORA-01555（snapshot too old）が出ると初期ロードが中断 → 全やり直しになるため最重要。

---

## 4. 残作業（このテーマ）

- [ ] archive 連番欠落チェックの自動化（日次 `sequence#` 連続性検査）
- [ ] RMAN 削除ポリシーの恒久設定スクリプト化（本番想定）
- [ ] 本番相当のDML量プロファイル取得（業務ピーク時間帯の行更新数）→ 容量の精緻化
- [ ] 初期ロード所要時間の実測（5TB相当）→ undo_retention の確定

---

## 5. 計測の再現

```bash
# 現状計測（モード・UNDO・実効保持・日次/時間別生成量・総量・FRA）
bash scripts/10_measure_archivelog.sh oracle-src

# 生成レート実測は本書 §2 の手順（N行UPDATE → ログスイッチ → archive増分）
```
ダッシュボード（`scripts/50`）のセクションE でも archive 本数/総量/保持日数/最古最新を常時可視化。
