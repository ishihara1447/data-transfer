# Phase 2 変換層設計書: STAGING_SCHEMA → TARGET_SCHEMA

## 0. この文書の位置づけ

三分割アーキテクチャの第三フェーズ（③スキーマ変換層）を設計する。

```
① 基準SCN整合性   → Data Pump（FLASHBACK_SCN で整合点固定）         ← 設計済み
② コミット順差分   → LogMiner（COMMIT_SCN 基準・docs/phase1-commit-scn-redesign.md）  ← 設計済み
③ スキーマ差分吸収 → STAGING → TARGET の決定論的変換レイヤ          ← 本書が対象
```

前提文書:

- `docs/gap-analysis.md` — G5（変換層未実装）/ G6（テーブル3分類未設計）が本書の直接動機
- `docs/migration-design.md` — 既存の SRC→TGT 変換設計（顧客・注文の列マッピング）
- `docs/phase1-commit-scn-redesign.md` — STAGING_SCHEMA に差分が届く仕組み
- `docs/logging-and-error-handling.md` — ログテーブル設計（流用方針を定める）

---

## 1. スキーマ関係の全体像

### 1.1 三スキーマの役割

| スキーマ | 役割 | データの出所 | 変更権限 |
|---------|------|------------|---------|
| `SRC_SCHEMA` | 旧システムの稼動スキーマ。移行期間中も更新される | 旧システムのアプリケーション | 移行処理は読み取り専用 |
| `STAGING_SCHEMA` | `delta_apply` の着地点。旧スキーマ構造を保持 | ①初期ロード（Data Pump）＋ ②差分適用（LogMiner SQL_REDO） | `delta_apply` のみが書き込む |
| `TARGET_SCHEMA` | 新システムの正規化済みスキーマ | ③変換処理のみが生成する | 変換パッケージのみが書き込む |

### 1.2 スキーマ関係図

```
旧システム APP
     │
     ▼ DML（INSERT/UPDATE/DELETE）
SRC_SCHEMA
     │
     ├──① Data Pump（FLASHBACK_SCN で初期ロード）──────────────────────────┐
     │                                                                        │
     └──② LogMiner 差分抽出（COMMIT_SCN 基準）                               │
          │                                                                   │
          │  Data Pump搬送（06_transfer_delta_datapump.sh）                   │
          ▼                                                                   ▼
   delta_queue（oracle-tgt）                                         STAGING_SCHEMA
          │                                                                   │
          └──── delta_apply（SRC→STAGING 置換で SQL_REDO を適用） ────────────┘
                                                                              │
                                                  ③ transform（本フェーズが設計する処理）
                                                                              │
                                                                              ▼
                                                                      TARGET_SCHEMA
                                                                              │
                                                                       新システム APP
```

**重要な前提:**
- `STAGING_SCHEMA` の列構造は `SRC_SCHEMA` と完全に同一である。
  `delta_apply` は SQL_REDO の `SRC_SCHEMA` を `STAGING_SCHEMA` に文字置換して
  `EXECUTE IMMEDIATE` するため、STAGING 側のテーブル定義が SRC と一致していない場合は
  適用が失敗する。
- `TARGET_SCHEMA` の列構造は新システムの要件に従い、SRC とは異なる。
  変換はすべて STAGING → TARGET の間で行い、差分適用（②）と変換（③）を完全に分離する。

---

## 2. 統合方針（A. 全体統合方針）

### 2.1 問題の整理: 既存パッケージとの関係

`docs/migration-design.md` に定義した `log_schema.pkg_migration` の
`migrate_customer` / `migrate_order` は **SRC_SCHEMA → TGT_SCHEMA** の直接変換を前提とする。
三分割アーキテクチャに移行すると、①②の完了後に STAGING_SCHEMA にデータが蓄積されており、
変換元は `SRC_SCHEMA` ではなく `STAGING_SCHEMA` になる。

設計の選択肢は次の二案に集約される。

### 2.2 案の比較

#### 案A: 既存 migrate_* プロシージャをSTAGING対応に改修して再利用

読み取り元スキーマを `SRC_SCHEMA` から `STAGING_SCHEMA` に差し替えるパラメータを追加し、
既存の変換ロジック（列マッピング・型変換・コード変換）を流用する。

| 観点 | 評価 |
|------|------|
| 実装コスト | 低（スキーマ名の可変化のみ） |
| 概念の明確さ | 低（「初期一括変換」と「継続的な差分変換」が同一パッケージに混在） |
| 差分変換への拡張性 | 低（現設計が TRUNCATE&INSERT 前提のため、差分の MERGE・UPSERT に対応しにくい） |
| ログとの整合 | 中（run_id/step_log の概念がそのまま使えるが、差分バッチの概念が欠ける） |
| リスク | 差分変換モードを追加実装する際に設計が歪む。再実行方針（全量DELETE）が差分運用と矛盾する |

