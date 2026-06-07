# ログ設計・エラーハンドリング設計書

## 概要

PL/SQL 移行処理の実行状況・件数・エラー原因をすべて DB ログテーブルに記録する。  
PowerShell は外部ファイルへのログ出力のみ担当し、移行ロジック・ログ登録は PL/SQL が行う。

---

## ログテーブル定義

### migration_run_log（実行単位ログ）

移行処理の1回の実行を記録する。

```sql
-- SEQUENCE
CREATE SEQUENCE log_schema.seq_migration_run_log
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- TABLE
CREATE TABLE log_schema.migration_run_log (
    run_id          NUMBER(10)      NOT NULL,    -- 実行ID（SEQUENCEから採番）
    run_name        VARCHAR2(100)   NOT NULL,    -- 実行名（例: 'RUN_001', '2024-01-01_BATCH'）
    status          VARCHAR2(20)    NOT NULL,    -- RUNNING / SUCCESS / FAILED
    started_at      DATE            NOT NULL,    -- 開始日時
    finished_at     DATE,                        -- 終了日時（完了時に更新）
    total_src_count NUMBER(10)      DEFAULT 0,   -- 旧スキーマ合計件数
    total_tgt_count NUMBER(10)      DEFAULT 0,   -- 新スキーマ合計件数
    error_message   VARCHAR2(4000),              -- エラーメッセージ（失敗時）
    CONSTRAINT pk_migration_run_log PRIMARY KEY (run_id),
    CONSTRAINT chk_run_status CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED'))
);

-- TRIGGER（採番）
CREATE OR REPLACE TRIGGER log_schema.trg_migration_run_log_bi
BEFORE INSERT ON log_schema.migration_run_log
FOR EACH ROW
BEGIN
    IF :NEW.run_id IS NULL THEN
        SELECT log_schema.seq_migration_run_log.NEXTVAL
        INTO :NEW.run_id FROM DUAL;
    END IF;
END;
/
```

### migration_step_log（ステップ単位ログ）

移行処理内の各ステップ（テーブル単位）の実行を記録する。

```sql
-- SEQUENCE
CREATE SEQUENCE log_schema.seq_migration_step_log
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- TABLE
CREATE TABLE log_schema.migration_step_log (
    step_log_id     NUMBER(10)      NOT NULL,    -- ステップログID
    run_id          NUMBER(10)      NOT NULL,    -- 実行ID（FK）
    step_name       VARCHAR2(100)   NOT NULL,    -- ステップ名（例: 'MIGRATE_CUSTOMER'）
    status          VARCHAR2(20)    NOT NULL,    -- RUNNING / SUCCESS / FAILED / SKIPPED
    src_count       NUMBER(10)      DEFAULT 0,   -- 旧スキーマの対象件数
    tgt_count       NUMBER(10)      DEFAULT 0,   -- 新スキーマへの挿入件数
    started_at      DATE            NOT NULL,    -- ステップ開始日時
    finished_at     DATE,                        -- ステップ終了日時
    batch_no        NUMBER          DEFAULT 0,   -- 最後に確定したバッチ番号
    CONSTRAINT pk_migration_step_log PRIMARY KEY (step_log_id),
    CONSTRAINT fk_step_log_run FOREIGN KEY (run_id) REFERENCES log_schema.migration_run_log(run_id),
    CONSTRAINT chk_step_status CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED', 'SKIPPED'))
);

-- TRIGGER（採番）
CREATE OR REPLACE TRIGGER log_schema.trg_migration_step_log_bi
BEFORE INSERT ON log_schema.migration_step_log
FOR EACH ROW
BEGIN
    IF :NEW.step_log_id IS NULL THEN
        SELECT log_schema.seq_migration_step_log.NEXTVAL
        INTO :NEW.step_log_id FROM DUAL;
    END IF;
END;
/
```

### migration_error_log（エラー詳細ログ）

例外発生時のエラー詳細を記録する。SQLERRM と BACKTRACE の両方を保存。

