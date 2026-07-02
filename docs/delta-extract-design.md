# 差分抽出・適用方式 設計書（改訂版）

## 0. この設計書の位置づけ

`docs/migration-strategy.md`（全体方針）の Step 5〜6（差分収集・差分適用）の
**詳細実装設計**。当初は「移行先で LogMiner を動かす」想定だったが、
検証で判明した制約により方式を改訂する。

---

## 1. 検証で判明した制約（改訂の理由）

### 制約: flat-file 辞書が PDB スキーマを含まない

```
DBMS_LOGMNR_D.BUILD（flat-file 辞書生成）
  - CDB$ROOT から実行 → CDB$ROOT のオブジェクトのみ辞書化。PDB の SRC_SCHEMA は含まれない
  - XEPDB1 から実行 → ORA-65040 で失敗
結果: 移行先（oracle-tgt）に archive log を運んで LogMiner にかけても
      SRC_SCHEMA の変更は 0 件しか認識されない
```

### この制約が示す本質

LogMiner で redo を「人間が読める SQL」に翻訳するには、
**そのスキーマ定義を知っている DB 上で解析する必要がある**。
移行元のスキーマ定義は移行元 DB にしかないため、
**解析は移行元（oracle-src）で行うのが自然**。

---

## 2. 改訂後の方式：移行元で抽出、結果を搬送

```
┌─ oracle-src（移行元）────────────────────┐
│ 1. LogMiner（DICT_FROM_ONLINE_CATALOG）   │
│    → online catalog 辞書で redo を解析     │
│ 2. SRC_SCHEMA の INSERT/UPDATE/DELETE を   │
│    SQL_REDO として抽出                     │
│ 3. 抽出結果を「差分ファイル」に書き出す     │
│    （SCN, table, operation, sql_redo, pk） │
└────────────────┬───────────────────────┘
                 │ 差分ファイルをオフライン搬送
                 │ （本番=物理媒体 / 検証=docker cp）
                 ▼
┌─ oracle-tgt（移行先）────────────────────┐
│ 4. 差分ファイルを読み込み                  │
│ 5. SRC_SCHEMA → STAGING_SCHEMA に置換      │
│ 6. FK 依存順・SCN 順で STAGING に適用       │
│ 7. 適用済み SCN を記録（冪等性担保）        │
└────────────────────────────────────────┘
```

### 当初方式との比較

| 項目 | 当初（archive log 搬送） | 改訂（差分ファイル搬送） |
|------|------------------------|------------------------|
| LogMiner 実行場所 | 移行先 | **移行元** |
| 辞書 | flat-file（PDB非対応で破綻） | **online catalog（PDB対応）** |
| 搬送対象 | archive log（巨大・167MB/本） | **差分SQL（小・テキスト）** |
| 搬送量 | redo 全量 | **SRC_SCHEMA 変更分のみ** |
| 本番妥当性 | 低（辞書問題） | **高** |

> **補足**: 本番では archive log は移行元に残り、LogMiner は archive log も
> オンライン redo も読める。検証環境（XE）では online redo を中心に検証する。

---

## 3. 本番制約との整合性チェック

| 本番制約 | 改訂方式での対応 |
|---------|----------------|
| GoldenGate 不可 | LogMiner（Oracle標準）のみ使用 ✓ |
| AWS 不可 | ローカル完結 ✓ |
| オフライン環境 | 差分ファイルを物理搬送（ネットワーク不要）✓ |
| DBリンク困難 | DBリンク不使用（ファイル受け渡しのみ）✓ |
| 5TB / 約500テーブル | 差分のみ搬送するため搬送量が小さい ✓ |
| 構造変換あり | STAGING に同一構造で受けてから別途PL/SQL変換 ✓ |
| 移行元は半年稼働継続 | LogMiner は移行元に低負荷。継続抽出可能 ✓ |

---

## 4. 差分ファイル形式

検証環境では DB テーブルを「搬送用キュー」として使い、
ファイル搬送を docker cp で模擬する。本番では UTL_FILE か
外部表でファイル化する。

### 検証環境の実装：差分キューテーブル

