# LogMiner変更キー + SCN固定スナップショット設計

作成日: 2026-07-28
状態: 設計候補、PoC必須

## 1. 目的

LogMinerをSQL再実行器ではなく、コミット済み変更の主キーとDELETEを検出する仕組みとして使う。同一主キーの複数変更を圧縮し、共通の上限SCNにおける最終行状態を移行元から取得してSTAGINGへ冪等適用する。

この方式は大規模、高更新頻度、反復更新、物理DELETE、更新日時が信頼できない表の候補である。現時点で本番採用は確定しない。

## 2. 重要な構成上の制約

現行の新設計は、Archived Redoを移行先へ搬送し、移行先DBでLogMinerを実行する。一方、`SRC_SCHEMA.<table> AS OF SCN S_upper` は移行元DBでしか実行できない。

したがって移行先LogMiner方式では次の往復が必要になる。

```text
移行元 -> Archived Redo -> 移行先
移行先 -> 変更キー要求ファイル -> 移行元
移行元 -> SCN固定差分ファイル -> 移行先
```

必要なUNDO保持時間は少なくとも次を上回らなければならない。

```text
Archive確定待ち
+ Redo搬送
+ 移行先LogMiner解析
+ 変更キー要求の逆送
+ 移行元でのスナップショット固定完了
+ 障害・再送余裕
```

物理搬送が長時間または日単位になる場合、この方式は現実的でない可能性が高い。その場合は、移行元で変更キー抽出とスナップショット固定を連続実行する構成、または現行LogMiner適用を選ぶ。

## 3. 構成候補

| 方式 | LogMiner | 行取得 | 長所 | 主なリスク |
|---|---|---|---|---|
| C1 | 移行先 | 移行元へキー要求を逆送し `AS OF SCN` | 移行元のRedo解析負荷を抑える | 双方向搬送、長いUNDO保持、運用複雑化 |
| C2 | 移行元 | 同じ移行元で直ちに `AS OF SCN` | UNDO待ち時間と搬送回数を減らす | 移行元CPU/PGA/I/O負荷 |
| C3 | 移行先 | SQL_REDOを安全分類して適用 | 逆方向搬送不要 | SQL再実行、CSF、LOB、特殊型 |

PoCではC1とC2を必ず比較する。新設計が移行先LogMinerであることだけを理由にC1を自動採用しない。

## 4. SCN境界と処理

前回適用済み上限を `S_prev`、今回の共通上限を `S_upper` とする。

```text
対象コミット: (S_prev, S_upper]
```

1. `COMMITTED_DATA_ONLY` でコミット済みトランザクションを抽出する。
2. `COMMIT_SCN` が範囲内のINSERT/UPDATE/DELETEから旧・新主キーを取得する。
3. 同一テーブル・同一主キーをバッチ内で一意化する。
4. 移行元の対象表を `AS OF SCN S_upper` でキー集合と結合する。
5. 行があればUPSERT、なければDELETEとして固定差分を作る。
6. 固定差分をExport、搬送、Importし、STAGINGへ冪等適用する。
7. STAGING適用後に1.0から2.0への変換と検証を行う。

## 5. 主キー抽出

SQL_REDO文字列の正規表現を主方式にしない。`V$LOGMNR_CONTENTS.REDO_VALUE` / `UNDO_VALUE` と `DBMS_LOGMNR.MINE_VALUE` / `COLUMN_PRESENT` を同じLogMinerセッション内で使用する。

| 操作 | 取得値 |
|---|---|
| INSERT | REDO_VALUEの新キー |
| UPDATE、キー不変 | REDO_VALUEまたはUNDO_VALUE |
| UPDATE、キー変更 | UNDO_VALUEの旧キーとREDO_VALUEの新キー |
| DELETE | UNDO_VALUEの旧キー |

`MINE_VALUE` と `COLUMN_PRESENT` は LONG、LOB、ADT、COLLECTIONをサポートしない。全主キー型を棚卸しし、非対応型はフォールバックへ送る。

複合主キーは連結文字列だけで保持しない。列順、列名、Oracle型、NULL有無、正規化値を列単位で保持し、実際のJOINは元の主キー列で行う。

## 6. 既存管理資産との統合

新しい管理表を重複作成せず、まず既存資産を再利用する。

| 必要な役割 | 既存資産 | 方針 |
|---|---|---|
| LogMinerバッチ | `LOGMINER_BATCH` / `LOGMINER_BATCH_LOG` | 再利用 |
| トランザクション・変更明細 | `MINED_TRANSACTION` / `MINED_CHANGE` | 再利用。キー抽出結果との関連を追加 |
| 適用バッチ | `APPLY_BATCH` | SCN範囲管理を再利用 |
| 適用タスク | `APPLY_TASK` | SQL再実行方式とスナップショット方式を区別する列が必要 |
| チェックポイント | `MIG_CHECKPOINT` | 工程別に分離して再利用 |
| Data Pumpジョブ・ファイル | `DATAPUMP_JOB` / `DATAPUMP_FILE` | 要求・応答ファイルも追跡 |

追加候補は次に限定する。

- `TABLE_SYNC_METHOD`: テーブル別方式、PK、更新日時、LOB、DELETE方式、適用順、PoC承認情報
- `DIRTY_KEY`: バッチ、表、キー識別ハッシュ、候補操作、処理状態
- `DIRTY_KEY_COLUMN`: 主キー列順、列名、型、正規化値

DDLはPoCで必要列を確定してから作成する。`CDC_BATCH`等の既存表と役割が重なる表は新設しない。

## 7. チェックポイント

単一のHigh Water Markで全工程を表さない。

| コンポーネント | 進める条件 |
|---|---|
| `LOGMINER_READER` | 対象SCN範囲の解析結果が永続化済み |
| `SNAPSHOT_FIXER` | 全対象表の `AS OF SCN S_upper` 固定と件数記録が完了 |
| `TRANSFER_READER` | チェックサム確認済みファイルを受領 |
| `APPLY_WRITER` | STAGINGの差分DMLと同一トランザクションで適用完了 |
| `TRANSFORM_WRITER` | バッチ全体の2.0変換完了 |
| `VALIDATOR` | バッチ検証の合格記録完了 |

後段が失敗しても前段の事実を失わない。再実行は未完了の最初の工程から開始する。

## 8. 正確性の不変条件

- すべての対象変更はコミットSCN範囲 `(S_prev, S_upper]` に属する
- 未コミット・ロールバック済み変更を含めない
- 全テーブルの行イメージは同じ `S_upper` を使う
- 主キー更新は旧キーDELETEと新キーUPSERTの両方を持つ
- 固定差分の件数、Export件数、Import件数、適用件数を追跡できる
- 未完了バッチを越えて `APPLY_WRITER` を進めない
- 同一バッチ再実行後の最終状態が同じになる
- 中間状態を利用者へ公開しない

## 9. Go / No-Go

次のどれかに該当する場合、C1方式は不採用とする。

- 必要UNDO保持時間が本番で保証できない
- 変更キー要求の逆方向搬送が運用・セキュリティ上許可されない
- 複合主キーまたは主キー型を安全に抽出できない
- 変更キーJOINが全表走査より高負荷になる
- LOB再取得量が許容値を超える
- 追従余力が1以下
- 障害時に同一SCN断面を再固定できない

## 10. PoC対象

詳細は `docs/delta-performance-poc-plan.md` に定義する。最低限、遅延コミット、DELETE、DELETE後INSERT、主キー更新、複合主キー、文字列主キー、LOB、長大トランザクション、ORA-01555、要求・応答ファイル再送、同一バッチ再実行を含める。
