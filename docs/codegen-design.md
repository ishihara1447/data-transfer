# 変換PL/SQL自動生成器 設計書（pkg_codegen）

## 0. この文書の位置づけ

`docs/phase2-transform-design.md`（STAGING→TARGET 変換層の設計）で定義した
`transform_catalog` / `pkg_transform_gen.transform_<tgt>` を、
**利用者が「対応関係」を入力するだけで決定論的に自動生成する仕組み**を設計する。

社内展開を想定し、生成側の実行環境には LLM（Claude Code）が無いことを前提とする。
利用者は DD（データディクショナリ）と「移行元↔移行先の対応関係（マッピング）」を
2つの設定表に入力するだけで、変換パッケージ一式（コンパイル可能な PL/SQL）を
得られることが本仕組みの価値である。

前提文書:

- `docs/phase2-transform-design.md` — transform_catalog / transform_class（PASS_THROUGH/LIGHT/HEAVY）/ pkg_transform の設計
- `docs/migration-design.md` — 旧スキーマ→新スキーマの基本方針

---

## 1. 目的と全体像

### 1.1 課題

`pkg_transform_gen.transform_<tgt>` の中身（INSERT...SELECT / MERGE、列ごとの変換式、
JOIN、差分窓条件）は、テーブルごとに定型ではあるが分量が多く、手書きは誤りやすく
拡張のたびに改修コストがかかる。これを「対応関係の入力」から機械的に導出したい。

### 1.2 全体像（3入力 → 生成 → デプロイ）

```
[入力1] 移行元DDL ─┐
                    ├─→ STAGING_SCHEMA / TARGET_SCHEMA に反映済み
[入力2] 移行先DDL ─┘     （pkg_codegen は dba_tab_columns を参照）
                                   │
[入力3] 対応関係 ─→ codegen_table_map / codegen_column_map に INSERT
                                   │
                                   ▼
                  log_schema.pkg_codegen.generate_all
                  （DD ＋ マッピングを読み、SQLテキストを DBMS_OUTPUT へ出力）
                                   │
                                   ▼
                  scripts/70_generate_transform.sh
                  （spool→ generated/pkg_transform_gen.sql → デプロイ）
                                   │
                                   ▼
        ┌──────────────────────────┴───────────────────────────┐
        ▼                                                       ▼
log_schema.pkg_transform_gen                      transform_catalog / transform_state
（per-table transform_<tgt> 実装）                （MERGE登録：唯一の真実源はマッピング表）
        │
        ▼
log_schema.pkg_transform.transform_all
（catalog の proc_name を動的呼び出し。PASS_THROUGH はコア側が汎用処理）
```

### 1.3 コア部と生成部の分離

| 区分 | モジュール | 役割 | 変更頻度 |
|------|-----------|------|---------|
| コア（固定） | `pkg_transform`（42） | 全体制御・ログ記録・PASS_THROUGH汎用処理・delete伝播・catalog動的呼び出し | 低い（テーブル追加で変わらない） |
| コア（固定） | `pkg_transform_util`（41） | 安全変換関数群（safe_to_number/safe_to_date/normalize_phone 等） | 低い |
| 生成部（自動） | `pkg_transform_gen`（71の出力） | per-table の `transform_<tgt>`（LIGHT/HEAVY の実体） | テーブル追加・マッピング変更のたびに再生成 |
| 設定（入力） | `codegen_table_map` / `codegen_column_map`（70） | 対応関係そのもの。マッピング変更の唯一の入力点 | 利用者が随時更新 |
| 生成器 | `pkg_codegen`（71） | DD＋マッピング→SQLテキスト生成。決定論的・LLM不要 | 低い（プリミティブ追加時のみ） |

`pkg_transform.transform_all` は `transform_catalog.proc_name` を完全修飾名で
動的呼び出しするため、生成された `pkg_transform_gen.transform_xxx` をそのまま
コアから呼び出せる。コア側のコードは生成のたびに変更する必要がない。

---

## 2. マッピング2表のスキーマと記入方法

定義場所: `sql/transform/70_codegen_mapping.sql`（所有: LOG_SCHEMA、SYS AS SYSDBA で実行、冪等）

### 2.1 codegen_table_map（1行 = 1移行先テーブルの変換定義）

