# 移行設計書

## 概要

同一 Oracle DB 内の旧スキーマ（SRC_SCHEMA）から新スキーマ（TGT_SCHEMA）へのデータ移行設計。  
DB Link なし、ステージングテーブルなし、PL/SQL による移行処理本体。

---

## スキーマ設計

### 旧スキーマ（SRC_SCHEMA）

旧システムのレガシー設計を模倣。日付を VARCHAR2 で持つ、正規化が不十分などの典型的なレガシー構造を含む。

#### customers テーブル（旧顧客マスタ）

```sql
CREATE TABLE src_schema.customers (
    cust_id     VARCHAR2(10)   NOT NULL,   -- 顧客ID（文字列）
    cust_name   VARCHAR2(200)  NOT NULL,   -- 顧客名（姓名未分離）
    tel         VARCHAR2(20),              -- 電話番号（ハイフンあり・なし混在）
    address     VARCHAR2(400),             -- 住所（都道府県〜番地を1カラムに格納）
    create_date VARCHAR2(8),               -- 登録日（YYYYMMDD形式の文字列）
    CONSTRAINT pk_src_customers PRIMARY KEY (cust_id)
);
```

#### orders テーブル（旧注文データ）

```sql
CREATE TABLE src_schema.orders (
    order_id    NUMBER(10)     NOT NULL,   -- 注文ID
    cust_id     VARCHAR2(10)   NOT NULL,   -- 顧客ID（外部キー）
    order_date  VARCHAR2(8),               -- 注文日（YYYYMMDD形式の文字列）
    amount      NUMBER(12,2),              -- 金額
    status      VARCHAR2(2),               -- ステータス（'10':受付,'20':処理中,'30':完了,'99':キャンセル）
    CONSTRAINT pk_src_orders PRIMARY KEY (order_id),
    CONSTRAINT fk_src_orders_cust FOREIGN KEY (cust_id) REFERENCES src_schema.customers(cust_id)
);
```

---

### 新スキーマ（TGT_SCHEMA）

新システムの設計。型の正規化・住所の分割・コード値の変換等を含む。

#### customers テーブル（新顧客マスタ）

```sql
CREATE TABLE tgt_schema.customers (
    customer_id    NUMBER(10)    NOT NULL,  -- 顧客ID（数値）← 旧 cust_id を変換
    customer_name  VARCHAR2(200) NOT NULL,  -- 顧客名
    phone          VARCHAR2(20),            -- 電話番号（ハイフン統一）
    prefecture     VARCHAR2(10),            -- 都道府県
    city           VARCHAR2(100),           -- 市区町村
    address_detail VARCHAR2(300),           -- 番地以降
    created_at     DATE,                    -- 登録日（DATE型）← 旧 create_date を変換
    CONSTRAINT pk_tgt_customers PRIMARY KEY (customer_id)
);
```

#### orders テーブル（新注文データ）

```sql
CREATE TABLE tgt_schema.orders (
    order_id      NUMBER(10)    NOT NULL,  -- 注文ID
    customer_id   NUMBER(10)    NOT NULL,  -- 顧客ID（外部キー）
    order_date    DATE,                    -- 注文日（DATE型）← 旧 order_date を変換
    total_amount  NUMBER(12,2),            -- 金額
    order_status  VARCHAR2(20),            -- ステータス（'ACCEPTED','PROCESSING','COMPLETED','CANCELLED'）
    CONSTRAINT pk_tgt_orders PRIMARY KEY (order_id),
    CONSTRAINT fk_tgt_orders_cust FOREIGN KEY (customer_id) REFERENCES tgt_schema.customers(customer_id)
);
```

---

## スキーマ間マッピング定義

### customers マッピング

| 旧カラム（SRC） | 型（旧） | 新カラム（TGT） | 型（新） | 変換ロジック |
|---------------|---------|---------------|---------|-------------|
| cust_id | VARCHAR2(10) | customer_id | NUMBER(10) | `TO_NUMBER(cust_id)` |
| cust_name | VARCHAR2(200) | customer_name | VARCHAR2(200) | そのままコピー |
| tel | VARCHAR2(20) | phone | VARCHAR2(20) | そのままコピー（正規化は将来対応）|
| address ※先頭N文字 | VARCHAR2(400) | prefecture | VARCHAR2(10) | 先頭3〜4文字（都道府県）を抽出 |
| address ※中間部分 | VARCHAR2(400) | city | VARCHAR2(100) | SUBSTR でパターン抽出 |
| address ※残り | VARCHAR2(400) | address_detail | VARCHAR2(300) | 残りの文字列 |
| create_date | VARCHAR2(8) | created_at | DATE | `TO_DATE(create_date, 'YYYYMMDD')` |

