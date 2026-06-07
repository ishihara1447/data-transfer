# Oracle 12c 互換性ポリシー

## 方針概要

### なぜ Oracle 12c 互換を意識するか

本番環境は Oracle 12c 相当のレガシー環境である。ローカル検証環境として Oracle 21c XE を使用するが、ローカルで動作した SQL/PL/SQL が本番では実行できないリスクを排除するため、以下のポリシーを定める。

本ポリシーを遵守することで：
- ローカルでの動作確認結果が本番環境でも再現できる
- 本番移行前に「使えない機能を誤って使っていた」という手戻りを防ぐ
- Oracle バージョンに依存しないシンプルなコードベースを維持できる

---

## 使用コンテナと本番環境の差異

| 項目 | ローカル（Docker） | 本番（想定） |
|------|-------------------|-------------|
| バージョン | Oracle 21c XE (21.3.0) | Oracle 12c (12.1 または 12.2 相当) |
| エディション | Express Edition | Enterprise / Standard |
| 接続制限 | XE制限あり | なし |
| PDB/CDB | CDB構成 | 12.1以前はCDB非対応 / 12.2はCDB対応 |
| 最大DB容量 | 12GB（XE制限） | 無制限 |
| 最大接続数 | 3接続（XE制限） | 無制限 |

> **注意:** 本番が Oracle 12.1 か 12.2 かによって利用可能な機能が異なる。  
> 12.1 を想定した最低ラインのポリシーとする。

---

## 禁止する構文・機能（12c 非互換・要注意）

### 絶対禁止（12c では使用不可または動作が保証されない）

| 構文・機能 | 問題となるバージョン | 代替方法 |
|-----------|---------------------|---------|
| `FETCH FIRST n ROWS ONLY` / `OFFSET n ROWS` | 12c R1 以降で追加（12.1対応） → ただし本番バージョン次第 | `ROW_NUMBER()` + `WHERE rn <= n` |
| `JSON_TABLE` / `JSON_OBJECT` / `JSON_ARRAY` | 12c R2（12.2）以降 | VARCHAR2 + 手動パース |
| `JSON_EXISTS` / `JSON_VALUE` | 12c R2（12.2）以降 | 同上 |
| `LISTAGG ... ON OVERFLOW TRUNCATE` | 12c R2 未満では非対応 | `LISTAGG` のみ使用（オーバーフロー考慮は件数制限で対応）|
| `APPROX_PERCENTILE` / `APPROX_MEDIAN` | 12c R2 以降 | 通常の PERCENTILE_CONT / MEDIAN |
| `MATCH_RECOGNIZE`（複雑な使用） | 12c R1 で追加されたが複雑な構文は注意 | 使用しない |
| `DBMS_SQL.RETURN_RESULT`（暗黙的結果セット） | 12c R1 以降 | OUT パラメータで代替 |
| `WITH FUNCTION`（インラインファンクション） | 12c R1 以降 → 本番バージョン次第 | 通常のパッケージ関数 |
| `BEQUEATH CURRENT_USER` | 12c R1 以降 | 使用しない |
| `ACCESSIBLE BY` 句 | 12c R1 以降 → 本番バージョン次第 | 使用しない |
| `IDENTITY` 列（GENERATED ALWAYS AS IDENTITY） | 12c R1 以降 → 本番DBで利用可否不明 | SEQUENCE + BEFORE INSERT トリガー |

### 注意が必要（バージョン依存・環境依存）

| 構文・機能 | 注意点 |
|-----------|--------|
| `VARCHAR2(n CHAR)` | 文字セット設定に依存。本番が AL32UTF8 以外の場合は注意 |
| `NVARCHAR2` | 本番の文字セットに依存 |
| `MAX_STRING_SIZE=EXTENDED` | デフォルト STANDARD の場合 VARCHAR2 は 4000 バイト制限。EXTENDED を前提にしない |
| `LATERAL` 結合 | 12c R1 以降で追加。シンプルな使用は可だが複雑な場合は避ける |
| `CROSS APPLY` / `OUTER APPLY` | 12c R1 以降 |
| `FIRST_VALUE` / `LAST_VALUE` の `IGNORE NULLS` | 動作確認が必要 |
| `LISTAGG` の 4000 文字超過 | STANDARD モードでエラーになる可能性 |