| 列 | 意味 | 記入方法 |
|----|------|---------|
| `tgt_table` | 移行先テーブル名（PK） | TARGET_SCHEMA 上の表名（大文字） |
| `src_schema` | 移行元スキーマ | 既定 `STAGING_SCHEMA`。通常は変更不要 |
| `tgt_schema` | 移行先スキーマ | 既定 `TARGET_SCHEMA`。通常は変更不要 |
| `src_table` | 駆動元テーブル（生成SQLで別名 `s`） | STAGING 側の表名 |
| `pk_columns` | 移行先PK列（カンマ区切り、複合PK可） | MERGE の ON 句生成に使用 |
| `transform_class` | 変換分類 | `NULL`＝自動判定（推奨）。明示する場合は `PASS_THROUGH`/`LIGHT_TRANSFORM`/`HEAVY_TRANSFORM` |
| `join_clause` | HEAVY 用 LEFT JOIN 句 | 別名は `l_*` を使う規約（例 `l_cust`/`l_reg`）。PASS_THROUGH/LIGHT では NULL |
| `delete_src_table` | 削除伝播の検出元 STAGING 表 | NULL の場合 `src_table` と同名とみなす |
| `sort_order` | FK依存順（親を小さく） | transform_all の実行順・catalog 登録順を決める |
| `is_active` | 生成対象フラグ | `Y`/`N`。`N` は生成・登録対象外 |
| `remarks` | 備考 | 自由記述 |

### 2.2 codegen_column_map（1行 = 1移行先列の変換ルール）

| 列 | 意味 | 記入方法 |
|----|------|---------|
| `tgt_table` | 対象テーブル | `codegen_table_map.tgt_table` と一致させる |
| `tgt_column` | 移行先列名 | TARGET_SCHEMA 上の列名 |
| `col_order` | 生成時の列順 | INSERT/MERGE の列リスト・SELECT式の並び順を決める |
| `transform_type` | 固定プリミティブ種別 | `DIRECT`/`CONCAT`/`CODE_MAP`/`JSON_EXTRACT`/`EXPRESSION` のいずれか |
| `src_columns` | 入力列（カンマ区切り） | プリミティブにより意味が変わる（3章参照）。`EXPRESSION` では無視 |
| `arg_text` | 種別ごとの引数・式 | プリミティブにより意味が変わる（3章参照） |

PASS_THROUGH（後述の自動判定で該当）になるテーブルは `codegen_column_map` に
行を入れる必要がない（コア側の汎用 PASS_THROUGH 処理が全列コピーする）。

---

## 3. プリミティブ目録（transform_type）

`pkg_codegen.gen_expr` が各 `transform_type` を 1 列分の SELECT 式（SQLテキスト）に
変換する。生成式中の表別名は **主表 `s`**、HEAVY の JOIN 先は **`l_*`** で統一する。

### 3.1 DIRECT — 単純コピー／型変換

- `src_columns`: 1列
- `arg_text`（キャスト種別）:
  | 値 | 生成される式 |
  |----|-------------|
  | `NONE`（既定） | `s."列名"` （そのまま） |
  | `NUMBER` | `log_schema.pkg_transform_util.safe_to_number(s."列名")` |
  | `DATE` | `log_schema.pkg_transform_util.safe_to_date(s."列名")` |
  | `DATE_FROM_TS` | `CAST(s."列名" AS DATE)` （TIMESTAMP→DATE） |
- 例: `('CUSTOMERS','CREATED_DATE',11,'DIRECT','CREATED_AT','DATE_FROM_TS')`
  → `CAST(s."CREATED_AT" AS DATE)`

### 3.2 CONCAT — 複数列連結

- `src_columns`: 2列以上（カンマ区切り、順序通り連結）
- `arg_text`: 区切り文字リテラル（例 `' '`）
- 生成式: `s."列1" || '区切り' || s."列2" || '区切り' || ...`
- 例: `('CUSTOMERS','FULL_NAME',3,'CONCAT','LAST_NAME,FIRST_NAME',' ')`
  → `s."LAST_NAME" || ' ' || s."FIRST_NAME"`

### 3.3 CODE_MAP — コード値のデータ駆動マッピング

- `src_columns`: 1列（変換対象のコード値列）
- `arg_text`: `code_type`（`log_schema.code_mapping` の検索キー）
- 生成式（NVL でフォールバック。マッピング未登録時は元値を使用）:
  ```sql
  NVL((SELECT m.tgt_value FROM log_schema.code_mapping m
       WHERE m.code_type='<arg_text>' AND m.src_code=s."<列名>"), s."<列名>")
  ```
- 例: `('ORDER_ENRICHED','STATUS_LABEL',8,'CODE_MAP','STATUS','ORDER_STATUS')`

### 3.4 JSON_EXTRACT — JSON文字列からのキー抽出