```
oracle-src 側: cdc_schema.delta_queue（抽出結果を貯める）
  delta_id      NUMBER         連番
  scn           NUMBER         変更SCN
  table_name    VARCHAR2(100)  対象テーブル
  operation     VARCHAR2(20)   INSERT/UPDATE/DELETE
  sql_redo      VARCHAR2(4000) LogMinerが生成したSQL
  pk_value      VARCHAR2(100)  PK値（LOB再取得用）
  rs_id         VARCHAR2(32)   トランザクション内順序
  ssn           NUMBER         同上
  extracted_at  TIMESTAMP      抽出時刻

搬送: delta_queue を Data Pump or CSV で oracle-tgt にコピー
      （検証では oracle-tgt 側に同名テーブルを作り docker cp 相当でコピー）

oracle-tgt 側: staging_ctl.delta_queue（搬送されてきた差分）
  + applied_at TIMESTAMP（適用済みマーク。冪等性担保）
```

---

## 5. コンポーネント設計

### oracle-src 側

```
PKG_DELTA_EXTRACT（cdc_schema、CDB$ROOT 格納の SYS プロシージャ）
  extract_delta(p_run_name)
    1. last_extracted_scn を取得
    2. CDB$ROOT で LogMiner 起動（DICT_FROM_ONLINE_CATALOG）
    3. V$LOGMNR_CONTENTS から SRC_SCHEMA の変更を読む
    4. XEPDB1 の cdc_schema.delta_queue に INSERT
    5. last_extracted_scn を更新
```

> 既存の `17b_sys_cdc_runner.sql` のフェーズ1〜2（LogMiner収集部分）を
> ほぼ流用できる。違いは「DBリンクで適用」→「delta_queueに保存」。

### 搬送スクリプト（Data Pump ファイル搬送方式）

本番のオフライン制約を忠実に模擬するため、delta_queue を
**Data Pump でダンプファイル化し、そのファイルを物理搬送**する。
テーブル間の直接コピーは行わない（DBリンクなし制約の検証を兼ねる）。

```
06_export_delta.sh （oracle-src）
  expdp で cdc_schema.delta_queue をダンプファイル化
  （tables=cdc_schema.delta_queue, query で未搬送分のみ）
  → ダンプファイル src_delta_NN.dmp 生成

07_transfer_delta.sh （搬送模擬）
  docker cp で src_delta_NN.dmp を
  oracle-src → ホスト /tmp → oracle-tgt に搬送

08_import_delta.sh （oracle-tgt）
  impdp で staging_ctl.delta_queue にロード
  （remap_schema=CDC_SCHEMA:STAGING_CTL, table_exists_action=APPEND）
```

> **補足**: Data Pump は必ずダンプ「ファイル」を生成するため、
> その物理ファイルを搬送する流れがオフライン環境の実態に合致する。
> 差分は小さい（テキストSQL中心）ため初期同期のような巨大ダンプにはならない。

### oracle-tgt 側

```
PKG_DELTA_APPLY（staging_ctl、XEPDB1 ローカル）
  apply_delta
    1. delta_queue の未適用行を SCN・FK依存順で取得
    2. sql_redo の SRC_SCHEMA → STAGING_SCHEMA 置換
    3. EXECUTE IMMEDIATE で適用
    4. applied_at を更新（冪等性）
```

> DBリンク不要。LogMiner も不要（既に SQL 化済み）。
> 移行先では「翻訳済みSQLを順番に流すだけ」になり、辞書問題が発生しない。

---

## 6. 実装ステップ（最小構成で貫通 → 拡張）

### フェーズ1: SYSTEM_EVENTS 1テーブルで貫通（まずこれ）

FK なし・LOBなし・INSERT中心の SYSTEM_EVENTS だけを対象に
src抽出 → Data Pump搬送 → tgt適用 のエンドツーエンドを通す。

| # | 内容 | 対象 |
|---|------|------|
| 1 | oracle-src に cdc_schema.delta_queue テーブル作成 | sql/cdc/30 |
| 2 | oracle-src に PKG_DELTA_EXTRACT 作成（17bベース、SYSTEM_EVENTS限定） | sql/cdc/31 |
| 3 | oracle-tgt に staging_ctl スキーマ + delta_queue + system_events 作成 | sql/cdc/32 |
| 4 | oracle-tgt に PKG_DELTA_APPLY 作成 | sql/cdc/33 |
| 5 | 搬送スクリプト 06/07/08（Data Pumpファイル搬送） | scripts/ |
| 6 | E2Eテスト: src に INSERT → 抽出 → 搬送 → tgt適用 → 件数一致確認 | — |