```sql
-- SEQUENCE
CREATE SEQUENCE log_schema.seq_migration_error_log
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- TABLE
CREATE TABLE log_schema.migration_error_log (
    error_id         NUMBER(10)      NOT NULL,   -- エラーID
    run_id           NUMBER(10)      NOT NULL,   -- 実行ID（FK）
    step_name        VARCHAR2(100),              -- どのステップで発生したか
    error_code       NUMBER,                     -- SQLCODE
    error_message    VARCHAR2(4000),             -- SQLERRM
    error_backtrace  VARCHAR2(4000),             -- DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
    occurred_at      DATE            NOT NULL,   -- 発生日時
    target_record_id VARCHAR2(100),              -- エラーが発生したレコードのID（判明する場合）
    target_table     VARCHAR2(100),              -- エラーが発生したテーブル名（例: 'TGT_SCHEMA.CUSTOMERS'）
    batch_no         NUMBER,                     -- エラーが発生したバッチ番号
    error_context    VARCHAR2(4000),             -- 追加コンテキスト（バッチ範囲・処理フェーズ等）
    CONSTRAINT pk_migration_error_log PRIMARY KEY (error_id),
    CONSTRAINT fk_error_log_run FOREIGN KEY (run_id) REFERENCES log_schema.migration_run_log(run_id)
);

-- TRIGGER（採番）
CREATE OR REPLACE TRIGGER log_schema.trg_migration_error_log_bi
BEFORE INSERT ON log_schema.migration_error_log
FOR EACH ROW
BEGIN
    IF :NEW.error_id IS NULL THEN
        SELECT log_schema.seq_migration_error_log.NEXTVAL
        INTO :NEW.error_id FROM DUAL;
    END IF;
END;
/
```

---

## 例外処理方針

### 基本方針

```
移行処理中に例外が発生した場合:
1. EXCEPTION ブロックで SQLCODE / SQLERRM / BACKTRACE を取得
2. migration_error_log に記録（AUTONOMOUS TRANSACTION で独立コミット）
3. 上位プロシージャに RAISE で例外を再送出
4. 最上位（migrate_all）でログ記録後 ROLLBACK
5. PowerShell に非ゼロの終了コードを返す
```

### AUTONOMOUS TRANSACTION の使用

ログ記録は `PRAGMA AUTONOMOUS_TRANSACTION` を持つ専用プロシージャで行う。  
これにより、移行処理が ROLLBACK されてもログは残る。

```sql
PROCEDURE log_error(
    p_run_id        IN NUMBER,
    p_step_name     IN VARCHAR2,
    p_error_code    IN NUMBER,
    p_error_msg     IN VARCHAR2,
    p_backtrace     IN VARCHAR2,
    p_record_id     IN VARCHAR2 DEFAULT NULL,
    p_target_table  IN VARCHAR2 DEFAULT NULL,
    p_batch_no      IN NUMBER   DEFAULT NULL,
    p_error_context IN VARCHAR2 DEFAULT NULL
) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    INSERT INTO log_schema.migration_error_log (
        run_id, step_name, error_code, error_message,
        error_backtrace, occurred_at, target_record_id,
        target_table, batch_no, error_context
    ) VALUES (
        p_run_id, p_step_name, p_error_code, p_error_msg,
        p_backtrace, SYSDATE, p_record_id,
        p_target_table, p_batch_no, SUBSTR(p_error_context, 1, 4000)
    );
    COMMIT;
END log_error;
```

> **注意:** `log_run_start` / `log_run_end` / `log_step` も AUTONOMOUS TRANSACTION を使用し、  
> メイン処理の ROLLBACK でログが消えないようにする。

### エラー取得の書き方

バッチ処理を伴う場合は、`p_target_table` と `p_batch_no`、`p_error_context` も渡す。

```sql
EXCEPTION
    WHEN OTHERS THEN
        v_error_code := SQLCODE;
        v_error_msg  := SUBSTR(SQLERRM, 1, 4000);
        v_backtrace  := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
        
        log_schema.pkg_migration.log_error(
            p_run_id        => p_run_id,
            p_step_name     => 'MIGRATE_CUSTOMER',
            p_error_code    => v_error_code,
            p_error_msg     => v_error_msg,
            p_backtrace     => v_backtrace,
            p_target_table  => 'TGT_SCHEMA.CUSTOMERS',
            p_batch_no      => v_batch_no,
            p_error_context => 'batch_no=' || v_batch_no
                               || ', tgt_count_so_far=' || v_tgt_count
        );
        RAISE;
```

### WHEN OTHERS 使用ルール

- `WHEN OTHERS` の後には必ず `RAISE`（または `RAISE_APPLICATION_ERROR`）を置く
- エラーを握りつぶさない
- ログ記録後に例外を上位へ伝播させる

### エラー継続 vs 中断方針

| ケース | 方針 |
|--------|------|
| 特定レコードの変換エラー | 本サンプルでは中断（RAISE）。大量データの場合は CONTINUE 方式を検討 |
| FK 違反 | 処理順序（customer → order）を守り発生させない |
| 重複キー | DELETE + INSERT の冪等設計で回避 |
| コンテナ接続不可 | PowerShell が事前チェックして起動しない |