- `src_columns`: 1列（JSON文字列を保持する CLOB 等）
- `arg_text`: 抽出する JSON キー名
- 12c互換のため Oracle の JSON 関数（JSON_VALUE 等）は使わず、
  `REGEXP_SUBSTR` ＋ `DBMS_LOB.SUBSTR` で文字列パターンマッチにより抽出する:
  ```sql
  REGEXP_SUBSTR(DBMS_LOB.SUBSTR(s."<列名>",2000,1),
    '"<キー>"[[:space:]]*:[[:space:]]*"([^"]*)"',1,1,NULL,1)
  ```
- 単純な `"key": "value"` 形式の文字列値抽出を想定（ネスト構造・配列は非対応）。
- 例: `('ORDER_ENRICHED','POSTAL_CODE',9,'JSON_EXTRACT','SHIPPING_ADDRESS','postal_code')`

### 3.5 EXPRESSION — 生SQL式の埋め込み

- `src_columns`: 無視（`NULL` でよい）
- `arg_text`: そのまま SELECT 式として埋め込まれる生SQL式。`s.列名` / `l_*.列名`
  / 関数呼び出し / CASE式 などを自由に書ける
- 生成式: `<arg_text の内容そのまま>`
- **以下は固定プリミティブを設けず、すべて EXPRESSION で表現する**:
  - `COALESCE`（複数候補からの NULL 合体）: 例
    `'COALESCE(s.company_name, s.last_name||'' ''||s.first_name)'`
  - `CONSTANT`（固定値の設定）: 例 `'''FIXED'''` のようにリテラルを式として書く
  - 単列ルックアップ（JOIN先テーブルの1列を取得するだけのケース）: 例
    `'l_reg.region_name'`
  - 派生計算式: 例 `'s.total_amount - s.tax_amount'`、
    `'CASE WHEN s.delivery_date IS NOT NULL THEN TRUNC(s.delivery_date)-TRUNC(s.order_date) END'`
  - util 関数呼び出し: 例 `'log_schema.pkg_transform_util.normalize_phone(s.phone)'`

EXPRESSION は生SQL式をそのまま埋め込むため、構文誤りは生成後の
コンパイルエラー（`SHOW ERRORS`）として顕在化する（8章参照）。

---

## 4. 生成→デプロイ手順（scripts/70）

### 4.1 前提（事前デプロイ済みであること）

1. `sql/transform/40_phase2_setup_tgt.sql` — STAGING/TARGET スキーマ、ログ表、
   `transform_catalog`/`transform_state`（空で作成）、`code_mapping`
2. `sql/transform/41_*`（pkg_transform_util）
3. `sql/transform/42_pkg_transform.sql`（コア: pkg_transform）
4. `sql/transform/70_codegen_mapping.sql`（マッピング2表の作成）
5. `sql/transform/71_pkg_codegen.sql`（生成器 pkg_codegen の作成）
6. マッピングデータの投入（`72_seed_mapping_example.sql` または利用者独自のINSERT）

### 4.2 実行

```bash
bash scripts/70_generate_transform.sh             # 生成 + デプロイ
bash scripts/70_generate_transform.sh --no-deploy # 生成のみ（中身を確認したい場合）
```

処理内容:

1. **生成**: `oracle-tgt` 上で `log_schema.pkg_codegen.generate_all` を実行し、
   `DBMS_OUTPUT`（`SET SERVEROUTPUT ON`）の出力を `generated/pkg_transform_gen.sql`
   としてホストに spool する。
   - 注意点: `SET SERVEROUTPUT ON` は `ALTER SESSION SET CONTAINER = XEPDB1` の
     **後**に実行する（コンテナ切替でサーバ出力バッファがリセットされるため）。
   - 生成物に `CREATE OR REPLACE PACKAGE BODY ... PKG_TRANSFORM_GEN` が
     含まれない場合はエラー終了する（生成失敗の早期検知）。
2. **デプロイ**: 生成ファイルを `oracle-tgt` にコピーし、`@pkg_transform_gen.sql`
   で実行（パッケージ仕様＋本体の `CREATE OR REPLACE` と `transform_catalog`/
   `transform_state` への `MERGE`）。`SHOW ERRORS PACKAGE BODY` でコンパイル
   結果を確認する。
3. **検証**: `pkg_transform_gen` の `dba_objects.status`、および
   `transform_catalog` の登録内容（`tgt_table_name` / `transform_class` /
   `proc_name`）を表示する。

### 4.3 生成されるSQLの構成（DBMS_OUTPUTの内容）

1. `CREATE OR REPLACE PACKAGE log_schema.pkg_transform_gen` — 仕様部
   （PASS_THROUGH 以外の各 `transform_<tgt>` のシグネチャ）
