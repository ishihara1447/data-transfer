# 差分方式 正確性・性能PoC計画

作成日: 2026-07-28
状態: 計画確定、実施未完了

## 1. 目的

更新日時差分、固定差分表、LogMiner変更キー + SCN固定スナップショット、現行LogMiner方式を同じ条件で比較し、テーブル群ごとの採用方式と切替条件を決める。

21c XEでは成立性と相対傾向を確認し、絶対性能、追付き性能、ソース業務影響はOracle 12c本番相当環境で確定する。

## 2. 比較方式

| ID | 方式 |
|---|---|
| A | 更新日時条件の直接 `expdp QUERY` |
| B | 更新日時条件で固定差分表を作成してExport |
| C1 | 移行先LogMiner変更キー + 逆方向キー要求 + 移行元SCN固定 |
| C2 | 移行元LogMiner変更キー + 移行元SCN固定 |
| D | 既存パーティション単位Export |
| E | 現行LogMiner SQL_REDO方式 |
| F | 更新日時方式 + LogMiner DELETE/変更キー照合 |

## 3. 実施順

### P0: テーブル棚卸し

約500表について次を収集する様式とSQLを作り、本番情報で埋める。

- 表サイズ、行数、平均行長、LOB容量
- 主キー列順、型、複合主キー、主キー更新有無
- 更新日時列、設定ロジック、精度、TZ、索引
- パーティション
- INSERT / UPDATE / DELETE 件数
- ユニーク変更キー数、同一キー反復更新回数
- 最大トランザクション時間
- FK依存、変換方式、特殊型

### P1: 正確性PoC

性能比較より先に、全方式で欠落と再実行性を確認する。

### P2: 代表3表の相対性能比較

1. 更新日時索引を持つ通常表
2. 更新頻度の高い大規模相当表
3. LOB表

### P3: C1 / C2構成比較

移行先LogMinerの逆方向搬送時間とUNDO保持時間を測り、移行元LogMinerとの損益を比較する。

### P4: 本番相当試験

Oracle 12c、同等エディション、RAC、ストレージ、UNDO、ファイルサーバ、業務負荷で最終判断する。

## 4. データ条件

以下は試験点であり、採用しきい値ではない。

| 軸 | 試験点 |
|---|---|
| 差分率 | 0.1%、1%、5%、20%、50% |
| 同一キー更新回数 | 1、5、20 |
| 行幅 | 小、中、大 |
| LOB | なし、小、大 |
| 主キー | 単一数値、単一文字列、複合 |
| トランザクション | 短時間、境界跨ぎ、長時間 |

## 5. 正確性ケース

- 長時間トランザクションが更新日時・SCN境界を跨ぐ
- 抽出時点に未コミット行がある
- ロールバック
- 物理DELETE
- INSERT後DELETE
- DELETE後再INSERT
- 同一主キーの複数回UPDATE
- 主キー更新
- 複合主キー、文字列主キー
- 同一トランザクションで複数表を更新
- FK親子同時更新
- LOB更新、非LOB列だけの更新
- DDL発生、CSF分割、Archived Redo跨ぎ
- 抽出、固定表作成、Export、搬送、Import、適用、変換の各工程停止
- 要求ファイル・応答ファイルの重複受領
- ORA-01555
- 同一バッチ再実行

合格条件:

- 欠落0
- 最終重複0
- `S_upper`断面と一致
- DELETE結果一致
- 再実行後に同一結果
- 未完了工程を越えてチェックポイントが進まない

## 6. 性能計測

### 移行元

- 経過時間、DB CPU、Logical/Physical Reads、I/O待機
- TEMP、UNDO、REDO、Archive Log生成量
- `V$UNDOSTAT.TUNED_UNDORETENTION`
- 業務SQLのP50/P95/P99、ロック・競合

### Data Pump・ファイル

- Access Method、Export/Import時間、ダンプ容量
- ファイル書込み・搬送MB/s、ファイル数、チェックサム時間
- 並列度、圧縮、ジョブ分割ごとの比較

### LogMiner・適用

- Redo解析MB/s、変更イベント件数/秒、ユニークキー圧縮率
- キー要求往復時間、スナップショット固定時間
- UPSERT/DELETE件数/秒、変換・検証時間
- 工程ごとのエラー・再実行時間

重要指標:

```text
追従余力 = 差分処理可能量 / 変更発生量

最終停止時間 =
  最終停止時の未処理差分 / 実効適用速度
  + 最終検証時間
```

## 7. 実装予定成果物

既存の `scripts/72_test_phase4_tables_e2e.sh` と `scripts/74_benchmark_datapump.sh` は変更せず、未使用番号で追加する。

| 成果物 | 目的 |
|---|---|
| `scripts/73_inventory_delta_candidates.sh` | テーブル分類情報の収集 |
| `scripts/75_test_timestamp_query_export.sh` | 直接QUERY方式 |
| `scripts/76_test_timestamp_stage_export.sh` | 固定差分表方式 |
| `scripts/77_test_dirty_key_snapshot.sh` | C1/C2変更キー方式 |
| `scripts/78_compare_delta_methods.sh` | 共通条件の性能比較 |
| `scripts/79_validate_delta_correctness.sh` | 正確性・障害再実行試験 |
| `sql/cdc/50_table_sync_method.sql` | テーブル別方式カタログ候補 |
| `sql/cdc/51_dirty_key.sql` | 複合主キー対応の変更キー候補 |
| `reports/delta-method-poc/` | ログ、計測CSV、実行計画、判断記録 |

DDL・スクリプト名は実装開始時に既存番号との衝突を再確認する。

## 8. 進捗項目との対応

| 進捗ID | 本計画で扱う内容 |
|---|---|
| P1-02 / P1-03 | 対象表、主キー、特殊型、LOB、更新日時の棚卸し |
| P1-07 | UNDOとORA-01555 |
| P1-11 / P1-16 | Data Pump業務影響とLOB Export |
| P4-04 | SCN範囲とLogMinerバッチ |
| P4-10 | 主キー抽出 |
| P4-14 | MERGE・直接DML・最終状態UPSERT比較 |
| P4-17 / P4-18 | LOB差分 |
| P4-23 | 追付き性能 |
| P4-26 | Phase4合格基準 |

## 9. 完了条件

- 全対象表を方式クラスへ仮分類できる
- 各クラスの代表表で正確性試験が合格する
- C1/C2の採否とUNDO要件が決まる
- 方式別のソース影響とE2E所要時間を比較できる
- 本番相当環境で再計測すべき項目と担当・期限が決まる
- テーブル別の採用理由と承認記録を残せる
