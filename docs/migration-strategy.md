# データ移行方式 設計書

## 1. 背景・制約条件

### プロジェクト概要

| 項目 | 内容 |
|------|------|
| データ量 | 約5TB |
| テーブル数 | 約500テーブル |
| 移行期間 | 半年（移行元は引き続き稼働） |
| 業務停止 | 極力回避 |
| ネットワーク | オフライン環境（インターネット不可） |
| DBリンク | 利用困難 |
| GoldenGate | 利用不可 |
| AWS | 利用不可 |
| スキーマ変換 | 一部テーブルは構造変更・データ変換あり（複数テーブル統合等） |

---

## 2. 移行における本質的な課題

「大量データをコピーすること」が課題ではない。

本当の課題は、

**「移行中も更新され続けるデータを、整合性を保ちながら移行すること」**

である。

```
2026/01/01 全量コピー完了
              ↓
         新規登録・更新・削除が発生し続ける
              ↓
         カットオーバーまでの差分をどう吸収するか
```

---

## 3. 検討方式と評価

| 案 | 方式 | 評価 | 理由 |
|----|------|------|------|
| 案1 | DataPumpのみ | **不採用** | 差分反映不可 |
| 案2 | CSVエクスポート | **小規模限定** | 遅い・同一断面保証困難 |
| 案3 | CDCツール（GoldenGate等） | **不採用** | ライセンス不可・オフライン不可 |
| 案4 | **Flashback SCN + DataPump + Redo適用** | **採用** | Oracle標準・5TB対応・同一断面保証 |

---

## 4. 採用方式：Flashback SCN基準 DataPump ＋ 差分Redo適用

### 全体フロー

```
[移行元 Oracle 12c]
        |
   Step1: 基準SCN取得
        |
   Step2: DataPump Export（FLASHBACK_SCN指定）
        |
   ダンプファイル生成（圧縮・並列）
        |
   Step3: オフライン搬送（SSD / NAS / 共有ストレージ）
        |
[移行先 Oracle]
        |
   Step4: DataPump Import → ステージングスキーマ
        |
   Step5: Archived Redo解析（LogMiner）→ 差分収集
        |
   Step6: 差分適用（ステージングに追従）
        |
   Step7: PL/SQL変換（ステージング → 移行先スキーマ）
        |
   Step8: カットオーバー（最終差分反映 → 接続切替）
```

---

## 5. ステージングスキーマが必須な理由

テーブル構造が異なる（複数テーブルを1テーブルに統合するなど複雑な変換あり）ため、
差分データの受け取り口として移行元と同一構造の「ステージングスキーマ」が必要。

```
[移行先DB内部]

  ステージングスキーマ（移行元と同一構造 / 約500テーブル）
      ↓ DataPump Import で初期ロード
      ↓ Archived Redo差分を継続適用
      ↓ PL/SQL変換（カットオーバー時 または 定期バッチ）
  ターゲットスキーマ（移行先の新構造）
```

DBリンクがなくても、ステージングスキーマが差分の受け皿として機能する。

---

## 6. 詳細手順

### Step 1：基準SCN取得

```sql
SELECT CURRENT_SCN FROM V$DATABASE;
-- 例: SCN = 123456789
-- このSCNを移行基準点とする
```

### Step 2：DataPump Export（全量・同一断面）

```bash
expdp system/password \
  schemas=SOURCE_SCHEMA \
  flashback_scn=123456789 \
  parallel=8 \
  compression=all \
  dumpfile=export_%U.dmp \
  logfile=export.log
```

`FLASHBACK_SCN` を指定することで、全500テーブルが同一時刻の断面として取得される。

### Step 3：ダンプ搬送

SSD・NAS・共有ストレージ等でオフライン搬送。

### Step 4：DataPump Import（ステージングスキーマへ）

```bash
impdp system/password \
  remap_schema=SOURCE_SCHEMA:STAGING_SCHEMA \
  parallel=8 \
  dumpfile=export_%U.dmp \
  logfile=import.log
```

### Step 5：差分収集（Archived Redo + LogMiner）

基準SCN以降のArchivedRedoを移行先に搬送し、LogMinerで解析。

```sql
-- LogMiner起動例
DBMS_LOGMNR.START_LOGMNR(
    STARTSCN => 123456789,
    OPTIONS  => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG
              + DBMS_LOGMNR.NO_ROWID_IN_STMT
);

-- 差分取得
SELECT SCN, SEG_OWNER, SEG_NAME, OPERATION, SQL_REDO
FROM V$LOGMNR_CONTENTS
WHERE SEG_OWNER = 'SOURCE_SCHEMA'
  AND OPERATION IN ('INSERT', 'UPDATE', 'DELETE')
ORDER BY SCN;
```