2. `CREATE OR REPLACE PACKAGE BODY ...` — 本体部
   - `INITIAL` モード: `INSERT INTO <tgt> (...) SELECT <列ごとの式> FROM <src> s <join>`
   - `DELTA` モード: `MERGE INTO <tgt> t USING (SELECT ... FROM <src> s <join> <差分窓>) src
     ON (<PK一致>) WHEN MATCHED THEN UPDATE ... WHEN NOT MATCHED THEN INSERT ...`
   - 差分窓: `src` テーブルに `UPDATED_AT` 列がある場合のみ
     `WHERE NVL(s.updated_at, s.created_at) > p_last AND ... <= p_snap` を付与
   - 各テーブルの最初と最後で `log_schema.pkg_transform.log_step` を呼び、
     件数（`v_src`/`v_tgt`）と状態（`RUNNING`/`SUCCESS`）を記録
3. `MERGE INTO log_schema.transform_catalog ...` / `MERGE INTO log_schema.transform_state ...`
   — `codegen_table_map` の内容を catalog/state に登録（`is_active='Y'` のみ、
   `sort_order` 順）。PASS_THROUGH の `proc_name` は `NULL`（コアが汎用処理）。

---

## 5. 分類自動判定ルール（derive_class）

`codegen_table_map.transform_class` が `NULL` の場合、`pkg_codegen.derive_class`
が以下の優先順位で自動判定する:

1. `join_clause` が `NOT NULL` → **HEAVY_TRANSFORM**
2. 対象テーブルに `codegen_column_map` の行が1件もない → **PASS_THROUGH**
3. すべての列が `transform_type='DIRECT'` かつ `arg_text` が `NONE`（型変換なし）
   → **PASS_THROUGH**
4. 上記以外 → **LIGHT_TRANSFORM**

明示的に `transform_class` を指定すれば、この自動判定をスキップして強制できる
（例: 列マッピングが全て DIRECT/NONE でも、業務上 LIGHT として扱いたい場合）。

PASS_THROUGH と判定された場合、`pkg_transform_gen` には対応する
`transform_<tgt>` プロシージャを生成しない（`transform_catalog.proc_name = NULL`）。
実行時はコア（`pkg_transform`）の汎用 PASS_THROUGH 処理（全列コピー）が動作する。

---

## 6. 利用者向けクイックスタート（実テーブルを入れる手順）

`72_seed_mapping_example.sql` を雛形として、自テーブル用に差し替える手順:

1. **DDL投入**: 移行元テーブルの DDL を STAGING_SCHEMA に、移行先テーブルの DDL を
   TARGET_SCHEMA に流す（DD は `dba_tab_columns` 経由で生成器が自動的に読む。
   DDL の生成自体は本仕組みのスコープ外）。
2. **マッピングファイルの作成**: `72_seed_mapping_example.sql` をコピーして
   利用者独自のファイル（例 `72_my_mapping.sql`）を作成する。
   - 冒頭の `DELETE FROM codegen_column_map; DELETE FROM codegen_table_map;`
     は既存マッピングの全クリアになる点に注意（複数ファイルに分割する場合は
     対象テーブル単位の `DELETE` に変更する）。
3. **テーブル対応の記入**: `codegen_table_map` に1行追加する。
   - `transform_class` は基本 `NULL`（自動判定に任せる）。
   - JOIN を伴う非正規化（HEAVY）の場合のみ `join_clause` を記述し、
     別名は `l_*`（例 `l_cust`/`l_reg`）の規約に合わせる。
   - `sort_order` は FK 親子関係を踏まえて親テーブルを小さく設定する
     （`REGIONS=5 < CUSTOMERS=10 < ORDERS=20 < ORDER_ENRICHED=40` のように）。
4. **列対応の記入**: `codegen_column_map` に列ごとに1行追加する。
   - そのままコピーする列は `DIRECT`/`NONE`。
   - 型変換（NUMBER/DATE/DATE_FROM_TS）が要る列は `DIRECT` の `arg_text` を変える。
   - 連結・コード変換・JSON抽出・式が要る列はそれぞれ `CONCAT`/`CODE_MAP`/
     `JSON_EXTRACT`/`EXPRESSION` を使う（3章参照）。
   - `col_order` は生成される列順に直結するため、PK等の必須列も漏らさず記入する。
5. **投入と生成**:
   ```bash
   docker cp sql/transform/72_my_mapping.sql oracle-tgt:/tmp/
   docker exec -u oracle oracle-tgt sqlplus -S '/ as sysdba' @/tmp/72_my_mapping.sql
   bash scripts/70_generate_transform.sh
   ```