---

## COMMIT / ROLLBACK タイミング（バッチ版）

```
migrate_all
├─ ← 処理開始
│
├─ migrate_customer
│   ├─ DELETE tgt orders（FK先行）
│   ├─ DELETE tgt customers
│   ├─ COMMIT ←── 削除を確定
│   ├─ LOOP
│   │   ├─ BULK COLLECT LIMIT 10000
│   │   ├─ FORALL INSERT
│   │   ├─ COMMIT ←── バッチ1確定（batch_no=1）
│   │   ├─ FORALL INSERT
│   │   ├─ COMMIT ←── バッチ2確定（batch_no=2）
│   │   └─ ...（繰り返し）
│   └─ 完了 → log_step('SUCCESS')
│
├─ migrate_order（同様のバッチCOMMIT構造）
│
├─ 正常終了 → log_run_end（AUTONOMOUS TRANSACTION）
│             ※ データCOMMITはバッチ単位で完了済み。ここでの追加COMMITは不要
└─ 異常終了 → log_error / log_run_end（AUTONOMOUS TRANSACTION）
              → ROLLBACK（失敗したバッチ分のみロールバック。確定済みバッチは残る）
```

**ポイント:**
- DELETE直後に COMMIT を行い、削除を確定させる（再実行の冪等性を保証）
- データの COMMIT はバッチ単位（約1万件ごと）に行う（旧設計の一括 COMMIT から変更）
- 失敗時の ROLLBACK は、最後に失敗したバッチ分のみに作用する
- ログ記録（run_log / step_log / error_log）は AUTONOMOUS TRANSACTION で独立してコミットする
- これにより「処理は失敗したがログは残る」状態を実現する

**旧設計との比較:**

| 項目 | 旧設計（一括COMMIT） | 新設計（バッチCOMMIT） |
|------|-------------------|---------------------|
| COMMITタイミング | migrate_all 末尾で1回 | DELETE後+各バッチ後 |
| ROLLBACKの範囲 | 全データを元に戻す | 失敗バッチ分のみ |
| UNDO使用量 | 全件分が蓄積される | 最大1バッチ分のみ蓄積 |
| 中断後の再開 | 全件再実行 | 全件DELETEして再実行（冪等設計） |

---

## 再実行方針

### 冪等性の担保

再実行時にエラーが出ないよう、`DELETE + COMMIT → バッチINSERT + COMMIT` 方式を採用する。

```sql
-- 再実行時も安全な設計（バッチ版）
-- 1. 全件削除して確定
DELETE FROM tgt_schema.orders;    -- FK先行
DELETE FROM tgt_schema.customers;
COMMIT;                           -- 削除を確定

-- 2. バッチ単位で挿入・確定（ループ内）
FORALL i IN l_customers.FIRST..l_customers.LAST
    INSERT INTO tgt_schema.customers VALUES l_customers(i);
COMMIT;    -- バッチ確定
```

> `MERGE` は 12c でも使用可能だが、`DELETE + INSERT` の方がシンプルで追跡しやすいため本サンプルでは採用しない。

**バッチCOMMIT後の再実行挙動:**

前回実行でバッチ 3 まで確定して失敗した場合でも、再実行時の冒頭 `DELETE + COMMIT` で全件が削除される。そのため、途中状態を引き継がず常に最初からバッチ挿入が行われる。

### 再実行前の状態確認

```sql
-- 前回実行ステータスの確認
SELECT run_id, run_name, status, started_at, finished_at, error_message
FROM log_schema.migration_run_log
ORDER BY run_id DESC;

-- エラー詳細の確認
SELECT *
FROM log_schema.migration_error_log
WHERE run_id = (SELECT MAX(run_id) FROM log_schema.migration_run_log)
ORDER BY occurred_at;
```

### 重複実行の防止

同名の実行名（run_name）が `RUNNING` 状態で存在する場合は処理を開始しない。

```sql
-- migrate_all の冒頭でチェック
SELECT COUNT(*) INTO v_running_count
FROM log_schema.migration_run_log
WHERE run_name = p_run_name AND status = 'RUNNING';

IF v_running_count > 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 
        'Migration already running for run_name: ' || p_run_name);
END IF;
```

### 再実行手順

1. `migration_run_log` で前回実行のステータスを確認する
2. FAILED の場合は原因を `migration_error_log` で調査する
3. 原因を修正後、同じ run_name または新しい run_name で再実行する
4. 実行後に `migration_step_log` で件数が想定通りか確認する

