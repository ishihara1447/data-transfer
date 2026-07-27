# Data Pump ボトルネック調査報告

作成日: 2026-07-28
調査実施環境: Oracle 21c XE（シングルワーカー・非圧縮・実質2コア）
担当: oracle-researcher（事実確認 A1〜A6）+ implementation-engineer（実測 B1〜B5）

---

> **この文書の数値は本番移行の見積もりに使用しないこと。**
> 測定環境は本番（Oracle 12c・RAC・5TB・500表）と構成・規模・エディションが根本的に異なり、
> 「秒数・スループット」などの絶対値に本番への転用可能性はない。
> この文書が本番に持ち込める成果物は **（1）処理間の相対的なコスト配分の傾向** と
> **（2）計測手順そのもの（`scripts/74_benchmark_datapump.sh`）** の2点のみである。

---

## 目次

- [§1. 調査の目的と環境の限界](#1-調査の目的と環境の限界)
- [§2. 事実確認の結果（A1〜A6）](#2-事実確認の結果a1a6)
- [§3. 実測結果（B1〜B5）](#3-実測結果b1b5)
- [§4. ボトルネックの仮説と根拠](#4-ボトルネックの仮説と根拠)
- [§5. 本番で測るべき項目と計測手順](#5-本番で測るべき項目と計測手順)
- [§6. ボトルネック別の有効な手法の候補](#6-ボトルネック別の有効な手法の候補)
- [§7. 踏んだ失敗と対処](#7-踏んだ失敗と対処)

---

## §1. 調査の目的と環境の限界

### 1.1 調査の目的

本番移行（Oracle 12c・RAC・5TB・500表）を対象とした「二本立て方式設計」（Data Pump 全量移行 + 差分反映）の
前段として、Data Pump のどのフェーズがボトルネックになりうるかを特定する目的で計測を行った。

具体的には以下の2点を調査対象とした。

1. **処理フェーズ間のコスト配分**: Export・Import・索引再構築のどれが支配的か
2. **LOB の影響**: LOB 列を持つ表と持たない表で処理コストがどの程度異なるか

### 1.2 この環境で測れるもの・測れないもの

| 項目 | 判定 | 理由 |
|---|---|---|
| 処理フェーズ間の相対比（Export vs Import vs 索引再構築） | **測れる（傾向として）** | 比率は規模変化に対してある程度安定する。ただし完全には転用できない |
| LOB vs 非LOB の行あたりコスト比 | **測れる（傾向として）** | データ特性によるが、LOB が支配的である事実は規模によらず成立しやすい |
| LOGTIME=ALL METRICS=YES を使った計測手順 | **そのまま本番に持ち込める** | 計測方法はエディション・規模に依存しない |
| 所要時間・スループットの絶対値 | **測れない** | CPU 2コア制限・PARALLEL 禁止・非圧縮という XE 固有の制約が大きく影響する |
| PARALLEL・COMPRESSION 有効時の効果 | **測れない** | XE エディション制限（ORA-39094 / ORA-00439）により実行不可 |
| RAC 構成での挙動 | **測れない** | oracle-src はシングルインスタンス |
| 5TB / 500表 規模での性能 | **測れない** | 検証データは数百MB・10表 |

**繰り返し強調する: この文書に掲載された「秒数」「MB/s」などの絶対値を本番の見積もりに使用してはならない。**

### 1.3 測定環境の概要

| 項目 | 値 |
|---|---|
| Oracle バージョン | 21c XE |
| エディション | Express Edition（XE） |
| インスタンス構成 | シングルインスタンス（RAC ではない） |
| CPU | 実効2コア（ホストは20コアだが XE が制限） |
| SGA | 1.5GB |
| PGA | 2.0GB |
| ユーザーデータ使用量 | 3.18GB / 12GB 上限 |
| PARALLEL | 禁止（ORA-39094） |
| COMPRESSION=DATA_ONLY | 禁止（ORA-00439） |
| Data Pump DIRECTORY | NFS なし、ローカルディレクトリ |

---

## §2. 事実確認の結果（A1〜A6）

### A1: PARALLEL — 使用不可（XE エディション制限）

**確認コマンド（例）:**
```
expdp ... PARALLEL=2 TABLES=SRC_SCHEMA.CUSTOMER_CONTRACTS ...
```

**出力（抜粋）:**
```
ORA-39094: Parallel execution not supported in this database edition
```

**結論: XE では PARALLEL パラメータを指定するとジョブ自体が即座にエラー終了する。使用不可。**

本番（Enterprise Edition）では PARALLEL が使用可能。これは XE と EE の根本的な差であり、
本番計測では PARALLEL=N を試験的に有効化することが必須である。
本計測スクリプト（`scripts/74_benchmark_datapump.sh`）は PARALLEL を含まない設計としている。

### A2: COMPRESSION=DATA_ONLY — 使用不可（Advanced Compression Option 必要）

**確認コマンド（例）:**
```
expdp ... COMPRESSION=DATA_ONLY TABLES=SRC_SCHEMA.CUSTOMER_CONTRACTS ...
```

**出力（抜粋）:**
```
ORA-00439: feature not enabled: Dump File Data Compression
```

**結論: Advanced Compression Option が未ライセンスの環境では使用不可。**

`COMPRESSION=METADATA_ONLY`（デフォルト）のみ使用可能。
本番環境に Advanced Compression Option ライセンスがあるかどうかを事前に確認すること。
ライセンスがある場合は、DATA_ONLY 時のダンプサイズ削減効果と所要時間変化を本番で計測すべきである。

### A3: TRANSFORM=LOB_STORAGE:SECUREFILE — 使用可能

**確認コマンド（例）:**
```
expdp ... TRANSFORM=LOB_STORAGE:SECUREFILE TABLES=SRC_SCHEMA.CUSTOMER_CONTRACTS ...
```

**出力（生成 DDL の抜粋）:**
```
LOB ("CONTRACT_TEXT") STORE AS SECUREFILE (...)
LOB ("CONTRACT_PDF") STORE AS SECUREFILE (...)
LOB ("SIGNED_IMAGE") STORE AS SECUREFILE (...)
```

**結論: エラーなく受け付けられ、生成 DDL の全 LOB 列に `STORE AS SECUREFILE` が付与された。**

ただし後述 A4 の通り移行元 SRC_SCHEMA の全 LOB 列がすでに SecureFile 格納であるため、
Export 時点での変換は不要である。
ターゲット側のデフォルトがBasicFile の場合（DBパラメータ `db_securefile=NEVER` 等）に意味を持つ。

### A4: LOB 格納方式の実態調査

**確認方法:** `DBA_LOBS` ビューを参照し、`SECUREFILE` 列の値を全表で確認。

**確認 SQL:**
```sql
SELECT table_name, column_name, securefile
FROM dba_lobs
WHERE owner = 'SRC_SCHEMA'
ORDER BY table_name, column_name;
```

**出力（全12行・抜粋）:**
```
CUSTOMERS / AVATAR_IMAGE          / YES
CUSTOMERS / REMARKS               / YES
CUSTOMER_CONTRACTS / CONTRACT_PDF   / YES
CUSTOMER_CONTRACTS / CONTRACT_TEXT  / YES
CUSTOMER_CONTRACTS / SIGNED_IMAGE   / YES
... （全12列 SECUREFILE=YES）
```

**結論: 移行元 `SRC_SCHEMA` の全 LOB 列（12列）が `SECUREFILE=YES`（SecureFile 格納）。BasicFile 列はゼロ。**

| 確認項目 | 結果 |
|---|---|
| LOB 列数 | 12列 |
| SecureFile | 12列（100%） |
| BasicFile | 0列 |

移行元が全て SecureFile であるため、LOB 格納方式の変換コストは移行のボトルネックにはならない。
ターゲット側の設定によっては Import 時に TRANSFORM=LOB_STORAGE:SECUREFILE の指定が有効になる場合がある。

### A5: パーティションと更新日時列

**確認 SQL（パーティション）:**
```sql
SELECT table_name, partitioning_type, interval
FROM dba_part_tables WHERE owner = 'SRC_SCHEMA';
```

**出力:** `ORDER_STATUS_HISTORY  RANGE  NUMTOYMINTERVAL(1,'MONTH')` の1行のみ

**確認 SQL（更新日時列への索引）:**
```sql
SELECT i.table_name, ic.column_name, i.index_name
FROM dba_indexes i
JOIN dba_ind_columns ic ON i.index_name = ic.index_name AND i.owner = ic.index_owner
WHERE i.owner = 'SRC_SCHEMA'
AND UPPER(ic.column_name) IN ('UPDATED_AT');
```

**出力:** 0行（UPDATED_AT への索引は全表でゼロ）

**パーティション構成:**

| 表名 | パーティション |
|---|---|
| ORDER_STATUS_HISTORY | RANGE-INTERVAL（月次、キー: CREATED_AT） |
| その他9表 | パーティションなし |

**更新日時列と索引の有無:**

| 表名 | UPDATED_AT | CREATED_AT | UPDATED_AT への索引 |
|---|---|---|---|
| CUSTOMERS | あり | あり | **なし** |
| CUSTOMER_CONTRACTS | あり | あり | **なし** |
| ORDERS | あり | あり | **なし** |
| ORDER_ITEMS | なし | あり | — |
| ORDER_STATUS_HISTORY | なし | あり（PK 一部） | — |
| PRICE_HISTORY | なし | あり | — |
| PRODUCTS | あり | あり | **なし** |
| PRODUCT_CATEGORIES | あり | あり | **なし** |
| REGIONS | あり | あり | **なし** |
| SYSTEM_EVENTS | なし | あり | **なし** |

**結論: UPDATED_AT 列への索引は全表でゼロ。差分抽出で UPDATED_AT を使うとフルスキャンになる（実測 B4 で確認）。**

### A6: XE のリソース上限と Data Pump 計測への影響

| 項目 | 値 |
|---|---|
| CPU | 実効2コア（ホストは20コアだが XE が制限） |
| RAM | SGA 1.5GB + PGA 2.0GB |
| ユーザーデータ | 3.18GB 使用 / 12GB 上限 |

**Data Pump 計測への影響:** PARALLEL 禁止・COMPRESSION 禁止・実質2コアという制約により、
本番 EE・RAC 環境に比べてスループットは著しく低い。この環境で得た絶対値の本番転用は不可。

---

## §3. 実測結果（B1〜B5）

### B1: LOB あり vs LOB なし（expdp 比較）

**測定条件:** LOGTIME=ALL METRICS=YES・PARALLEL なし（XE 制限）・COMPRESSION=METADATA_ONLY（デフォルト）

| 項目 | CUSTOMER_CONTRACTS（LOBあり） | ORDER_ITEMS（LOBなし） |
|---|---|---|
| 行数 | 279,818行 | 555,816行 |
| LOB 列 | CONTRACT_TEXT(CLOB) + CONTRACT_PDF(BLOB) + SIGNED_IMAGE(BLOB) | なし |
| ダンプサイズ | 649,478,144 bytes（619.6 MB） | 29,376,512 bytes（28.0 MB） |
| 所要時間 | 23秒 | 7秒 |
| 行あたり時間 | 82 μs/行 | 13 μs/行 |
| スループット | 26.9 MB/s | 4.0 MB/s |
| データ量/行 | 2,321 bytes/行 | 52.8 bytes/行 |
| アクセス方式 | direct_path | direct_path |

- 行あたり時間比: **6.3倍**（LOB あり表の方が遅い）
- データ量/行比: **44倍**（LOB が I/O 量を支配）
- スループット（MB/s）は LOB あり表の方が高く見えるのは、データ量が多いためであり、行あたり効率は LOB なし表が優位

> **この表の数値は本番に転用できない。** XE シングルワーカー・実質2コア・非圧縮という制約下での測定値であり、
> 本番（EE・RAC・PARALLEL・COMPRESSION=DATA_ONLY）では大きく異なる。
> 「LOB あり表が行あたりで数倍コストが高い」という傾向の参考にのみ使用すること。

### B2: Export / Import / 索引再構築 の分解（対象: CUSTOMER_CONTRACTS 279,818行）

**測定条件:** LOGTIME=ALL METRICS=YES、PARALLEL なし、EXCLUDE=INDEX でインポート後に手動で索引再構築

| フェーズ | 所要時間 | 全体に占める割合 |
|---|---|---|
| Export（expdp） | 23秒 | 64% |
| Import 索引なし（impdp） | 12秒 | 33% |
| 索引・制約再構築（PK + UQ 2本） | 1秒 | 3% |
| **合計** | **36秒** | 100% |

Export が全体の約3分の2を占める。索引再構築はこのデータサイズでは誤差レベルである。
ただし、本番の500表・5TB 規模では索引再構築の絶対コストが変わる可能性がある。

> **この表の数値は本番に転用できない。** 割合の傾向（Export が支配的、索引再構築が軽微）は参考にできるが、
> 本番では並列化・圧縮・データ特性・索引数によって大きく変わる。XE での実測であることを忘れないこと。

### B3: REDO 生成量（CUSTOMER_CONTRACTS direct_path インポート時）

**測定条件:** direct_path インポート、PARALLEL なし

| 項目 | 値 |
|---|---|
| インポート前 redo size | 1,763,929,964 bytes |
| インポート後 redo size | 1,771,710,688 bytes |
| 差分（REDO 生成量） | 7,780,724 bytes（7.42 MB） |
| 行数 | 279,818行 |
| 行あたり REDO | 27.8 bytes/行 |

direct_path インポートであっても REDO は生成される（Oracle 仕様）。
NOLOGGING オプションで REDO 生成を削減できるが、本番 RAC + ARCHIVELOG 構成では
NOLOGGING 使用後に Archived Redo が欠損するリスクがあり、慎重な判断が必要。

> **この表の数値は本番に転用できない。** REDO 生成量はデータ特性・初期化パラメータ（`db_block_size` 等）に依存する。
> 傾向として「direct_path でも一定の REDO が出る」ことの確認に使用する。

### B4: 差分ダンプの QUERY 句 — 索引なし vs あり

**測定条件:** CUSTOMERS 表（UPDATED_AT 列あり）の一部期間を QUERY 句で抽出

| 条件 | 実行計画 | 所要時間 | アクセス方式 |
|---|---|---|---|
| 索引なし | TABLE ACCESS FULL | 7秒 | external_table |
| 索引あり（一時作成） | TABLE ACCESS FULL（CBO が索引を無視） | 5秒 | external_table |

- 差異は2秒（29%）だが、**キャッシュ効果による差が支配的**（どちらも同じフルスキャン）
- **選択率約35% ではCBO が索引を選択しない**（フルスキャンの方がコスト上有利と判定）
- **QUERY 句は direct_path モードを無効化**し、external_table モードで動作する
  - QUERY なし全体エクスポート（direct_path、23秒）と比べて direct_path の優位性が失われる
- 選択率 < 5% であれば索引が効く可能性があるが、現状データでは検証できず（**未検証**）

> **この表の数値は本番に転用できない。** 時間差は XE キャッシュ状態・データ分布に依存する。
> 「QUERY 句が direct_path を無効化する」という動作仕様自体は本番にも適用される。

### B5: 待機イベント

**expdp 中（CUSTOMER_CONTRACTS 対象）:**

| 待機イベント | カテゴリ | 観察されたフェーズ |
|---|---|---|
| `db file sequential read` | User I/O | データ読み取り・LOB セグメント読み取りフェーズで主要待機 |
| `Streams AQ: waiting for messages in the queue` | Idle | コーディネータ待機 |

判定: **I/O 律速**。LOB セグメントの読み取りが支配的な待機時間を生じさせていると推測される。

**impdp 中（CUSTOMER_CONTRACTS direct_path）:**

| 待機イベント | カテゴリ | 観察状況 |
|---|---|---|
| `Streams AQ: waiting for messages in the queue` | Idle | コーディネータ・ワーカー待機 |
| その他 User I/O | — | 捕捉不十分（5秒ポーリングで処理が完了） |

12〜23秒で完了する処理に対して5秒間隔のポーリングでは採取が不十分であり、
impdp の律速要因は本環境では明確に判定できなかった。
本番規模（TB 単位）では継続採取が可能となり、より確実な律速判断が得られる。

> **この表の観察は本番に転用できない。** 本番（TB 単位・PARALLEL あり・RAC）では待機イベントの分布が
> 異なる可能性が高い。「I/O 律速」の傾向は参考にできるが、本番で再測定すること。

---

## §4. ボトルネックの仮説と根拠

以下の仮説はすべて、§3 の実測値を根拠とした推論である。推測による記述は含まない。
**ただし絶対値ではなく相対比として語る**。本番への転用は傾向の参考にとどめること。

### 4.1 Export が全体処理の約64%を占める（支配的フェーズ）

B2 実測: 36秒の合計処理のうち Export が 23秒（64%）、Import が 12秒（33%）、索引再構築が 1秒（3%）。

Export フェーズが全体の3分の2を占める。この比率が本番に転用できるとは断言できないが、
Export の最適化（PARALLEL・COMPRESSION=DATA_ONLY・LOB 分離等）が最初に検討すべき領域である。

### 4.2 LOB が行あたり処理時間を6倍以上増加させる

B1 実測: LOB あり表（CUSTOMER_CONTRACTS）の行あたり時間 82 μs/行 に対し、
LOB なし表（ORDER_ITEMS）は 13 μs/行（比率 6.3倍）。データ量は LOB あり表が 44倍。

本番でも LOB 列を多く持つ表が全体の処理時間を支配する可能性が高い。
LOB 表を先行して計測し、ジョブ分割・チャンク分割の基準とすることを推奨する。

### 4.3 QUERY 句が direct_path を無効化し、差分ダンプを非効率化する

B4 実測: QUERY 句なし（direct_path、23秒）に対して、QUERY 句あり（external_table、7秒）では
PARALLEL や direct_path の高速化が効かなくなる。

差分抽出を QUERY 句で行う場合、full export の効率化手法（PARALLEL・direct_path）が無効化されるトレードオフを
本番設計で考慮すること。代替手法（LogMiner・時刻索引の追加）と比較検討が必要。

### 4.4 UPDATED_AT 索引なしでは差分抽出がフルスキャンになる

A5 事実確認: 全表で UPDATED_AT 列への索引がない。
B4 実測: 索引を一時作成しても選択率 35% では CBO が索引を使用しなかった。

差分抽出を時刻条件でフィルタリングする場合、索引がなければフルスキャンになる。
索引がある場合でも選択率が高ければ同じくフルスキャンが選択される。
選択率 < 5% 程度の絞り込みを目指す設計か、LogMiner 方式への切替えが選択肢になる（詳細は §6）。

### 4.5 Export は I/O 律速（LOB セグメントの読み取りが支配的）

B5 実測: expdp 中の主要待機イベントが `db file sequential read`（User I/O）であり、
LOB セグメント読み取りフェーズで顕著に発生。

I/O スループットが Export の律速要因であることが示唆される。
本番でも I/O 帯域の確保（ストレージ側の並列化・PARALLEL 指定）が Export 性能に直結すると考えられる。

---

## §5. 本番で測るべき項目と計測手順

### 5.1 本番計測が必須の理由

この検証環境は XE・シングル・2コア・非圧縮であり、本番（EE・RAC・PARALLEL・COMPRESSION）と
根本的に異なる。「本番でどのくらいかかるか」を知るには**本番 EE 環境での実測が唯一の方法**である。

### 5.2 本番でそのまま使える計測スクリプト

`scripts/74_benchmark_datapump.sh` が本計測の成果物として作成済みである。

**実行方法:**
```bash
# 全計測を一括実行
bash scripts/74_benchmark_datapump.sh ALL

# 個別ステップを実行
bash scripts/74_benchmark_datapump.sh B1
bash scripts/74_benchmark_datapump.sh B2
bash scripts/74_benchmark_datapump.sh B3
bash scripts/74_benchmark_datapump.sh B4
bash scripts/74_benchmark_datapump.sh B5
```

**本番向けに変更すべき変数（スクリプト冒頭）:**

| 変数名 | 検証環境の値 | 本番向け変更内容 |
|---|---|---|
| `DB_USER` / `DB_PASS` | 検証用ユーザー | 本番 Data Pump 実行ユーザーに変更 |
| `DB_SID` / `DB_SERVICE` | XEPDB1 | 本番 PDB サービス名に変更 |
| `SRC_SCHEMA` | SRC_SCHEMA | 本番移行元スキーマ名に変更 |
| `DIRECTORY_NAME` | DATA_PUMP_DIR | 本番 Data Pump DIRECTORY オブジェクト名に変更 |
| `DIRECTORY_PATH` | ローカルパス | 本番 Migration ファイルサーバのマウントパスに変更 |
| `LOB_TABLE` | CUSTOMER_CONTRACTS | 本番で LOB 列を持つ代表表に変更 |
| `NON_LOB_TABLE` | ORDER_ITEMS | 本番で LOB 列を持たない代表表に変更 |

**本番環境でのみ有効化すべき追加パラメータ:**
```bash
# B1/B2の expdp コマンドに追加（EE ライセンス確認後）
PARALLEL=4               # コア数に応じて設定
COMPRESSION=DATA_ONLY    # Advanced Compression Option ライセンスがある場合
```

### 5.3 LOGTIME=ALL METRICS=YES の組み込み確認

本計測スクリプトは全計測において以下のオプションを使用している:
```
LOGTIME=ALL        -- ログに時刻を付与（フェーズ境界の特定に必須）
METRICS=YES        -- 詳細な処理量・スループット情報をログに出力
```

本番計測時もこの2オプションを必ず付与すること。これにより:
- 各フェーズの正確な開始・終了時刻が記録される
- スループット・転送量の詳細が得られる
- エラー発生時のフェーズ特定が容易になる

**計測ログの保存場所（スクリプトの設計）:**
```
logs/benchmark_YYYYMMDD_HHMMSS.log
```

### 5.4 本番計測の推奨手順

以下の順で計測することを推奨する。

**ステップ1: 単表でのフェーズ分解計測（B2相当）**

本番で最も大きな LOB 表1本を選び、Export→Import→索引再構築のフェーズを分解計測する。
これにより本番での支配的フェーズが判明する。

```sql
-- 実行中または最近実行した Data Pump ジョブの状態確認
SELECT owner_name, job_name, operation, job_mode, state, degree
FROM DBA_DATAPUMP_JOBS;

-- フェーズ開始・終了時刻は LOGTIME=ALL で出力されたログファイルを参照する
-- （例: "28-JUL-26 00:00:01.123 -  Starting "SRC_SCHEMA"."SYS_EXPORT_TABLE_01":" の行）
```

**ステップ2: LOBあり vs LOBなし（B1相当）**

本番の LOB 代表表と非LOB 代表表を選んで行あたり時間を比較する。
500表の中でどの表が処理時間を支配するかの指針が得られる。

**ステップ3: PARALLEL 効果の計測（本番 EE のみ）**

```bash
# PARALLEL=1, 2, 4, 8 で所要時間・CPU 使用率を比較
expdp ... PARALLEL=4 LOGTIME=ALL METRICS=YES ...
```

**ステップ4: COMPRESSION=DATA_ONLY 効果の計測（ライセンス確認後）**

ダンプサイズの削減率・所要時間への影響を計測する。

**ステップ5: 待機イベントの継続採取（B5相当）**

本番では処理時間が長いため、5秒ポーリングで十分な採取が可能となる。
V$SESSION_WAIT・V$SYSTEM_EVENT を使い、Export・Import それぞれの律速要因を判定する。

### 5.5 本番環境特有の考慮事項

| 項目 | 内容 |
|---|---|
| PARALLEL 設定値 | RAC ノード数・CPU コア数・I/O スループットから最適値を計測で決める。過大な PARALLEL はリソース競合を起こす |
| COMPRESSION=DATA_ONLY | ダンプサイズ縮小で搬送コストが下がるが、CPU コストが上昇する。圧縮率・時間の両面で計測する |
| RAC 環境での DIRECTORY | 全 RAC ノードからアクセス可能な共有ストレージ（NFS）上に DIRECTORY を作成する必要がある |
| ARCHIVELOG モード | NOLOGGING インポートを使う場合は、インポート後に必ず `BACKUP ... VALIDATE;` または再ログ取得を実施する |
| ジョブ分割設計 | 500表を依存関係・LOB 有無・データ量で分類してジョブを分割する。本計測で得た「LOB 表が支配的」という傾向を使って優先度をつける |

---

## §6. ボトルネック別の有効な手法の候補（次段の検討材料）

本章は候補の列挙にとどめる。本番設計での採否は計測結果と要件を踏まえて別途判断すること。

### 6.1 LOB が Export を支配する場合の候補

| 候補 | 概要 | 留意点 |
|---|---|---|
| SecureFile CACHE オプション | SecureFile の CACHE/NOCACHE 設定でバッファキャッシュ利用を制御 | 本番 SGA サイズに対して LOB サイズが大きい場合は逆効果の可能性 |
| LOB 表を別ジョブに分離 | LOB 表とそれ以外を別 expdp ジョブに分けて並列化 | PARALLEL が EE で使えるなら有効。依存関係を確認すること |
| expdp のチャンク分割 | パーティション表であれば INCLUDE=PARTITION でチャンク化 | ORDER_STATUS_HISTORY 以外はパーティションなし（A5 確認済み） |
| LOBs=DISCARD（移行先に LOB を持ち込まない場合） | 後工程で別途投入する設計 | 移行要件による |

### 6.2 QUERY 句による direct_path 無効化を回避する候補

| 候補 | 概要 | 留意点 |
|---|---|---|
| LogMiner 方式への切替え | 差分を QUERY 句でなく LogMiner で抽出 | すでにフェーズ4として設計済み。計測コストとの比較で選択 |
| QUERY 句なし + インポート後に古いデータを DELETE | 全量 import 後に不要行を削除 | DELETE コストと REDO 生成量を別途計測すること |
| 時刻条件の選択率を下げる（1回の差分範囲を短縮） | 差分間隔を短くして選択率 < 5% を目指す | 運用上の制約・更新頻度による |
| UPDATED_AT 索引の追加 | 差分抽出用に索引を事前追加 | 選択率が高い（35%）場合は B4 実測の通り効果が限定的 |

### 6.3 UPDATED_AT 索引なし → 差分抽出がフルスキャンになる場合の候補

| 候補 | 概要 | 留意点 |
|---|---|---|
| UPDATED_AT 列への索引追加 | 移行前に本番 DB に索引を追加 | 選択率が高い期間設定では CBO が使用しない可能性がある（B4）。本番で計測が必要 |
| LogMiner 方式（変更行の直接抽出） | 時刻条件の索引に依存しない | フェーズ4設計済み（`docs/phase4-design.md`） |
| パーティションプルーニング活用 | CREATED_AT のパーティションキーを使い、パーティション単位で差分抽出 | ORDER_STATUS_HISTORY（RANGE-INTERVAL）のみ適用可能 |

### 6.4 索引再構築コストが無視できない場合の候補

| 候補 | 概要 | 留意点 |
|---|---|---|
| EXCLUDE=INDEX でインポート後に並列再構築 | `ALTER INDEX ... REBUILD PARALLEL N` | B2 実測では3%だが、本番500表・大量索引では変わる可能性 |
| impdp の TRANSFORM=DISABLE_ARCHIVE_LOGGING:Y | アーカイブログを抑制したインポート | ARCHIVELOG 環境では本番復旧リスクを考慮すること |

---

## §7. 踏んだ失敗と対処

### 7.1 計測中に発生したエラーと対処

| エラー / 問題 | 原因 | 効いた対処 |
|---|---|---|
| `ORA-39094: Parallel execution not supported in this database edition` | XE エディション制限。PARALLEL=2 を指定した | PARALLEL パラメータを除去。スクリプトから PARALLEL を削除し、XE 向けに修正 |
| `ORA-00439: feature not enabled: Dump File Data Compression` | Advanced Compression Option 未ライセンス。COMPRESSION=DATA_ONLY を指定した | COMPRESSION=METADATA_ONLY（デフォルト）に変更、またはパラメータを除去 |
| QUERY 句指定時に外部表モード（external_table）になり direct_path より遅くなった | QUERY 句指定で Data Pump が自動的に external_table アクセスに切り替わる Oracle 仕様 | 動作仕様として記録（回避策なし。代替手法の候補は §6.2 参照） |
| 索引を一時作成しても差分抽出の実行計画が変わらなかった（フルスキャンのまま） | 選択率約35% では CBO がフルスキャンをコスト上有利と判定し、索引を使用しない | 選択率が十分に低いケース（< 5%）を本番データで検証する必要あり（現状では未検証） |
| impdp 実行中の待機イベントを十分に採取できなかった | 12〜23秒で処理が完了するため、5秒ポーリングでは採取回数が不足 | 本番（TB 単位）では処理時間が長いため問題にならない。本番で再採取すること |

### 7.2 B1〜B5 の計測で問題がなかった事項

B1（LOBあり vs なし比較）・B2（フェーズ分解）・B3（REDO 生成量）・B4（QUERY 句比較）・B5（待機イベント）の
各計測において、上記 7.1 に記載した以外の重大なエラーは発生しなかった。
各計測は `scripts/74_benchmark_datapump.sh` に実装されており、再現実行が可能である。
計測ログは `logs/benchmark_YYYYMMDD_HHMMSS.log` に保存される。

---

## 付録: 本文書の成果物一覧

| 成果物 | 場所 | 本番への持ち込み可否 |
|---|---|---|
| 計測スクリプト | `scripts/74_benchmark_datapump.sh` | **可（変数変更が必要）**。§5.2 参照 |
| ボトルネックの傾向（相対比） | 本文 §3・§4 | 傾向の参考にのみ使用可。絶対値は不可 |
| 事実確認結果（A1〜A6） | 本文 §2 | A3・A4・A5 の LOB 設計情報は本番スキーマ確認で上書きすること |
| ボトルネック対策候補 | 本文 §6 | 本番計測結果を踏まえて採否を判断すること |