#### 案B: STAGING→TARGET 専用の変換パッケージを新設（推奨）

`pkg_transform` を新設し、`pkg_migration` の変換ロジック（型変換・コード変換等の純粋な関数）
を共有部品として切り出す。変換パッケージは初期全量変換と差分増分変換の両モードを持つ。

| 観点 | 評価 |
|------|------|
| 実装コスト | 中（変換ロジックの一部は `pkg_migration` から流用可能） |
| 概念の明確さ | 高（②の着地（delta_apply）と ③の変換（pkg_transform）が明確に分離） |
| 差分変換への拡張性 | 高（MERGE/UPSERT を初期設計から組み込める） |
| ログとの整合 | 高（transform_run_log / transform_step_log を独立管理できる） |
| リスク | 低（既存 pkg_migration を変更しないため、①の初期ロード検証に影響しない） |

#### 推奨: 案B（新規パッケージ建立）

以下の理由から案Bを推奨する。

1. **責務の分離**: `pkg_migration` は初期ロード（①）向け設計であり、差分変換の
   冪等性要件（MERGE）と一括変換の冪等性要件（TRUNCATE＋INSERT）は性格が異なる。
   同一パッケージに混在させると、将来の保守で意図しない影響が発生しやすい。

2. **差分変換はMERGE前提**: 差分が STAGING に継続的に届く運用では、TARGET に対して
   TRUNCATE＆INSERT を繰り返すことは現実的ではない（全量再変換のコストが高い）。
   MERGE（または DELETE/INSERT on PK）を基本とする新設計の方が実態に合う。

3. **変換ロジックの再利用**: `pkg_migration` の変換関数（`TO_DATE(col, 'YYYYMMDD')` の
   ラッパー・CASE によるコード変換等）を `pkg_transform_util` として抽出すれば、
   両パッケージが同じ変換ルールを参照でき、二重管理にならない。

### 2.3 変換タイミングの方式比較

STAGING に差分が継続的に届く中で、いつ・どの単位で TARGET への変換を行うか。

| 方式 | 説明 | 利点 | 欠点 | 推奨 |
|------|------|------|------|------|
| 差分到着ごとに即時変換 | delta_apply の直後に pkg_transform を呼ぶ | TARGET が常に最新 | delta_apply と変換の結合度が高まる | 非推奨 |
| 定期バッチ変換（推奨） | 差分は STAGING に蓄積し、定期的に（例: 15分毎）変換バッチを動かす | ②と③の完全分離。変換バッチの失敗が差分適用に影響しない | TARGET に最大1バッチ分の遅延 | 推奨 |
| カットオーバー直前一括変換 | 移行完了直前に一度だけ全量変換 | シンプル | 変換時間がカットオーバー停止時間に直結する | 補助的に使用 |

**推奨方針: 定期バッチ変換 ＋ カットオーバー直前追い込み**

```
通常運用中:
  STAGING に差分到着（delta_apply が随時適用）
     ↓
  定期変換バッチ（pkg_transform.transform_all）が STAGING を読んで TARGET を MERGE
     ↓
  TARGET は最大1バッチ分の遅延で追従

カットオーバー直前:
  SRC の書き込みを停止 → 最終差分を STAGING に適用 → 最終変換バッチを実行
  → TARGET が SRC と一致したことを確認 → 新システムに切り替え
```

この方針により、変換バッチの障害は TARGET の遅延を生じさせるが、差分適用（②）の継続性に
影響しない。また、カットオーバー直前の「最終バッチ」は同じパッケージをそのまま使えるため、
手順が単純になる。

---

## 3. テーブル3分類フレームワーク（B. テーブル3分類フレームワーク / G6）

### 3.1 分類定義と判定基準

全移行対象テーブルを以下の3分類に判定し、分類ごとに異なる変換経路を適用する。

#### 分類1: 無変換（PASS_THROUGH）

STAGING の列構造が TARGET と完全に一致し、データの変換が不要なテーブル。

**判定基準（すべてに該当すること）:**
- 列数・列名・データ型が STAGING と TARGET で一致する
- コード変換が不要（ステータスコードの意味変更等がない）
- 主キーの型変換が不要（VARCHAR2 → NUMBER 等が発生しない）
- 正規化対応が不要（1テーブルから複数テーブルへの分割がない）

**処理経路:**

```
STAGING.テーブルX → INSERT /*+ APPEND */ INTO TARGET.テーブルX  （初期全量）
STAGING.テーブルX → MERGE INTO TARGET.テーブルX              （差分増分）
```

変換ロジックを介さず、STAGING から TARGET へ直接 INSERT/MERGE する。
変換パッケージは汎用的なコピーロジック（PK指定・バッチサイズ指定）を提供する。

#### 分類2: 軽微変換（LIGHT_TRANSFORM）

列構造の変更は最小限だが、型変換・コード変換・NULL補完等の行内変換が必要なテーブル。