---

## バッチ処理とログの関係

### step_log の更新タイミング

バッチCOMMIT後に `log_step` を呼び出して `tgt_count` と `batch_no` を進捗更新する。  
これにより、処理途中でも「何件目まで確定したか」をリアルタイムで確認できる。

```
バッチ1 FORALL INSERT → COMMIT → log_step UPDATE (tgt_count=10000, batch_no=1)
バッチ2 FORALL INSERT → COMMIT → log_step UPDATE (tgt_count=20000, batch_no=2)
バッチ3 FORALL INSERT → COMMIT → log_step UPDATE (tgt_count=30000, batch_no=3)
...
完了     → log_step UPDATE (status='SUCCESS', tgt_count=35000, batch_no=4)
```

> `step_log.batch_no` には**最後に成功したバッチ番号**が記録される。  
> 例: `batch_no = 5` の場合、5バッチ目（最大5万件）まで確定済みであることを意味する。

### error_log へのバッチ情報記録

エラー発生時は `log_error` に `target_table`・`batch_no`・`error_context` を記録する。

```sql
-- エラー発生時の記録例（migrate_customer内）
log_error(
    p_run_id        => p_run_id,
    p_step_name     => 'MIGRATE_CUSTOMER',
    p_error_code    => v_error_code,
    p_error_msg     => v_error_msg,
    p_backtrace     => v_backtrace,
    p_target_table  => 'TGT_SCHEMA.CUSTOMERS',
    p_batch_no      => v_batch_no,
    p_error_context => 'batch_no=' || v_batch_no
                       || ', tgt_count_so_far=' || v_tgt_count
);
```

### 運用での読み方

| ログテーブル | 確認内容 | 判断できること |
|-------------|---------|--------------|
| `step_log.batch_no` | 最後に成功したバッチ番号 | どこまで確定したか |
| `step_log.tgt_count` | 確定済み挿入件数 | 何件まで処理が進んだか |
| `error_log.batch_no` | エラーが発生したバッチ番号 | どのバッチで失敗したか |
| `error_log.target_table` | エラーが発生したテーブル | どのテーブルの処理で失敗したか |
| `error_log.error_context` | バッチ範囲・処理フェーズ | エラーの前後状況 |

```sql
-- 最後に成功したバッチと件数を確認する
SELECT step_name, status, src_count, tgt_count, batch_no, started_at, finished_at
FROM log_schema.migration_step_log
WHERE run_id = :run_id
ORDER BY step_log_id;

-- エラーが発生したバッチを特定する
SELECT step_name, error_code, error_message, target_table, batch_no, error_context
FROM log_schema.migration_error_log
WHERE run_id = :run_id
ORDER BY occurred_at;
```

---

## ログ確認クエリ（運用用）

### 最新実行サマリ

```sql
SELECT
    r.run_id,
    r.run_name,
    r.status,
    r.started_at,
    r.finished_at,
    r.finished_at - r.started_at AS elapsed_days,
    r.total_src_count,
    r.total_tgt_count,
    r.error_message
FROM log_schema.migration_run_log r
ORDER BY r.run_id DESC;
```

### ステップ別件数確認

```sql
SELECT
    s.run_id,
    s.step_name,
    s.status,
    s.src_count,
    s.tgt_count,
    s.src_count - s.tgt_count AS diff,
    s.batch_no,
    s.started_at,
    s.finished_at
FROM log_schema.migration_step_log s
WHERE s.run_id = :run_id
ORDER BY s.step_log_id;
```

### エラー詳細確認

```sql
SELECT
    e.error_id,
    e.step_name,
    e.error_code,
    e.error_message,
    e.error_backtrace,
    e.occurred_at,
    e.target_record_id,
    e.target_table,
    e.batch_no,
    e.error_context
FROM log_schema.migration_error_log e
WHERE e.run_id = :run_id
ORDER BY e.occurred_at;
```

---

## PowerShell との役割分担

| 処理 | 担当 |
|------|------|
| Oracle コンテナ起動確認 | PowerShell |
| SQL*Plus 呼び出し | PowerShell |
| 外部ログファイル出力 | PowerShell |
| 終了コード判定 | PowerShell |
| 移行ロジック（DELETE/INSERT） | **PL/SQL（必須）** |
| 件数カウント | **PL/SQL（必須）** |
| 例外処理・エラー記録 | **PL/SQL（必須）** |
| DBログテーブルへの書き込み | **PL/SQL（必須）** |
| COMMIT / ROLLBACK | **PL/SQL（必須）** |