### フェーズ2: 全10テーブルへ拡張（貫通確認後）

- PKG_DELTA_EXTRACT のフィルタを全テーブルに拡張
- FK依存順適用・UPDATE/DELETE・LOBフォールバックを追加
- staging_schema に全10テーブルを作成（DataPump初期同期 or 手動DDL）

---

## 7. 検証観点

| 観点 | 確認内容 |
|------|---------|
| 抽出精度 | INSERT/UPDATE/DELETE が漏れなく delta_queue に入るか |
| 適用順序 | FK依存順・SCN順で適用され整合性が保たれるか |
| 冪等性 | 同じ差分を二度適用しても重複・エラーにならないか |
| LOB | out-of-line LOB が SQL_REDO に含まれない場合の扱い |
| ラグ | 抽出→搬送→適用の遅延 |

---

## 7.5 フェーズ1 検証結果（2026-06-06 実施）

SYSTEM_EVENTS 1テーブルでエンドツーエンド貫通を確認した。

```
oracle-src: INSERT (event_id 202402, 202403)
  → SYS.delta_extract: LogMiner抽出 → cdc_schema.delta_queue に4行
    （INSERT 2 + シーケンストリガ由来の UPDATE 2）
    → expdp でダンプファイル化 → docker cp 搬送
      → impdp で staging_ctl.delta_queue にロード
        → SYS.delta_apply: STAGING_SCHEMA.system_events に2行反映 ✓
```

### 検証で判明した実装上の要点（ハマりどころ）

| # | 問題 | 原因 | 対処 |
|---|------|------|------|
| 1 | LogMiner が変更を0件と報告 | DICT_FROM_ONLINE_CATALOG 使用時、PDBの変更は CON_ID=1(CDB$ROOT) として報告される | CON_IDフィルタを撤廃し SEG_OWNER のみで絞る |
| 2 | impdp が ORA-31640 でダンプを開けない | docker cp したファイルが UID1000 所有で oracle(54321) が読めない | ホスト側で chmod 644 してから配置 |
| 3 | PDBのDATA_PUMP_DIRにファイルが見つからない | PDBではGUIDサブディレクトリ配下に格納される | find で実パスを動的解決 |
| 4 | 適用時 ORA-00933 | LogMinerのSQL_REDOは末尾にセミコロンが付くが EXECUTE IMMEDIATE は不可 | 末尾セミコロンを除去 |
| 5 | expdp が ORA-01017 | SYSパスワードの特殊文字 + "as sysdba" のスペースで parfile 認証失敗 | 特殊文字なしの cdc_schema/staging_ctl ユーザーで接続（DATAPUMP権限付与） |

### 残課題（フェーズ2で対応）

- **LOB（EMPTY_CLOB/EMPTY_BLOB）**: redo にインライン化されないため、SQL_REDOには EMPTY_CLOB() が入る。FLASHBACK QUERY フォールバックが必要（既存 17_ の知見を流用）。今回は SYSTEM_EVENTS の payload が NULL のため顕在化せず。
- **INSERT文のPK抽出**: 正規表現が UPDATE形式 `"PK" = 値` 前提のため、INSERT の `VALUES` 形式ではPK値が取れない。LOBフォールバック実装時に要修正。

## 8. スコープ外（今回の検証で扱わないこと）

- DataPump による初期同期（別タスクで保留中）
- STAGING → TARGET の構造変換（タスク#5で別途）
- 5TB規模のスケール検証（XE では不可。設計上の考慮のみ）
- LOB フォールバックの完全実装（既存 17_ の知見を流用予定）

---

## 9. SQL_REDO 再生可能性の制約と安全な適用方式（Phase2 設計原則）

### 9.1 SQL_REDO は万能な差分 SQL ではない

`V$LOGMNR_CONTENTS.SQL_REDO` は LogMiner が Redo ログから再構成した SQL であり、
**`SQL*Plus` でそのまま安全に実行できる保証はない**。

特に以下の場合は直接実行が危険である。