**判定基準（無変換に非該当かつ、以下のいずれかに該当すること）:**
- 日付文字列（VARCHAR2）→ DATE 型への変換がある
- 数値文字列（VARCHAR2）→ NUMBER 型への変換がある
- コードの意味変換がある（例: '10' → 'ACCEPTED'）
- 列名の変更がある（列の分割・結合は伴わない）
- NULL デフォルト値の補完がある

**処理経路:**

```
STAGING.テーブルX → 変換関数（pkg_transform_util の共有関数）
                  → MERGE INTO TARGET.テーブルX
```

行内変換はすべて `pkg_transform_util` の共有関数として実装し、
変換プロシージャからこれを呼び出す。

#### 分類3: 重変換（HEAVY_TRANSFORM）

テーブルの正規化・結合・分割を伴い、1:1では変換できないテーブル。

**判定基準（以下のいずれかに該当すること）:**
- 1テーブルが複数テーブルに分割される（正規化）
- 複数テーブルを JOIN して1テーブルを生成する（非正規化の統合）
- 住所等の非構造化列を複数列に分解する（STAGING 内での構造化が必要）
- 外部参照の ID 変換が必要（旧 ID 体系 → 新 ID 体系のマッピングテーブルを参照）

**処理経路:**

```
STAGING.テーブルX（+ 参照テーブル群）
  → 変換プロシージャ（テーブル専用の pkg_transform.transform_テーブル名）
  → MERGE INTO TARGET.テーブルA
  → MERGE INTO TARGET.テーブルB（分割先が複数ある場合）
```

重変換テーブルは専用プロシージャを個別実装する。共通化は難しいが、
変換関数（日付変換・コード変換等）は `pkg_transform_util` を共有する。

### 3.2 サンプルテーブルの分類判定

`docs/migration-design.md` に定義されたサンプルテーブルへの適用:

| テーブル | 分類 | 判定理由 |
|---------|------|---------|
| `customers` | HEAVY_TRANSFORM | `cust_id` の VARCHAR2→NUMBER 変換、`cust_name` の姓名分離、`address` の3列分解、`create_date` の VARCHAR2→DATE 変換が複合する |
| `orders` | LIGHT_TRANSFORM | PK/FK は型変換あり（cust_id: VARCHAR2→NUMBER）、`order_date` VARCHAR2→DATE、`status` コード変換。列の分割・結合はなし |

> 実運用では全対象テーブルについて上記判定基準を適用し、`transform_catalog`（後述）に登録する。

### 3.3 変換カタログ（transform_catalog）設計

分類情報を管理するメタデータ表。変換処理の起動制御・監視クエリに使用する。

```sql
-- 変換カタログ（メタデータ管理テーブル）
CREATE TABLE log_schema.transform_catalog (
    catalog_id        NUMBER(10)     NOT NULL,  -- 採番（SEQUENCE + トリガー）
    src_table_name    VARCHAR2(100)  NOT NULL,  -- STAGING 側テーブル名（例: 'CUSTOMERS'）
    tgt_table_name    VARCHAR2(100)  NOT NULL,  -- TARGET 側テーブル名（例: 'CUSTOMERS'）
    transform_class   VARCHAR2(20)   NOT NULL,  -- PASS_THROUGH / LIGHT_TRANSFORM / HEAVY_TRANSFORM
    proc_name         VARCHAR2(200),            -- 呼び出す変換プロシージャ名（HEAVY_TRANSFORM 用）
    pk_columns        VARCHAR2(400),            -- PK 列名（MERGE の ON 句に使用）
    sort_order        NUMBER(5)      NOT NULL,  -- FK 依存順（親テーブルを先に処理）
    is_active         VARCHAR2(1)    DEFAULT 'Y', -- Y/N（無効化によるスキップ）
    remarks           VARCHAR2(4000),           -- 変換方針の補足説明
    CONSTRAINT pk_transform_catalog PRIMARY KEY (catalog_id),
    CONSTRAINT uq_transform_catalog_src UNIQUE (src_table_name),
    CONSTRAINT chk_transform_class CHECK (
        transform_class IN ('PASS_THROUGH', 'LIGHT_TRANSFORM', 'HEAVY_TRANSFORM')
    ),
    CONSTRAINT chk_transform_active CHECK (is_active IN ('Y', 'N'))
);
```

**カタログ登録例:**

| src_table_name | tgt_table_name | transform_class | sort_order | 備考 |
|----------------|----------------|-----------------|-----------|------|
| CUSTOMERS | CUSTOMERS | HEAVY_TRANSFORM | 10 | 姓名分離・住所分解・日付型変換 |
| ORDERS | ORDERS | LIGHT_TRANSFORM | 20 | コード変換・日付型変換 |

> `sort_order` は FK 依存関係を反映する（親テーブルを先に変換）。
> `CUSTOMERS` を先に変換しないと `ORDERS` の FK 参照が失敗する。