> **注記:** 住所の分割は本サンプルでは都道府県のみ SUBSTR で抽出し、残りを address_detail に格納する簡略版とする。

### orders マッピング

| 旧カラム（SRC） | 型（旧） | 新カラム（TGT） | 型（新） | 変換ロジック |
|---------------|---------|---------------|---------|-------------|
| order_id | NUMBER(10) | order_id | NUMBER(10) | そのままコピー |
| cust_id | VARCHAR2(10) | customer_id | NUMBER(10) | `TO_NUMBER(cust_id)` |
| order_date | VARCHAR2(8) | order_date | DATE | `TO_DATE(order_date, 'YYYYMMDD')` |
| amount | NUMBER(12,2) | total_amount | NUMBER(12,2) | そのままコピー |
| status | VARCHAR2(2) | order_status | VARCHAR2(20) | コード変換（下記参照）|

### ステータスコード変換

| 旧コード | 旧意味 | 新ステータス |
|---------|-------|------------|
| '10' | 受付 | 'ACCEPTED' |
| '20' | 処理中 | 'PROCESSING' |
| '30' | 完了 | 'COMPLETED' |
| '99' | キャンセル | 'CANCELLED' |
| その他 | 不明 | 'UNKNOWN' |

---

## バッチコミット設計

### 基本方針

大量データの一括 INSERT はUNDO/REDOログの肥大化リスクがあるため、約1万件（`p_batch_size = 10000`）単位でCOMMITを行うバッチ処理を採用する。

### 処理パターン

Oracle 12c 互換の `BULK COLLECT ... LIMIT` + `FOR LOOP` パターンを使用する。  
FORALL を使用しない理由: ループ内で `safe_to_date_yyyymmdd` 等の関数呼び出しが必要なため、DML のみのバルク実行である FORALL とは組み合わせられない。

```
1. DELETE FROM tgt_schema.テーブル（全件削除）
2. COMMIT（削除を確定）
3. ループ開始:
     BULK COLLECT INTO コレクション LIMIT p_batch_size
     EXIT WHEN コレクション.COUNT = 0
     FOR i IN 1..コレクション.COUNT LOOP
       INSERT INTO tgt_schema.テーブル VALUES コレクション(i);
     END LOOP;
     COMMIT（バッチ分を確定）
     batch_no := batch_no + 1
     log_step を UPDATE（tgt_count / batch_no を進捗更新）
4. ループ終了 → SUCCESS ログ記録
```

### フロー図

```
DELETE → COMMIT（削除確定）
  │
  └─ LOOP
       BULK COLLECT LIMIT 10000
       FOR LOOP INSERT
       COMMIT（バッチ確定）         ← batch_no = 1, 2, 3 ...
       log_step UPDATE（進捗）
     END LOOP
  │
  └─ log_step('SUCCESS')
```

### 冪等性（再実行時の安全性）

- 冒頭の `DELETE + COMMIT` により、再実行前に対象テーブルを全件クリアする
- その後バッチループで再挿入するため、何度実行しても結果が一定になる
- 前回の実行で途中バッチまで確定していた場合も、再実行の `DELETE + COMMIT` で全消去される

### 失敗時の状態

| 失敗タイミング | データ状態 | 対処 |
|--------------|----------|------|
| DELETE後・バッチ開始前 | TGTテーブルが空 | 再実行でバッチ挿入が行われる |
| バッチ n 処理中 | バッチ 1〜n-1 は確定済み、バッチ n はROLLBACK | 再実行で全DELETE→全再挿入 |
| 全バッチ完了後 | 全件確定済み | 通常は発生しない |

### batch_no の意味と追跡方法

- `batch_no` は1始まりの連番で、各バッチCOMMIT後にインクリメントする
- `migration_step_log.batch_no` には**最後に成功したバッチ番号**が記録される
- `migration_error_log.batch_no` には**エラーが発生したバッチ番号**が記録される
- 例: `step_log.batch_no = 5` の場合、5バッチ目（最大5万件）まで確定したことを意味する