---

## 推奨代替構文

### ページネーション

```sql
-- 禁止: FETCH FIRST（本番バージョン依存）
SELECT * FROM customers FETCH FIRST 10 ROWS ONLY;

-- 推奨: ROW_NUMBER() + サブクエリ（12c 以前でも動作）
SELECT * FROM (
    SELECT c.*, ROW_NUMBER() OVER (ORDER BY customer_id) AS rn
    FROM customers c
)
WHERE rn BETWEEN 1 AND 10;
```

### 自動採番（IDENTITY 列の代替）

```sql
-- 禁止: IDENTITY 列（本番バージョン依存）
-- CREATE TABLE t (id NUMBER GENERATED ALWAYS AS IDENTITY, ...);

-- 推奨: SEQUENCE + BEFORE INSERT トリガー
CREATE SEQUENCE seq_customers START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE OR REPLACE TRIGGER trg_customers_bi
BEFORE INSERT ON customers
FOR EACH ROW
BEGIN
    IF :NEW.customer_id IS NULL THEN
        SELECT seq_customers.NEXTVAL INTO :NEW.customer_id FROM DUAL;
    END IF;
END;
/
```

### トップN取得（ROWNUM）

```sql
-- 推奨: ROWNUM（全バージョン対応）
SELECT * FROM customers WHERE ROWNUM <= 10;
```

### 文字列集約

```sql
-- 推奨: LISTAGG（12c R1 以降は使用可。ON OVERFLOW TRUNCATE は使わない）
SELECT LISTAGG(cust_name, ',') WITHIN GROUP (ORDER BY cust_name)
FROM customers;
```

---

## SQL*Plus 互換性要件

本プロジェクトの全 SQL ファイルは SQL*Plus で実行できることを必須とする。

### SQLcl 専用機能（使用禁止）

| 禁止機能 | 説明 |
|---------|------|
| `SET LINESIZE AUTO` | SQLcl 独自。SQL*Plus では `SET LINESIZE n`（数値指定必須）|
| `SPOOL filename.csv CSV` | SQLcl の CSV 出力。SQL*Plus では `SPOOL` + フォーマット手動設定 |
| `FORMAT csv` / `FORMAT json` | SQLcl 独自 |
| `SCRIPT` / `JS` / `JAVASCRIPT` | SQLcl の JavaScript 実行 |
| `REPEAT` コマンド | SQLcl 独自 |
| `INFORMATION` / `INFO` コマンド（拡張版）| SQLcl 独自 |
| `DDL` コマンド | SQLcl 独自 |
| `LOAD` コマンド | SQLcl 独自 |
| Liquibase 統合コマンド | SQLcl 独自 |

### SQL*Plus 推奨設定

```sql
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 100
WHENEVER SQLERROR EXIT SQL.SQLCODE
```

---

## PL/SQL 互換性ポリシー

### 使用可能な DBMS パッケージ（12c 以前から存在）

- `DBMS_OUTPUT`
- `DBMS_UTILITY` （`FORMAT_ERROR_BACKTRACE` は 10g R2 以降）
- `DBMS_APPLICATION_INFO`
- `DBMS_LOB`
- `UTL_FILE`
- `DBMS_METADATA`
- `DBMS_STATS`

### 使用注意（バージョン依存）

- `DBMS_PARALLEL_EXECUTE` → 11g R2 以降（使用可）
- `DBMS_COMPARISON` → 11g R1 以降（使用可）
- `DBMS_JSON` → 12c R2（12.2）以降 → **使用禁止**

---

## コードレビューチェックリスト

実装後のコードレビューでは以下を確認する。

- [ ] `FETCH FIRST` / `OFFSET` を使っていないか
- [ ] `IDENTITY` 列を使っていないか（SEQUENCE+トリガーで代替）
- [ ] `JSON_TABLE` / `JSON_OBJECT` 等の JSON 関数を使っていないか
- [ ] `ON OVERFLOW TRUNCATE` を使っていないか
- [ ] `SET LINESIZE AUTO` 等の SQLcl 専用コマンドを使っていないか
- [ ] `VARCHAR2` を 4000 バイト超で使っていないか（CLOB で代替）
- [ ] SQLcl の `SCRIPT` コマンドを使っていないか
- [ ] `DBMS_JSON` を使っていないか