---

## 4. TARGET_SCHEMA DDL スケルトン方針（C. TARGET_SCHEMA 設計）

### 4.1 設計原則

`docs/migration-design.md` に示された TGT_SCHEMA の設計（新顧客マスタ・新注文データ）を
TARGET_SCHEMA の目標構造として採用する。Phase 2 では以下の方針を明確にする。

- TARGET_SCHEMA の DDL 完全実装は実装フェーズで行う。
- 本書は「目標構造の方針」と「STAGING との差分（変換が必要な箇所）」を明記する。

### 4.2 customers テーブルの目標構造

`migration-design.md` で定義した TGT_SCHEMA.CUSTOMERS をそのまま TARGET の目標とする。

**STAGING → TARGET の主要な変換ポイント:**

| STAGING 列（SRC と同一） | TARGET 列 | 変換方針 |
|------------------------|----------|---------|
| `cust_id` VARCHAR2(10) | `customer_id` NUMBER(10) | `TO_NUMBER(cust_id)` 。数値以外は `migration_error_log` に記録して NULL 化（または実行中断、運用方針に依存） |
| `cust_name` VARCHAR2(200) | `customer_name` VARCHAR2(200) | そのままコピー（姓名分離は将来対応として現フェーズでは省略、remarks に記録） |
| `tel` VARCHAR2(20) | `phone` VARCHAR2(20) | そのままコピー |
| `address` VARCHAR2(400) | `prefecture` VARCHAR2(10) | 先頭3〜4文字（都道府県）を SUBSTR で抽出。実用変換ルールは実装フェーズで決定 |
| `address` VARCHAR2(400) | `city` VARCHAR2(100) | SUBSTR によるパターン抽出（実装フェーズで決定） |
| `address` VARCHAR2(400) | `address_detail` VARCHAR2(300) | 都道府県・市区町村を除いた残余部分 |
| `create_date` VARCHAR2(8) | `created_at` DATE | `REGEXP_LIKE(col, '^[0-9]{8}$')` 検証後に `TO_DATE(col, 'YYYYMMDD')`。不正値は NULL |

**分類: HEAVY_TRANSFORM**
- 1列（address）から3列（prefecture / city / address_detail）への分解が発生するため。
- 単純な列内変換（日付・コード）も複合するため、専用プロシージャを要する。

### 4.3 orders テーブルの目標構造

`migration-design.md` で定義した TGT_SCHEMA.ORDERS をそのまま TARGET の目標とする。

**STAGING → TARGET の主要な変換ポイント:**

| STAGING 列（SRC と同一） | TARGET 列 | 変換方針 |
|------------------------|----------|---------|
| `order_id` NUMBER(10) | `order_id` NUMBER(10) | そのままコピー（PK） |
| `cust_id` VARCHAR2(10) | `customer_id` NUMBER(10) | `TO_NUMBER(cust_id)` |
| `order_date` VARCHAR2(8) | `order_date` DATE | `TO_DATE` 変換（`create_date` と同方針） |
| `amount` NUMBER(12,2) | `total_amount` NUMBER(12,2) | そのままコピー（列名変更のみ） |
| `status` VARCHAR2(2) | `order_status` VARCHAR2(20) | コード変換（下表） |

**ステータスコード変換（`migration-design.md` の定義を継承）:**

| SRC/STAGING 値 | TARGET 値 |
|---------------|----------|
| '10' | 'ACCEPTED' |
| '20' | 'PROCESSING' |
| '30' | 'COMPLETED' |
| '99' | 'CANCELLED' |
| その他 | 'UNKNOWN' |

**分類: LIGHT_TRANSFORM**
- 列の分割・結合はなし（1:1変換）。型変換・コード変換・列名変更のみ。

### 4.4 FK 制約の適用タイミング

TARGET_SCHEMA では `customers.customer_id` を参照する `orders.customer_id` の FK 制約が存在する。
変換バッチは `sort_order`（transform_catalog）に従い、CUSTOMERS → ORDERS の順に処理する。

**初期全量変換時:** CUSTOMERS の全量 INSERT 完了後に ORDERS を変換する。
FK 制約は事前に DISABLE し、全量変換完了後に ENABLE VALIDATE する（変換時間の短縮）。

**差分増分変換時:** CUSTOMERS の差分 MERGE が完了してから ORDERS の差分 MERGE を行う。
同一変換バッチ内での順序を `sort_order` で保証する。

---

## 5. 変換パッケージ設計（pkg_transform）

### 5.1 パッケージ構成方針

変換処理を3層に分ける。