```sql
-- 進捗確認: 何件目まで確定したか
SELECT step_name,
       tgt_count,
       batch_no,
       tgt_count / NULLIF(src_count, 0) * 100 AS progress_pct
FROM log_schema.migration_step_log
WHERE run_id = :run_id;
```

---

## 不正データ防御

### 日付文字列の検証方針

旧スキーマの `create_date` / `order_date` は VARCHAR2(8) で YYYYMMDD 形式を想定しているが、不正値が混入する可能性がある。`REGEXP_LIKE` を使って8桁数字であることを検証してから `TO_DATE` を呼び出す。

```sql
-- REGEXP_LIKE による検証付き日付変換
CASE
    WHEN col IS NOT NULL
         AND REGEXP_LIKE(col, '^[0-9]{8}$')
    THEN TO_DATE(col, 'YYYYMMDD')
    ELSE NULL
END
```

**従来の `LENGTH(col) = 8` チェックとの違い:**

| チェック方法 | 防げる不正値 | 防げない不正値 |
|-------------|------------|--------------|
| `LENGTH(col) = 8` | NULL・短い文字列 | 非数字（'ABCD1234'）、全角数字 |
| `REGEXP_LIKE(col, '^[0-9]{8}$')` | NULL・短い文字列・非数字・全角 | 意味的に無効な日付（'20001399'等）|

> **注記:** 意味的に無効な日付（月13・日32等）は `TO_DATE` の例外として EXCEPTION ブロックで捕捉されるか、または事前に NULL に変換する方針とする。本サンプルでは `REGEXP_LIKE` で形式チェックした後、`TO_DATE` が失敗した場合は NULL を返す設計（EXCEPTION を使わず CASE でラップ）とする。

### 検証失敗時の扱い

検証失敗（REGEXP_LIKE が FALSE）の場合は **NULL に変換**する（処理を中断しない）。  
これにより、1件の不正データで全体移行が停止するリスクを回避する。

| 状況 | 扱い |
|------|------|
| `create_date` が NULL | NULL のまま |
| `create_date` が8桁数字以外 | NULL に変換（警告なし） |
| `create_date` が有効な8桁数字 | `TO_DATE` で変換 |

### cust_id の TO_NUMBER 失敗リスクと対処

`cust_id` は VARCHAR2(10) で数値文字列を想定しているが、数字以外が混入した場合 `TO_NUMBER` が `ORA-01722: invalid number` を発生させる。

**対処方針:**
- `REGEXP_LIKE(cust_id, '^[0-9]+$')` で事前検証する方法もあるが、本サンプルでは `TO_NUMBER` の変換失敗は EXCEPTION ブロックで捕捉して `log_error` に記録し、処理を中断（RAISE）する
- 変換失敗時には `migration_error_log.target_record_id` にエラーレコードの `cust_id` が記録される
- 実運用では移行前にデータクレンジング（数値以外の `cust_id` を持つレコードを特定・修正）を推奨する

```sql
-- 事前データ確認クエリ（移行前チェック用）
SELECT cust_id FROM src_schema.customers
WHERE NOT REGEXP_LIKE(cust_id, '^[0-9]+$');
```

---

## PL/SQL 移行パッケージ構成

### パッケージ: pkg_migration

**パッケージ仕様（SPEC）**

```sql
CREATE OR REPLACE PACKAGE log_schema.pkg_migration AS

    -- メインエントリポイント
    -- p_batch_size: 1バッチあたりの最大処理件数（デフォルト10000）
    PROCEDURE migrate_all(
        p_run_name   IN VARCHAR2,
        p_batch_size IN NUMBER DEFAULT 10000
    );

    -- 個別移行プロシージャ
    PROCEDURE migrate_customer(
        p_run_id     IN NUMBER,
        p_batch_size IN NUMBER DEFAULT 10000
    );
    PROCEDURE migrate_order(
        p_run_id     IN NUMBER,
        p_batch_size IN NUMBER DEFAULT 10000
    );

    -- ログ記録ユーティリティ
    FUNCTION  log_run_start(p_run_name IN VARCHAR2) RETURN NUMBER;
    PROCEDURE log_run_end(
        p_run_id       IN NUMBER,
        p_status       IN VARCHAR2,
        p_src_count    IN NUMBER DEFAULT 0,
        p_tgt_count    IN NUMBER DEFAULT 0,
        p_error_msg    IN VARCHAR2 DEFAULT NULL
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

END pkg_migration;
/
```