6. **確認**: `generated/pkg_transform_gen.sql` の中身、`SHOW ERRORS` の結果、
   `transform_catalog` の登録内容（`transform_class`/`proc_name`）を確認する。
7. **実行**: `pkg_transform.transform_all` を呼び出して移行・差分反映を実施する
   （詳細は `docs/phase2-transform-design.md` 参照）。

`72_seed_mapping_example.sql` 自体は、既存の手書き変換
（`regions`=PASS_THROUGH／`customers`,`orders`=LIGHT／`order_enriched`=HEAVY）を
マッピングとして再現した受け入れ試験フィクスチャであり、各プリミティブの
実例集としても参照できる。

---

## 7. 制約・未対応事項

固定プリミティブで決定論的に表現できる範囲（DIRECT/CONCAT/CODE_MAP/
JSON_EXTRACT/EXPRESSION による1テーブル→1テーブルの列単位変換、および
LEFT JOIN による非正規化）が本仕組みのスコープである。以下は対象外:

- **1→N 分割／集約（GROUP BY 等）**: 単一テーブルを複数テーブルへ分割する変換、
  集約による grain 変更は固定プリミティブでは表現できない。`EXPRESSION` で
  サブクエリとして部分的に書くか、手書きの `transform_<tgt>` を別途用意する。
- **代理キー（サロゲートキー）の再採番・再マッピング**: 移行元PKと異なる
  新規キー体系へのマッピング（採番・対応表管理）は未対応。必要であれば
  `EXPRESSION` でルックアップ式として表現するか、別途シーケンス／対応表を
  用意した手書き処理が必要。
- **SCD（Slowly Changing Dimension）**: 履歴保持を伴う変換は本仕組みの
  決定論的1行→1行マッピングの枠組み外。手動実装、または将来拡張で対応する。
- **STAGING側DDL／Data Pump parfile の自動生成**: 本仕組みは「対応関係から
  変換PL/SQLを生成する」ことに特化しており、移行元・移行先のDDL生成や
  Data Pump 関連の生成は別スコープ（利用者が用意する入力の一部）。
- **マスタ変更の波及再変換**: マッピング設定（`codegen_table_map`/
  `codegen_column_map`）を変更した際に、既存の `pkg_transform_gen` の差分のみを
  再生成・再デプロイする仕組みは未対応。再生成は常に `generate_all` による
  全件再構築（既存行は `MERGE` で上書き）であり、影響範囲の分析・部分再実行は
  利用者の判断に委ねられる。

---

## 8. トラブルシュート

### 8.1 生成物がコンパイルエラーになる場合

- まず `scripts/70_generate_transform.sh` の手順 [2] で実行される
  `SHOW ERRORS PACKAGE BODY LOG_SCHEMA.PKG_TRANSFORM_GEN` の出力を確認する。
  `行番号/列番号` と `PLS-XXXXX`/`ORA-XXXXX` が表示されるので、
  `generated/pkg_transform_gen.sql` の該当行を直接特定できる。
- エラーの大半は `EXPRESSION`（`arg_text`に書いた生SQL式）または
  `join_clause` の構文誤りに起因する。マッピング側のテキストを修正し、
  再投入→`scripts/70_generate_transform.sh` を再実行する。
- `--no-deploy` で生成のみ行い、`generated/pkg_transform_gen.sql` を
  目視確認してからデプロイする運用も可能。

### 8.2 クォート・別名に関する注意

- `arg_text` に文字列リテラルを書く場合、SQL内の `'` は `''`（2重）でエスケープする
  必要がある（例: `'COALESCE(s.company_name, s.last_name||'' ''||s.first_name)'`
  — INSERT文中の文字列リテラルとしてのエスケープと、生成されるSQL内の
  文字列リテラルとしてのエスケープが二重にかかる点に注意）。
- 列名・表別名はダブルクォートで囲んで生成されるため
  （`s."CUSTOMER_ID"` 等）、`src_columns`/`tgt_column` は実際のDD上の
  大文字小文字と一致させる（Oracle標準のオブジェクト名は通常大文字）。
- `EXPRESSION` 内で主表を参照する場合は `s.<列名>`、HEAVY の JOIN 先を
  参照する場合は `join_clause` で定義した別名（`l_*`規約）をそのまま使う。
  別名の不一致は「無効な識別子（ORA-00904）」としてコンパイル時に検出される。
- `col_order` の重複・歯抜けは構文エラーにはならないが、生成される
  列順や可読性に影響するため、テーブル内で一意な連番を付ける。