```
pkg_transform             ── エントリポイント・制御（初期全量 / 差分増分）
  ├─ transform_all()        ← 全テーブルを transform_catalog に従い順次変換
  ├─ transform_by_table()   ← 1テーブル単位の変換（テスト・再実行用）
  └─ transform_customers()  ← HEAVY_TRANSFORM テーブルの専用プロシージャ
     transform_orders()     ← LIGHT_TRANSFORM テーブルの専用プロシージャ（以下同様）

pkg_transform_util        ── 共有変換関数（pkg_migration とも共有可能）
  ├─ safe_to_date()         ← REGEXP_LIKE + TO_DATE ラッパー（不正値は NULL）
  ├─ safe_to_number()       ← REGEXP_LIKE + TO_NUMBER ラッパー
  └─ map_order_status()     ← CASE によるステータスコード変換
```

### 5.2 pkg_transform の SPEC 概要

```sql
CREATE OR REPLACE PACKAGE log_schema.pkg_transform AS

    -- モード定数
    C_MODE_INITIAL   CONSTANT VARCHAR2(10) := 'INITIAL';   -- 初期全量変換（TRUNCATE + INSERT）
    C_MODE_DELTA     CONSTANT VARCHAR2(10) := 'DELTA';     -- 差分増分変換（MERGE）

    -- メインエントリポイント
    -- p_mode: C_MODE_INITIAL または C_MODE_DELTA
    -- p_run_name: ログ管理用の実行識別名
    PROCEDURE transform_all(
        p_run_name   IN VARCHAR2,
        p_mode       IN VARCHAR2 DEFAULT 'DELTA',
        p_batch_size IN NUMBER   DEFAULT 10000
    );

    -- テーブル単位の変換（個別実行・再実行用）
    PROCEDURE transform_by_table(
        p_run_id      IN NUMBER,
        p_table_name  IN VARCHAR2,
        p_mode        IN VARCHAR2 DEFAULT 'DELTA',
        p_batch_size  IN NUMBER   DEFAULT 10000
    );

    -- HEAVY_TRANSFORM テーブルの専用プロシージャ
    PROCEDURE transform_customers(
        p_run_id     IN NUMBER,
        p_mode       IN VARCHAR2,
        p_batch_size IN NUMBER
    );

    -- LIGHT_TRANSFORM テーブルの専用プロシージャ
    PROCEDURE transform_orders(
        p_run_id     IN NUMBER,
        p_mode       IN VARCHAR2,
        p_batch_size IN NUMBER
    );

    -- ログユーティリティ（log_schema.migration_run_log / step_log / error_log を流用）
    FUNCTION  log_run_start(p_run_name IN VARCHAR2, p_mode IN VARCHAR2) RETURN NUMBER;
    PROCEDURE log_run_end(
        p_run_id    IN NUMBER,
        p_status    IN VARCHAR2,
        p_src_count IN NUMBER DEFAULT 0,
        p_tgt_count IN NUMBER DEFAULT 0,
        p_error_msg IN VARCHAR2 DEFAULT NULL
    );
    PROCEDURE log_step(
        p_run_id    IN NUMBER,
        p_step_name IN VARCHAR2,
        p_status    IN VARCHAR2,
        p_src_count IN NUMBER DEFAULT 0,
        p_tgt_count IN NUMBER DEFAULT 0,
        p_batch_no  IN NUMBER DEFAULT 0
    );
    PROCEDURE log_error(
        p_run_id       IN NUMBER,
        p_step_name    IN VARCHAR2,
        p_error_code   IN NUMBER,
        p_error_msg    IN VARCHAR2,
        p_backtrace    IN VARCHAR2,
        p_record_id    IN VARCHAR2 DEFAULT NULL,
        p_target_table IN VARCHAR2 DEFAULT NULL,
        p_batch_no     IN NUMBER   DEFAULT NULL,
        p_error_context IN VARCHAR2 DEFAULT NULL
    );

END pkg_transform;
/
```

### 5.3 transform_all の制御フロー

```
PROCEDURE transform_all(p_run_name, p_mode, p_batch_size)
│
├─ 1. RUNNING チェック（同名 run_name が RUNNING なら RAISE）
│
├─ 2. log_run_start → run_id 取得
│
├─ 3. transform_catalog を sort_order 順に SELECT（is_active = 'Y' のみ）
│
├─ 4. FOR LOOP（カタログ順に各テーブルを処理）
│   │
│   ├─ [PASS_THROUGH]
│   │    汎用コピープロシージャを呼び出し
│   │    MODE=INITIAL: DELETE + BULK INSERT
│   │    MODE=DELTA  : MERGE（PK一致で UPDATE、不一致で INSERT）
│   │
│   ├─ [LIGHT_TRANSFORM]
│   │    proc_name に基づき動的呼び出しまたは専用プロシージャを呼び出し
│   │    MODE=INITIAL: DELETE + 変換 INSERT
│   │    MODE=DELTA  : 変換 MERGE
│   │
│   └─ [HEAVY_TRANSFORM]
│        proc_name（例: 'TRANSFORM_CUSTOMERS'）を呼び出し
│        MODE に応じて全量または差分変換
│
├─ 5. log_run_end（status='SUCCESS'）
│
EXCEPTION WHEN OTHERS
│   log_error（SQLCODE / SQLERRM / BACKTRACE）
│   log_run_end（status='FAILED'）
└─  RAISE
```