### プロシージャ別設計

#### migrate_all（全体制御）

`p_batch_size` パラメータを受け取り、各移行プロシージャに伝搬する。デフォルト値は 10000。

```
1. log_run_start → run_id 取得
2. migrate_customer(run_id, p_batch_size) を呼び出し
3. migrate_order(run_id, p_batch_size) を呼び出し
4. src_count / tgt_count を集計
5. log_run_end(run_id, 'SUCCESS') で終了記録
6. （各バッチで既にCOMMIT済みのため、ここではCOMMIT不要）
EXCEPTION WHEN OTHERS:
   ROLLBACK（失敗バッチ分をロールバック）
   src_count / tgt_count をターゲットテーブルから再カウント（コミット済み件数）
   log_error(run_id, 'MIGRATE_ALL', SQLCODE, SQLERRM, BACKTRACE)
   log_run_end(run_id, 'FAILED', src_count, tgt_count, error_msg)
   RAISE
```

> **注記:** データの COMMIT はバッチ単位で行うため、`migrate_all` 末尾での一括 COMMIT は行わない。  
> 失敗時の ROLLBACK は、最後に失敗したバッチ分のみに作用する。

#### migrate_customer（顧客移行）

```
1. log_step(run_id, 'MIGRATE_CUSTOMER', 'RUNNING')
2. SRC_SCHEMA.CUSTOMERS の件数取得（src_count）
3. TGT_SCHEMA.ORDERS を DELETE（FK制約のため子を先に削除）
4. TGT_SCHEMA.CUSTOMERS を DELETE（再実行対応）
5. COMMIT（削除を確定）
6. OPEN カーソル FOR SELECT ... FROM SRC_SCHEMA.CUSTOMERS
7. ループ:
     FETCH カーソル BULK COLLECT INTO コレクション LIMIT p_batch_size
     EXIT WHEN コレクション.COUNT = 0
     FOR i IN 1..コレクション.COUNT LOOP
       INSERT INTO TGT_SCHEMA.CUSTOMERS VALUES コレクション(i)
     END LOOP
     tgt_count := tgt_count + コレクション.COUNT
     batch_no  := batch_no + 1
     COMMIT（バッチ確定）
     log_step UPDATE（tgt_count, batch_no を進捗更新）
8. log_step(run_id, 'MIGRATE_CUSTOMER', 'SUCCESS', src_count, tgt_count, batch_no)
EXCEPTION WHEN OTHERS:
   log_error(run_id, 'MIGRATE_CUSTOMER', SQLCODE, SQLERRM, BACKTRACE,
             target_table=>'TGT_SCHEMA.CUSTOMERS', batch_no=>batch_no)
   log_step(run_id, 'MIGRATE_CUSTOMER', 'FAILED')
   RAISE
```

#### migrate_order（注文移行）

```
1. log_step(run_id, 'MIGRATE_ORDER', 'RUNNING')
2. SRC_SCHEMA.ORDERS の件数取得（src_count）
3. TGT_SCHEMA.ORDERS を DELETE（再実行対応）
4. COMMIT（削除を確定）
5. OPEN カーソル FOR SELECT ... FROM SRC_SCHEMA.ORDERS
6. ループ:
     FETCH カーソル BULK COLLECT INTO コレクション LIMIT p_batch_size
     EXIT WHEN コレクション.COUNT = 0
     FOR i IN 1..コレクション.COUNT LOOP
       INSERT INTO TGT_SCHEMA.ORDERS VALUES コレクション(i)
     END LOOP
     tgt_count := tgt_count + コレクション.COUNT
     batch_no  := batch_no + 1
     COMMIT（バッチ確定）
     log_step UPDATE（tgt_count, batch_no を進捗更新）
7. log_step(run_id, 'MIGRATE_ORDER', 'SUCCESS', src_count, tgt_count, batch_no)
EXCEPTION WHEN OTHERS:
   log_error(run_id, 'MIGRATE_ORDER', SQLCODE, SQLERRM, BACKTRACE,
             target_table=>'TGT_SCHEMA.ORDERS', batch_no=>batch_no)
   log_step(run_id, 'MIGRATE_ORDER', 'FAILED')
   RAISE
```