### Step 6：差分適用（ステージングスキーマへ）

LogMinerが生成したSQL_REDOをステージングスキーマへ適用。
FK依存順・SCN昇順で適用することが重要。

### Step 7：PL/SQL変換（ステージング → ターゲット）

カットオーバー直前またはバッチで、ステージングからターゲットスキーマへ変換。
複数テーブル統合など複雑な変換はこのフェーズで実施。

### Step 8：カットオーバー

```
1. 業務を最小時間だけ停止
2. 最終差分をステージングに適用
3. PL/SQL変換（差分分のみ）
4. アプリの接続先を移行先DBへ切り替え
5. 業務再開
```

---

## 7. 成功のための重要条件

### 条件1：UNDO保持（ORA-01555対策）

DataPump Export中に `Snapshot too old` が発生しないよう、
`UNDO_RETENTION` を十分に設定する（Export所要時間の2倍以上を目安）。

```sql
ALTER SYSTEM SET UNDO_RETENTION = 86400; -- 24時間
```

### 条件2：Archive Log保持

差分反映完了まで Archived Redo Log を削除しない。
RMAN の保持ポリシーを緩める、または手動管理に切り替える。

```sql
-- 削除禁止期間の設定例（RMAN）
CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON STANDBY;
```

### 条件3：ディスク容量

| 項目 | 目安 |
|------|------|
| 移行元DB | 5TB |
| ダンプファイル | 1〜4TB（圧縮率による） |
| Archived Redo Log | 数百GB〜数TB（業務量による） |
| ステージングスキーマ | 5TB程度 |
| 作業領域 | 数百GB |

### 条件4：移行期間中のDDL禁止

移行期間中にテーブル追加・列追加・型変更が発生すると差分適用が困難になる。
移行元・移行先ともにDDL変更を凍結すること。

---

## 8. PoC（事前検証）項目

| PoC | 確認内容 | 合格基準（目安） |
|-----|----------|----------------|
| PoC1 | DataPump Export所要時間・圧縮率 | 搬送時間込みで許容範囲内か |
| PoC2 | UNDO保持（長時間Export耐性） | ORA-01555が発生しないか |
| PoC3 | Archived Redo Log 生成量測定 | 1日・1週間・1か月の生成量 |
| PoC4 | 差分抽出検証 | INSERT/UPDATE/DELETE が正確に取得できるか |
| PoC5 | PL/SQL変換精度・速度 | 500テーブルの変換が許容時間内に完了するか |

---

## 9. 本検証環境（ローカルDocker）との対応

本番では DBリンク不使用・DataPump搬送であるが、
ローカル検証環境では以下の読み替えで等価な検証が可能。

| 本番 | 検証環境（Docker） | 検証目的 |
|------|------------------|---------|
| DataPump Export/Import | `PKG_CDC_SNAPSHOT.take_snapshot` (AS OF SCN) | 同一断面取得の検証 |
| オフライン搬送 | DBリンク（直結） | 搬送後のデータ整合性確認（搬送手段は問わない） |
| Archived Redo + LogMiner | `SYS.cdc_process_batch`（LogMiner） | 差分抽出・適用ロジックの検証 |
| data-generator | data-generator（Pythonコンテナ） | 稼働中DB環境の模擬 |

> **ローカル環境の主な検証目的**：差分適用ロジック（LogMiner解析・FK依存順適用・LOB処理）の動作確認。搬送手段（DBリンク vs DataPump）は検証スコープ外。

---

## 10. 残リスクと対策

| リスク | 影響 | 対策 |
|--------|------|------|
| Archive Log が消滅（保持期間切れ） | 差分が欠落→再スナップショット必要 | Log保持ポリシー設定・定期確認 |
| PL/SQL変換の処理時間超過 | カットオーバー延長 | PoC5で事前計測・バッチ分割設計 |
| ORA-01555（UNDO不足） | Export失敗 | UNDO_RETENTION延長・夜間実施 |
| 移行期間中のDDL変更 | 差分適用失敗 | 変更凍結の合意を取り付ける |
| LOBデータの差分欠落 | データ不整合 | FLASHBACK QUERYフォールバック実装（検証中） |