### 5.4 INITIAL モードと DELTA モードの処理差異

| 処理項目 | INITIAL モード | DELTA モード |
|---------|--------------|------------|
| 変換前の TARGET クリア | DELETE（FK 依存順で子→親の順に全件削除）し COMMIT | 不要 |
| FK 制約 | 変換開始前に DISABLE し、全テーブル完了後に ENABLE VALIDATE | 有効のまま（MERGE が FK 制約を検証） |
| TARGET への書き込み | BULK COLLECT + FOR LOOP INSERT（`pkg_migration` と同方式） | MERGE INTO（PK ON 句で UPDATE/INSERT を振り分け） |
| 変換対象の STAGING 行 | STAGING の全行 | 前回変換実行時以降に `delta_apply` が更新した行（後述） |
| 冪等性の実現方法 | DELETE + INSERT（再実行で全件再変換） | MERGE（再実行で同じ結果になる） |

### 5.5 差分変換対象の特定

DELTA モードでは、前回変換バッチ以降に STAGING に反映された行のみを変換する必要がある。
対象行の特定方針を以下の2案から選択する。

#### 方針1: staging_updated_at タイムスタンプ（推奨）

`delta_apply` が STAGING に行を書き込む際に `updated_at TIMESTAMP DEFAULT SYSTIMESTAMP`
列を更新する。変換バッチは前回変換の終了タイムスタンプ以降に更新された行を対象とする。

```sql
-- transform_run_log の last_transform_at を参照して変換対象を絞り込む
SELECT * FROM staging_schema.customers
WHERE updated_at > v_last_transform_at
ORDER BY updated_at;
```

メリット: シンプル。タイムスタンプ列のインデックスがあれば高速。
デメリット: `updated_at` を `delta_apply` が必ず更新する実装が前提。時刻の逆行に注意。

#### 方針2: commit_scn 連携

`delta_apply` が STAGING に適用した最大 `commit_scn` を `staging_ctl.delta_apply_state.last_applied_commit_scn` から取得し、前回変換時の `last_transform_commit_scn` 以降の commit_scn を持つ行を変換対象とする。
STAGING テーブルに `last_commit_scn NUMBER` 列を追加する必要がある。

メリット: 差分境界が commit_scn と一致し、②との連携が明確。
デメリット: STAGING テーブルへの列追加が必要。delta_apply の改修も伴う。

**推奨: まず方針1で実装し、SCN 連携は運用安定後に検討する。**

---

## 6. 決定論的変換と冪等性（D. 決定論的変換と冪等性）

### 6.1 決定論的変換の定義と保証方法

変換処理は「同じ STAGING 入力から常に同じ TARGET 出力を生成する」ことを保証する。
これを**決定論的変換**と呼ぶ。

保証のための設計ルール:

| ルール | 具体的な実装方針 |
|--------|---------------|
| SYSDATE・SYSTIMESTAMP を変換値に使用しない | 変換結果列に現在時刻を埋め込まない（監査列 `converted_at` は別列とする） |
| DBMS_RANDOM 等を使用しない | 変換結果が実行ごとに変化する関数を禁止 |
| 変換関数の副作用を禁止 | `pkg_transform_util` の関数はすべて PURE（入力のみで結果が決まる） |
| コード変換は CASE 式で明示 | 暗黙の型キャストに依存しない |
| 不正値のハンドリングを明示 | NULL に変換するか ERROR にするかを変換カタログに記録 |

### 6.2 再実行可能性の設計

#### INITIAL モード（初期全量変換）

```
1. TARGET のデータを全件削除（DELETE + COMMIT、FK 依存順に子→親）
2. STAGING から全件読み込み → 変換 → TARGET に INSERT
3. 全テーブル完了後に FK 制約を ENABLE VALIDATE
```

失敗時に再実行すると手順1から再度実行されるため、部分変換の残余が残らない。
`pkg_migration` の設計（`docs/migration-design.md` の冪等性方針）と同方式。

#### DELTA モード（差分増分変換）

```
MERGE INTO target_schema.テーブル t
USING (
    SELECT /* 変換後の列値 */
    FROM staging_schema.テーブル s
    WHERE s.updated_at > v_last_transform_at
) src
ON (t.pk列 = src.pk列)
WHEN MATCHED THEN
    UPDATE SET t.列1 = src.列1, t.列2 = src.列2, ...
WHEN NOT MATCHED THEN
    INSERT (t.pk列, t.列1, ...) VALUES (src.pk列, src.列1, ...)
```