---

## 処理フロー

```
PowerShell: run-migration.ps1
│
├─ Oracle コンテナ起動確認
├─ SQL*Plus 呼び出し
│   └─ EXECUTE log_schema.pkg_migration.migrate_all('RUN_001', 10000);
│       │
│       ├─ log_run_start → migration_run_log に INSERT（status='RUNNING'）
│       │
│       ├─ migrate_customer（p_batch_size=10000）
│       │   ├─ migration_step_log INSERT（status='RUNNING'）
│       │   ├─ TGT orders DELETE（FK先行削除）
│       │   ├─ TGT customers DELETE → COMMIT（削除確定）
│       │   ├─ LOOP（バッチ処理）
│       │   │   ├─ BULK COLLECT LIMIT 10000
│       │   │   ├─ FOR LOOP INSERT INTO TGT customers
│       │   │   ├─ COMMIT（バッチ確定）← batch_no=1,2,...
│       │   │   └─ migration_step_log UPDATE（tgt_count / batch_no 進捗更新）
│       │   └─ migration_step_log UPDATE（status='SUCCESS', counts, batch_no）
│       │
│       ├─ migrate_order（p_batch_size=10000）
│       │   ├─ migration_step_log INSERT（status='RUNNING'）
│       │   ├─ TGT orders DELETE → COMMIT（削除確定）
│       │   ├─ LOOP（バッチ処理）
│       │   │   ├─ BULK COLLECT LIMIT 10000
│       │   │   ├─ FOR LOOP INSERT INTO TGT orders
│       │   │   ├─ COMMIT（バッチ確定）← batch_no=1,2,...
│       │   │   └─ migration_step_log UPDATE（tgt_count / batch_no 進捗更新）
│       │   └─ migration_step_log UPDATE（status='SUCCESS', counts, batch_no）
│       │
│       └─ log_run_end（status='SUCCESS'）
│           ※ データCOMMITはバッチ単位で完了済み
│
├─ 終了コード確認
└─ ログファイル保存（logs/migration_YYYYMMDD_HHMMSS.log）

エラー時:
       ├─ ROLLBACK（失敗バッチ分のみ）
       ├─ src_count / tgt_count をターゲットテーブルから再カウント（コミット済み件数）
       ├─ migration_error_log INSERT（SQLERRM + BACKTRACE + target_table + batch_no）
       ├─ log_run_end（status='FAILED', src_count, tgt_count）
       └─ PowerShell に終了コード 1 を返す
```

---

## Oracle 12c 互換を意識した設計判断

| 設計項目 | 採用方針 | 理由 |
|---------|---------|------|
| 自動採番 | SEQUENCE + BEFORE INSERT トリガー | IDENTITY 列は 12c 以前の本番では使えない可能性 |
| ページネーション | 不使用（全件処理） | FETCH FIRST/OFFSET の互換性問題を回避 |
| 日付変換 | TO_DATE(str, 'YYYYMMDD') | 標準的な Oracle 関数、バージョン非依存 |
| エラー情報取得 | DBMS_UTILITY.FORMAT_ERROR_BACKTRACE | 10g R2 以降で利用可能 |
| カーソル処理 | BULK COLLECT + FOR LOOP（バッチ処理） | 行単位ループは性能劣化リスク。FORALL では safe_to_date_yyyymmdd 等の PL/SQL 関数を呼び出せないため FOR LOOP を採用。INSERT...SELECT は大量データ時のUNDO肥大化リスクがあるため採用しない |
| バッチサイズ | p_batch_size=10000（デフォルト） | 1万件単位でCOMMITし、UNDO/REDOログの肥大化を防ぐ |
| 日付検証 | REGEXP_LIKE(col, '^[0-9]{8}$') | LENGTH チェックのみでは非数字を防げない。12c から利用可能（実際は10g以降）|
| コード変換 | CASE WHEN 式 | 標準 SQL、バージョン非依存 |
| JSON 不使用 | ログ記録は VARCHAR2 | JSON_OBJECT 等は 12c R2 以降のみ |