| ケース | 問題点 |
|--------|--------|
| CSF=1 の行が存在 | SQL_REDO が次行に分割されており、連結しないと構文が壊れる |
| LOB型列を含むテーブル | LOB 本体は Redo とは別管理であり SQL_REDO で正確に再現できない |
| OPERATION_CODE 92/93/94 | LOB_WRITE/LOB_TRIM/LOB_ERASE は通常の DML とは異なる内部操作 |
| STATUS != 0 | LogMiner が解析できなかった不完全なレコード |
| 移行先テーブル構造が異なる | STAGING に存在しない列・型に対して SQL が失敗する |

> **設計原則**: SQL_REDO は「直接実行する SQL」ではなく「差分イベントの情報」として扱う。
> 直接適用（`EXECUTE IMMEDIATE`）は条件を満たした単純テーブルにのみ限定する。

---

### 9.2 テーブル分類（replay_category）

`cdc_schema.cdc_table_catalog` の `replay_category` 列で管理する。

| 分類 | 条件 | 差分適用方式 |
|------|------|--------------|
| **A** | LOBなし・STAGING同一構造・PK安定・ホワイトリスト登録済み | SQL_REDO 直接適用（`EXECUTE IMMEDIATE`） |
| **B** | 列追加・列削除・型変換など STAGING と SRC に差異あり | RAW/STG 変換後に MERGE（現行構成では非使用） |
| **C** | CLOB/BLOB/NCLOB/XMLType/LONG 等の LOB 列あり | SQL_REDO 直接適用禁止。PK再取得または最終再同期 |
| **D** | 移行期間中に DDL 変更の可能性あり | DDL 凍結または個別再設計 |
| **E** | STATUS 異常・UNSUPPORTED・MISSING_SCN 等 | 手動調査キューへ送る |

**本プロジェクトのテーブル分類結果（`sql/cdc/11_cdc_src_schema.sql` 参照）:**

| テーブル | LOB列 | replay_category | 差分適用方式 |
|---------|-------|----------------|--------------|
| REGIONS | なし | **A** | SQL_REDO 直接適用（ホワイトリスト登録済み） |
| CUSTOMERS | BLOB(avatar_image), CLOB(remarks) | **C** | SQL_REDO 直接適用禁止 → 手動調査キュー |
| ORDERS | CLOB(shipping_address) | **C** | SQL_REDO 直接適用禁止 → 手動調査キュー |
| SYSTEM_EVENTS | CLOB(event_payload) | **C** | SQL_REDO 直接適用禁止（is_active='N'） |

> **重要**: CUSTOMERS と ORDERS は LOB 列を持つため、`data-generator` が書き込んだ
> BLOB/CLOB 本体は SQL_REDO から正確に再現できない。STAGING への適用には LOB フォールバックが必要。

---

### 9.3 SQL_REDO 直接適用ホワイトリスト方式

直接適用を許可するテーブルは `cdc_schema.redo_replay_whitelist`（`36_*.sql`）で明示管理する。

**登録条件（すべて満たすこと）:**
- `cdc_table_catalog.lob_present = 'N'`（LOB列なし）
- `cdc_table_catalog.replay_category = 'A'`
- STAGING_SCHEMA と SRC_SCHEMA の構造が同一
- 主キーまたは一意キーで対象行を安定特定できる
- 検証環境で PoC 確認済み

```
現在のホワイトリスト: REGIONS のみ
CUSTOMERS / ORDERS は LOB あり → 登録禁止
```

---

### 9.4 CSF 連結処理

`CSF=1` の行は SQL_REDO が次行に続いていることを示す。
`SYS.delta_extract` は LogMiner 結果の収集ループ内で CSF 行を連結し、
`delta_queue.sql_redo_assembled`（CLOB）に完全な SQL を格納する。

```
LogMiner 出力（CSF=1 の場合）:
  行1: sql_redo = "INSERT INTO ... VALUES ('very long tex", CSF=1
  行2: sql_redo = "t value')",                             CSF=0

delta_queue に格納されるもの:
  sql_redo           = "INSERT INTO ... VALUES ('very long tex"  （先頭4000字）
  sql_redo_assembled = "INSERT INTO ... VALUES ('very long text value')"  （完全SQL）
```

`SYS.delta_apply` は `sql_redo_assembled` を優先し（NULL の場合は `sql_redo` にフォールバック）
`EXECUTE IMMEDIATE` に渡す。

---

### 9.5 差分適用判定ロジック（SYS.delta_apply）