MERGE は本質的に冪等（同じ条件で再実行しても結果が同じ）。
ただし STAGING の `updated_at` が変換バッチの前後で変化しないことが前提。

#### 削除（DELETE）の扱い

SRC で削除されたレコードは `delta_apply` によって STAGING からも削除される。
STAGING にない PK は TARGET にも存在すべきでないため、定期的な差分検証が必要。

削除伝播の方針:

```
方針A: DELTA モード変換バッチで TARGET にも DELETE を伝播する
  → STAGING に存在しないが TARGET に存在する PK を検出して DELETE
  → 変換バッチのコストが増加するが、TARGET が常に STAGING と整合

方針B: 削除は定期的な整合確認バッチで処理する（変換バッチから分離）
  → 変換バッチをシンプルに保てる
  → TARGET にゴースト行が残る期間が生じる
```

いずれの方針を採用するかは実装フェーズで決定する。
PoC 段階では全量再変換（INITIAL モード）で整合を取ることも選択肢となる。

### 6.3 二段階検証（G12）との接続点

`docs/gap-analysis.md` の G12 に記載された二段階検証は、変換後の TARGET の正しさを
確認する仕組みとして Phase 2 の成功条件に直結する。

**変換後に実施する検証:**

```
第1段階: 件数検証（形式検証）
  STAGING の件数 = TARGET の件数
  ※ 分類1（PASS_THROUGH）は 1:1 のため件数が一致するはず
  ※ 重変換で分割が発生する場合は件数の一致条件を事前定義する

第2段階: 内容検証（業務整合性検証）
  (a) サンプルハッシュ: STAGING と TARGET の代表行を列変換後に突合
  (b) 業務集計: SRC/STAGING の集計値（例: 注文金額合計）と TARGET の集計値を比較
  (c) NOT NULL 制約の充足確認: TARGET で NOT NULL 列に NULL が入っていないか
```

変換バッチの `transform_step_log` に `src_count / tgt_count` を記録する設計は
`pkg_migration` の `migration_step_log` と同じ構造とする（第1段階検証の基礎データ）。

---

## 7. ログ設計（変換層のログ方針）

### 7.1 既存ログテーブルの流用方針

`docs/logging-and-error-handling.md` に定義した3テーブル
（`migration_run_log` / `migration_step_log` / `migration_error_log`）を
変換バッチのログにも流用する。

`run_name` の命名規則で初期ロードと変換バッチを区別する。

| 処理 | run_name の例 | step_name の例 |
|------|-------------|--------------|
| 初期ロード（pkg_migration） | `INITIAL_20260607` | `MIGRATE_CUSTOMER` |
| 初期全量変換 | `TRANSFORM_INITIAL_20260607` | `TRANSFORM_CUSTOMERS` |
| 差分変換バッチ | `TRANSFORM_DELTA_20260607_001` | `TRANSFORM_ORDERS` |

### 7.2 変換層固有の追加情報

`migration_step_log` の `batch_no` と `src_count / tgt_count` で
変換の進捗を追跡する（`pkg_migration` と同方式）。

変換層固有の追加情報は `error_context` 列に以下の形式で記録する。

```
error_context = 'mode=DELTA, transform_class=LIGHT_TRANSFORM, '
              || 'last_transform_at=' || TO_CHAR(v_last_transform_at, 'YYYY-MM-DD HH24:MI:SS')
              || ', batch_no=' || v_batch_no
```

### 7.3 AUTONOMOUS TRANSACTION の継続使用

ログ記録は `pkg_migration` と同様に AUTONOMOUS TRANSACTION を使用し、
変換処理の ROLLBACK でログが消えない設計とする。

---

## 8. Oracle 12c 互換設計の確認

本設計が採用する機能の 12c 互換性を確認する。

| 採用機能 | 12c での利用可否 | 備考 |
|---------|---------------|------|
| MERGE 文 | 利用可（9i 以降） | UPSERT の標準実装 |
| BULK COLLECT + FOR LOOP | 利用可 | `pkg_migration` と同方式 |
| REGEXP_LIKE | 利用可（10g 以降） | `pkg_migration` と同方式 |
| TO_DATE / TO_NUMBER | 利用可 | バージョン非依存 |
| CASE 式 | 利用可 | バージョン非依存 |
| PRAGMA AUTONOMOUS_TRANSACTION | 利用可 | ログ記録に使用 |
| DBMS_UTILITY.FORMAT_ERROR_BACKTRACE | 利用可（10g R2 以降） | `pkg_migration` と同方式 |
| SEQUENCE + BEFORE INSERT トリガー | 利用可 | IDENTITY 列の代替（ポリシー準拠） |
| TIMESTAMP 型 | 利用可 | `updated_at` 列に使用 |
| WHEN OTHERS THEN RAISE | 利用可 | エラー握りつぶし禁止ポリシー準拠 |

採用しない機能（非互換リスクあり）:

| 不採用機能 | 理由 |
|-----------|------|
| JSON_OBJECT 等の JSON 関数 | 12c R2 以降。`oracle-compatibility-policy.md` で禁止 |
| IDENTITY 列 | 同ポリシーで禁止 |
| FETCH FIRST n ROWS | 12.1 での動作保証が不明。ROW_NUMBER() で代替 |

---

## 9. 処理フロー概要（DELTA モードの定期バッチ）

```
定期バッチ起動（例: cron / PowerShell スケジューラ）
│
├─ SQL*Plus 呼び出し
│   └─ EXECUTE log_schema.pkg_transform.transform_all(
│           p_run_name   => 'TRANSFORM_DELTA_20260607_001',
│           p_mode       => 'DELTA',
│           p_batch_size => 10000
│      );
│
│   ├─ log_run_start → run_id 取得
│   │
│   ├─ transform_catalog を sort_order 順にカーソル OPEN
│   │
│   ├─ テーブル1: CUSTOMERS（HEAVY_TRANSFORM）
│   │   ├─ log_step（RUNNING）
│   │   ├─ STAGING.CUSTOMERS から updated_at > last_transform_at を BULK COLLECT
│   │   ├─ 変換ロジック（safe_to_number / safe_to_date / 住所分解）
│   │   ├─ MERGE INTO TARGET.CUSTOMERS（バッチ単位でCOMMIT）
│   │   └─ log_step（SUCCESS, src_count, tgt_count, batch_no）
│   │
│   ├─ テーブル2: ORDERS（LIGHT_TRANSFORM）
│   │   ├─ log_step（RUNNING）
│   │   ├─ STAGING.ORDERS から updated_at > last_transform_at を BULK COLLECT
│   │   ├─ 変換ロジック（safe_to_number / safe_to_date / map_order_status）
│   │   ├─ MERGE INTO TARGET.ORDERS（バッチ単位でCOMMIT）
│   │   └─ log_step（SUCCESS, src_count, tgt_count, batch_no）
│   │
│   └─ log_run_end（SUCCESS）
│
├─ 終了コード確認
└─ 外部ログファイル保存

エラー時:
│   ├─ ROLLBACK（失敗バッチ分のみ）
│   ├─ log_error（SQLCODE / SQLERRM / BACKTRACE / error_context）
│   └─ log_run_end（FAILED）
```

---

## 10. 実装フェーズで決めるべき未決事項

以下の事項は本設計書では方針の選択肢を示したが、実装前の確定が必要。

### 必須決定事項（実装着手前）

| # | 事項 | 選択肢 | 推奨 |
|---|------|--------|------|
| 1 | 差分変換対象の特定方法 | staging_updated_at タイムスタンプ（方針1）/ commit_scn 連携（方針2） | 方針1から着手 |
| 2 | STAGING テーブルへの `updated_at` 列追加方法 | delta_apply 改修で追加 / INSERT/UPDATE トリガーで追加 | 実装コストが低い方を選択 |
| 3 | TARGET 削除の伝播方法 | DELTA バッチで検出・削除 / 整合確認バッチで別途処理 | 実装フェーズで PoC して決定 |
| 4 | INITIAL モード時の FK 制約制御 | 変換前 DISABLE + 変換後 ENABLE VALIDATE / FK 依存順を守り有効のまま | テーブル数・データ量による |
| 5 | customers の姓名分離 | Phase 2 で実装 / 将来対応として `customer_name` は未分離のまま TARGET に移す | 新システム要件による |
| 6 | 住所3列への分解ロジック（都道府県・市区町村の抽出） | REGEXP_SUBSTR によるパターンマッチング / 外部辞書テーブル参照 | データ品質の事前調査が必要 |

### 運用設計事項（カットオーバー前に決定）

| # | 事項 | 内容 |
|---|------|------|
| 7 | 定期バッチの実行間隔 | 許容遅延と変換コストのバランスによる。15分〜1時間が目安 |
| 8 | 整合確認バッチ（G12）の実施タイミング | 変換バッチの直後 / 独立したスケジュール |
| 9 | カットオーバー時の最終変換手順 | SRC 停止 → 最終差分適用 → 最終変換バッチ → 件数・ハッシュ検証 の詳細手順 |
| 10 | 全量再変換（INITIAL モード）のトリガー条件 | TARGET データ破損 / 変換ロジック変更時の再実行基準 |

### 本番環境固有事項（本番検討フェーズで決定）

| # | 事項 | 内容 |
|---|------|------|
| 11 | TARGET_SCHEMA のユーザー・権限設計 | 変換パッケージのオーナースキーマと TARGET スキーマの権限分離 |
| 12 | 変換カタログの管理フロー | テーブル追加時のカタログ登録手順・承認フロー |
| 13 | LOB 列を含むテーブルの変換経路（G13） | EMPTY_CLOB/BLOB の FLASHBACK QUERY フォールバック統合 |