```
FOR 各差分イベント:
  1. replay_allowed = 'Y' か？
     No → delta_manual_review_queue に記録 → CONTINUE（スキップ）
  2. sql_redo_assembled または sql_redo でスキーマ名を置換
  3. EXECUTE IMMEDIATE で STAGING_SCHEMA に適用
  4. 失敗 → ROLLBACK してこのTxを FAILED マーク

apply_ledger のTxステータス:
  APPLIED        : 全行が正常適用
  PARTIAL        : 一部適用 + 一部 MANUAL_REVIEW（混在Tx）
  MANUAL_REVIEW  : 全行が手動調査キューへ（LOBテーブルのTx等）
  FAILED         : SQL 実行エラー
```

---

### 9.6 LOBテーブルのフォールバック方式

CUSTOMERS / ORDERS の STAGING への差分反映は、**周期的ターゲット再同期方式**で実装する
（詳細設計は [11章](#11-lobテーブル差分反映方式詳細設計) を参照）。

---

## 10. 実装ファイル対応表（Phase2）

| ファイル | 内容 |
|---------|------|
| `sql/cdc/30_delta_queue_src.sql` | `operation_code/status_code/csf/rs_id/ssn/sql_redo_assembled/replay_*` 追加 |
| `sql/cdc/31_pkg_delta_extract_src.sql` | STATUS/CSF/OPERATION_CODE 収集・CSF連結・classify_event 分類 |
| `sql/cdc/32_delta_queue_tgt.sql` | src と同一スキーマ（Data Pump で自動対応） |
| `sql/cdc/33_pkg_delta_apply_tgt.sql` | replay_allowed チェック・MANUAL_REVIEW ルーティング |
| `sql/cdc/34_cdc_table_catalog.sql` | `lob_present/replay_category` 追加・LOB棚卸し結果を反映 |
| `sql/cdc/36_redo_replay_whitelist.sql` | 直接適用ホワイトリスト（REGIONS のみ登録） |
| `sql/cdc/37_delta_manual_review_queue.sql` | 手動調査キュー（oracle-tgt） |

---

## 11. LOBテーブル差分反映方式（詳細設計）

> **状態**: 設計完了・未実装（9.6 参照）。CUSTOMERS/ORDERS（`replay_category='C'`）の
> 差分が [9章](#9-sql_redo-再生可能性の制約と安全な適用方式phase2-設計原則) の安全設計により
> `delta_manual_review_queue` に退避されたまま STAGING_SCHEMA に反映されない問題を解消する。

### 11.1 方式の選定：A/Bを統合し「周期的ターゲット再同期」を基本方式とする

9.6（旧稿）では方式A（変更PK再取得・都度反映）と方式B（最終再同期・移行終了時に一括）を
選択肢として挙げ、「実装が単純」という理由でBを暫定候補としていた。
しかし改めて検討すると、Bを額面通り「移行完了までCUSTOMERS/ORDERSを一切更新しない」
方式にすると、**この2表は移行期間中（数日〜数週間）ずっと業務データが古いまま**になる。
CUSTOMERS/ORDERSは本プロジェクトの中核業務テーブルであり、これでは
「継続的にほぼリアルタイムで反映する」という本環境の価値提案（README 1〜4章）が
この2表に関しては実質的に成立しなくなる。

一方で方式Aを「変更1件ごとに移行元へ再取得を要求する」とすると、搬送のたびに
Data Pump のエクスポート/インポートを起動するオーバーヘッドが大きい。

そこで本設計では **AとBを統合**する。

> **基本方式**: 移行期間中は、変更のあった **PKだけ**を一定周期でまとめて移行元へ
> 再取得要求し、移行元から該当行（LOB本体を含む）を再取得して STAGING へ反映する
> （＝**バッチ化した方式A**）。
> **カットオーバー時**は、この周期処理を「保留ゼロになるまで」同期的に最後にもう一度
> 実行するだけでよい（＝方式Bは独立した仕組みではなく、この周期処理の**最後の1回**として吸収する）。

**なぜこの統合が成立するか**: 本番の制約は「オフライン」「DBリンク不可」であり、
「移行元→移行先」方向のファイル搬送しかできない、という制約ではない。
[2章](#2-改訂後の方式移行元で抽出結果を搬送)で確立した「Data Pump ダンプ＋物理搬送」の
仕組みは向きに依存しないため、**同じ仕組みを逆方向（移行先→移行元）にも使える**。
実際、検証環境では `scripts/06_transfer_delta_datapump.sh` の
`docker cp` ベースの搬送パターンを、方向を逆にしてそのまま流用できる
（本番では物理媒体を運ぶ回数が往復で倍になるだけで、実現可能性自体は変わらない）。

### 11.2 全体像（図解）

```
   [oracle-tgt]                                          [oracle-src]
                                                    
 delta_manual_review_queue          ①PKリスト搬送           SRC_SCHEMA
 (LOBイベントのPKが蓄積)         ─────(tgt→src)────▶      CUSTOMERS / ORDERS
        │                          (Data Pump/docker cp,          │
        │ 集約・重複排除              06と同じ搬送方式を逆向きに)     │ ②該当PKのみ
        ▼                                                          │  再SELECT
 lob_resync_target                                                 │ (LOB本体込み)
 (対象PK・最新操作を保持)                                            ▼
        │                                                  lob_resync_export
        │                                                  (再取得結果を一時格納)
        │                          ③再取得結果を搬送                │
        │                        ◀────(src→tgt)─────────────────┘
        ▼                          (既存06と同じ搬送方向)
 lob_resync_stage_*
 (取り込み用シャドウ表)
        │
        │ ④MERGE（PK一致でUPDATE/INSERT）
        ▼
 STAGING_SCHEMA.CUSTOMERS / ORDERS   ← ここでようやくLOB本体を含め最新化される
        │
        └─ delta_manual_review_queue を review_status='RESOLVED' に更新
```

- ①②③④は `scripts/43_lob_resync_cycle.sh`（新規）が一定周期で1サイクルとして実行する
  （[11.6](#116-実行周期とトリガ) 参照）。
- DELETEイベントだけは②〜④を経由せず、①より前に即時反映する（[11.5](#115-deleteの特別扱い即時反映)）。

### 11.3 データモデル追加

| 対象 | 追加内容 |
|------|----------|
| `staging_ctl.delta_manual_review_queue`（既存表・列追加） | `pk_value VARCHAR2(100)` を追加。`delta_queue.pk_value` は既に抽出済み（`sql/cdc/30_delta_queue_src.sql` コメント「PK値（LOB再取得用ベストエフォート抽出）」）だが、現行の `SYS.delta_apply` の `log_to_review_queue` がこの値を引き渡していない**（既存の伝播漏れ）**。本設計の前提として、この配線を先に直す必要がある |
| `staging_ctl.lob_resync_target`（新規・oracle-tgt） | 再同期対象PKの集約表。`table_name, pk_value, last_operation, requested_at, resync_status(PENDING/IN_TRANSIT/DONE), resolved_at` |
| `cdc_schema.lob_resync_request`（新規・oracle-src） | ①で搬送されてきたPKリストの受け皿。`table_name, pk_value, received_at` |
| `cdc_schema.lob_resync_export` / `staging_ctl.lob_resync_stage_customers` / `_orders`（新規） | ②で再取得した行を一時的に持つシャドウ表。列構成は `SRC_SCHEMA.CUSTOMERS` / `.ORDERS`（＝`STAGING_SCHEMA` と同一構造）に合わせる |

> 対象テーブルは `cdc_table_catalog.replay_category='C'` から動的に決定する
> （現状 CUSTOMERS/ORDERS。将来 LOB を持つ表が増えてもハードコード不要）。
> PK は既存の `cdc_table_catalog.pk_column` の「単一数値列」前提を踏襲する
> （複合キー対応は本設計のスコープ外＝既存の制約を引き継ぐのみで新規制約ではない）。

### 11.4 処理フロー（PL/SQL / シェルの役割分離）

本プロジェクトの実装方針（PL/SQLとPowerShell/シェルの役割分離）どおり、
**判定・集約・MERGE等のロジックはすべてPL/SQL**、
**シェルはコンテナ間の expdp/impdp 起動とファイル搬送のみ**を担う。

1. **tgt: `SYS.lob_resync_build_targets`**（新規PL/SQL、`delta_apply` と同じ命名系統）
   - `delta_manual_review_queue` の `fallback_reason='TABLE_HAS_LOB' AND review_status='PENDING'` を
     `commit_scn` 順に走査し、`(table_name, pk_value)` ごとに**最新の操作のみ**を採用（重複排除）
   - 最新操作が `DELETE` → 11.5 の即時反映へ回し、`lob_resync_target` には積まない
   - 最新操作が `INSERT`/`UPDATE` → `lob_resync_target` に `MERGE`（PENDING）
   - 処理した `delta_manual_review_queue` 行は `review_status='IN_REVIEW'` に更新（二重集約防止）
2. **`scripts/43_lob_resync_cycle.sh`（新規シェル）① tgt→src 搬送**
   - `lob_resync_target` の `PENDING` 行を `staging_ctl` から expdp
   - `docker cp` で oracle-src へ搬送（`scripts/06` の搬送手順を逆方向に踏襲）
   - src で impdp → `cdc_schema.lob_resync_request` にロード
   - 搬送済みの `lob_resync_target` 行を `IN_TRANSIT` に更新
3. **src: `SYS.lob_resync_export_rows`**（新規PL/SQL）
   - `lob_resync_request` を `table_name` ごとにグルーピングし、対象PKを収集
   - 各対象テーブルについて `expdp ... query="WHERE <pk_column> IN (SELECT pk_value FROM cdc_schema.lob_resync_request WHERE table_name='...')"`
     を**シェル側**が実行（PL/SQL側はPKリストの用意まで。expdp起動はシェルの責務）
4. **`scripts/43_lob_resync_cycle.sh` ③ src→tgt 搬送**
   - 上記ダンプを `docker cp` で oracle-tgt へ搬送（**既存 `scripts/06` と同一方向・同一パターン**）
   - `lob_resync_stage_customers` / `_orders` へ `impdp`（`table_exists_action=TRUNCATE` で毎回クリーンに取り込み）
5. **tgt: `SYS.lob_resync_merge`**（新規PL/SQL）
   - シャドウ表 → `STAGING_SCHEMA.CUSTOMERS`/`.ORDERS` へ `MERGE`
     （`WHEN MATCHED THEN UPDATE SET` 全列 / `WHEN NOT MATCHED THEN INSERT`）
   - 対応する `lob_resync_target` を `DONE` に、`delta_manual_review_queue` を `RESOLVED` に更新
   - シャドウ表を `TRUNCATE`（次サイクルに備える）

### 11.5 DELETEの特別扱い：即時反映

`DELETE` はLOB本体の再取得が不要（消すだけなので中身を読む必要がない）。
そのため `SYS.delta_apply` の段階で `replay_category='C'` かつ `operation='DELETE'` の行は、
`delta_manual_review_queue` に退避するのではなく、**PK指定の `DELETE`** を直接
`STAGING_SCHEMA` に対して実行してよい（LOB列があっても `DELETE FROM ... WHERE pk = :1` 自体は
LOB本体を参照しないため安全）。これにより：

- 「UPDATE後にDELETE」のような競合が起きても、`build_resync_targets` が
  `commit_scn` 順で「最新操作」を見るため、削除済みPKを誤って再同期対象にしない
- 再同期の対象範囲（PK件数）が実際に生き残っている行だけに絞られ、搬送量が減る

> 注意: 9.5 の判定ロジックに「`replay_category='C'` でも `operation='DELETE'` なら
> `replay_allowed='Y'` 相当として扱う」という**例外分岐の追加**が必要
> （`delta_extract` の `classify_event` 側での対応を想定）。

### 11.6 実行周期とトリガ

`sql/cdc/35_ops_config_src.sql` と同じ仕組みで、`ops_config` に以下を追加する。

| キー | 既定値 | 意味 |
|------|--------|------|
| `lob_resync_interval_cycles` | 6 | `scripts/40_cdc_cycle.sh` を何回まわすごとに `43_lob_resync_cycle.sh` を起動するか |
| `lob_resync_pending_threshold` | 500 | `lob_resync_target` の `PENDING` 件数がこれを超えたら周期を待たず即起動 |

`scripts/41_cdc_daemon.sh`（既存の継続CDCデーモン）がサイクルカウントと上記しきい値を見て
`43_lob_resync_cycle.sh` の起動要否を判定する（`40_cdc_cycle.sh` 自体は変更しない）。

### 11.7 冪等性・整合性の担保

- **上書きの一方向性**: STAGING の CUSTOMERS/ORDERS は「LogMinerのSQL_REDO直接適用」を
  一切受けない（9.2でC分類のため常に禁止）。この2表を更新する経路は
  `SYS.lob_resync_merge` と 11.5 の即時DELETEだけであり、複数経路が競合して
  適用順序が壊れる心配がない
- **再同期は「現在値の再取得」であって差分適用ではない**ため、同じPKが2回連続で
  再同期対象になっても（＝直前のサイクルの搬送漏れ等）、結果は同じ最新行になるだけで
  冪等。差分の順序保証（commit_scn/xid/seq_in_tx）はSQL_REDO直接適用（A分類）にのみ必要で、
  C分類の再同期には不要
- **競合ウィンドウ**: 「PKリスト生成」から「src側での再SELECT」までの間に、
  そのPKへさらに変更が入っても問題ない。再SELECTは**その時点の最新行**を取得するため、
  結果的に「より新しい状態」が反映されるだけで、古い状態で上書きされることはない
- **再取得時点で既にPKが削除されていた場合**: `expdp` のQUERYが0件ヒットになり
  シャドウ表に行が入らず `MERGE` は何もしない。ただしこのDELETE自体は
  11.5の即時反映で別途拾われるため、最終的にSTAGINGから消える（拾い漏れにならない）

### 11.8 カットオーバー時の最終処理

新しい「最終再同期」専用の仕組みは作らない。カットオーバー手順に以下を追加するだけでよい。

```
1. oracle-src への書き込みを止める（メンテナンスウィンドウ開始）
2. 最後の CDC サイクル（scripts/40）を1回実行し、直前までの差分を反映しきる
3. scripts/43_lob_resync_cycle.sh を「lob_resync_target の PENDING が
   0件になるまで」ループ実行する（通常は1〜2回で収束する規模）
4. delta_manual_review_queue に review_status='PENDING' が残っていないことを確認
5. ここまでで SRC=STAGING が完全一致 → カットオーバー続行（TARGET側の最終変換等）
```

### 11.9 可観測性（ダッシュボード拡張・任意）

`scripts/50_migration_dashboard.sh` の A区分（反映の遅れ・鮮度）付近に、
`lob_resync_target` の `PENDING`/`IN_TRANSIT` 件数と最終 `resolved_at` を追加表示する。
現状のダッシュボードはSTAGING⇔SRCの遅延をSCNベースで見ているが、
LOBフォールバックの遅延はここに含まれておらず、可視化の穴になっているため。

### 11.10 実装ファイル対応表（予定・未実装）

| ファイル | 内容 |
|---------|------|
| `sql/cdc/37_delta_manual_review_queue.sql`（既存・改修） | `pk_value` 列追加 |
| `sql/cdc/33_pkg_delta_apply_tgt.sql`（既存・改修） | `log_to_review_queue` に `pk_value` を伝播／DELETE即時反映の分岐追加 |
| `sql/cdc/31_pkg_delta_extract_src.sql`（既存・改修） | `classify_event` に「C分類でもDELETEはreplay_allowed='Y'」の例外追加 |
| `sql/cdc/38_lob_resync_tgt.sql`（新規） | `lob_resync_target` / シャドウ表 / `SYS.lob_resync_build_targets` / `SYS.lob_resync_merge` |
| `sql/cdc/39_lob_resync_src.sql`（新規） | `lob_resync_request` / `SYS.lob_resync_export_rows` |
| `sql/cdc/35_ops_config_src.sql`（既存・改修） | `lob_resync_interval_cycles` / `lob_resync_pending_threshold` 追加 |
| `scripts/43_lob_resync_cycle.sh`（新規） | ①③の搬送（`scripts/06` を土台に往復対応させる） |
| `scripts/41_cdc_daemon.sh`（既存・改修） | 周期・しきい値に応じた `43` の起動判定 |
| `scripts/50_migration_dashboard.sh`（既存・改修） | LOB再同期の遅延表示（任意） |

### 11.11 スコープ外（本設計で扱わないこと）

- 複合主キーを持つLOBテーブルへの対応（現状 `pk_column` は単一数値列前提のまま）
- `SRC_SCHEMA` と `TARGET_SCHEMA`（変換先）で列構成が異なるケースのMERGE（現状はSTAGING=SRC同一構造が前提）
- 再同期の粒度をさらに細かくする（例: LOB列だけ差分検知して再取得列を絞る）こと。
  今回は「対象行を丸ごと再取得」で十分とし、最適化は行わない
