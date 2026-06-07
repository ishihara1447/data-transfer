# Phase 2 重変換（HEAVY_TRANSFORM）アーキタイプ集

## 0. この文書の位置づけ

`docs/phase2-transform-design.md` で定義した変換3分類のうち、`HEAVY_TRANSFORM`
（正規化・結合・分割を伴う重変換）について、想定される代表的なアーキタイプ（型）を
網羅的に列挙し、設計指針を与える。

### 0.1 本書が必要な背景

業務オーナーは**セキュリティ上の理由により、実際の変換ルール（列マッピングや
ビジネスロジックの詳細）を事前開示できない**。そのため、本書では実際のルールを
名指しせず、「実際に来るルールがどれかに当てはまるはずの型」を先に整理しておき、
ルール確定後にすみやかに `transform_catalog` への登録・専用プロシージャ実装へ
落とし込めるようにする。

各アーキタイプは次の観点で記述する。

1. 定義
2. 入力例（実テーブル `customers` / `orders` / `regions` / `order_items` 等を題材に）
3. 変換ロジック方針
4. 12c 互換の実装手段
5. 冪等性（MERGE）の効かせ方
6. DELTA 増分での扱い
7. FK・適用順の注意
8. リスク

### 0.2 前提とする実テーブル構造（再掲）

検討の土台として、STAGING_SCHEMA（= SRC_SCHEMA ミラー）に存在する代表的なテーブルを
以下に整理する（いずれも `docs/migration-design.md` のサンプルとは別系統の、
実環境の参照用テーブル群）。

| テーブル | 主な列 | 備考 |
|---------|-------|------|
| `customers` | customer_id, customer_code, company_name, last_name, first_name, email, phone, region_id(FK), credit_limit, status, avatar_image(BLOB), remarks(CLOB), created_at, updated_at, created_by | LOB列を含む（G13 と関連） |
| `orders` | order_id, order_no, customer_id(FK), shipping_region_id(FK), status, order_date, ship_date, delivery_date, total_amount, tax_amount, shipping_address(CLOB=JSON), notes, created_at, updated_at | shipping_address は JSON 文字列を格納する CLOB |
| `regions` | region_id, region_code, region_name, parent_region_id, display_order, is_active | 自己参照（階層構造） |
| `order_items` | （明細行。order_id, product_id, quantity, unit_price 等を想定） | 集約・ロールアップの素材 |
| `products` / `product_categories` | 商品マスタ・カテゴリ階層 | 非正規化JOINの素材 |
| `customer_contracts` | 顧客契約情報 | 1→N 分割の素材 |
| `order_status_history` / `price_history` | 履歴テーブル | SCD/履歴化の素材 |

> **重要**: 上記は「実際に存在することが確認できているテーブル構造」であり、
> 実際の変換ルール（どの列をどう変換するか）はここには含まれない。
> アーキタイプの説明では、これらのテーブルを **題材として仮の変換例**を示すに
> とどめ、実ルールを先取りしない。

### 0.3 共通の前提・制約

- Oracle 12c 互換 SQL/PL/SQL のみを使用する（`docs/oracle-compatibility-policy.md` 準拠）。
- **JSON_VALUE / JSON_TABLE / JSON_OBJECT 等の JSON 関数は使用禁止**。
  JSON 文字列の解析は `REGEXP_SUBSTR` / `SUBSTR` / `INSTR` の組み合わせで行う。
- 変換は決定論的（同一入力 → 同一出力）。`SYSDATE` / `DBMS_RANDOM` を変換結果に
  混入させない。
- INITIAL（全量）は DELETE+INSERT、DELTA（増分）は `updated_at` スナップショット窓
  の MERGE を基本とする（`docs/phase2-transform-design.md` 5.4 節 を踏襲）。
- 削除伝播あり（STAGING に存在しない PK は TARGET からも削除する方針を基本線とする）。

---

## 1. アーキタイプ一覧（サマリ）

| # | アーキタイプ名 | 一言定義 | 代表的な該当例（題材） |
|---|--------------|---------|---------------------|
| 1 | 半構造化（JSON/CLOB）分解 | CLOB に格納された半構造化データを複数列に分解する | `orders.shipping_address`（JSON文字列）→ postal_code/prefecture/city/address |
| 2 | 非正規化JOIN（N→1） | 複数 STAGING テーブルを結合し1つの TARGET 行を生成する | `orders` + `regions` → region_name 付き enriched order |
| 3 | 正規化分割（1→N） | 1つの STAGING テーブルを複数の TARGET テーブルへ分割する | `customers` → `customers` + `customer_contact` |
| 4 | 集約/ロールアップ | 明細行を集計して親または別表に格納する | `order_items` → `orders` の合計列、または `order_summary` 表 |
| 5 | コード値マッピング（データ駆動） | ハードコード CASE でなくマッピング表を参照して変換する | ステータスコード、地域コード等の変換に `code_mapping` 表を利用 |
| 6 | 代理キー/ID 再マッピング | 旧自然キー体系を新代理キー体系に置き換える | 旧 `customer_code` → 新 `customer_id`（サロゲートキー）と `key_map` |
| 7a | SCD（緩やかに変化する次元）/履歴化 | 変更履歴を保持しながら現在値も維持する | `order_status_history` / `price_history` を使った履歴管理 |
| 7b | 行→列ピボット／列→行アンピボット | 行集合を列に展開する、または列集合を行に展開する | カテゴリ別売上集計列の生成、属性値テーブルの正規化 |

以下、各アーキタイプを詳述する。

---

## 2. アーキタイプ1: 半構造化（JSON/CLOB）分解

### 2.1 定義

CLOB 列に格納された半構造化データ（JSON 文字列、区切り文字形式の複合データ等）を
パースし、構造化された複数の列・複数のテーブルに分解する変換。

### 2.2 入力例

`orders.shipping_address`（CLOB）に以下のような JSON 文字列が格納されている想定。

```json
{"postal_code":"100-0001","prefecture":"東京都","city":"千代田区","address":"千代田1-1"}
```

これを TARGET 側で `postal_code` / `prefecture` / `city` / `address_detail` の
4列に分解する、という形が代表例として想定される。

### 2.3 変換ロジック方針

JSON 関数が使用できないため、キー名を手がかりにした正規表現抽出で代替する。

```
1. キー名でアンカーした REGEXP_SUBSTR でバリュー部分を抜き出す
   例: REGEXP_SUBSTR(json_str, '"postal_code"\s*:\s*"([^"]*)"', 1, 1, NULL, 1)
       → サブグループ抽出（第6引数 subexpression）で値だけを取得
2. 値が見つからない場合（キー欠落・JSON 不正）は NULL を返す
3. 抽出した文字列を必要に応じて TRIM・型変換する
```

擬似コード（イメージ）:

```sql
FUNCTION extract_json_string(
    p_json IN CLOB,
    p_key  IN VARCHAR2
) RETURN VARCHAR2 IS
    v_pattern VARCHAR2(200);
BEGIN
    v_pattern := '"' || p_key || '"\s*:\s*"([^"]*)"';
    RETURN REGEXP_SUBSTR(p_json, v_pattern, 1, 1, NULL, 1);
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;  -- 解析失敗時は NULL（呼び出し側でエラー記録するか方針を分ける）
END;
```

> **注記**: `REGEXP_SUBSTR` の第1引数が CLOB の場合、長大な CLOB では性能・
> メモリ使用量に注意する（10000文字を超えるあたりから `REGEXP_*` 系関数の
> パフォーマンスが劣化することが知られている）。事前に `DBMS_LOB.SUBSTR` で
> 妥当なサイズに切り出してから正規表現を適用する設計が無難。

### 2.4 12c 互換の実装手段

| 手段 | 互換性 | 備考 |
|------|--------|------|
| `REGEXP_SUBSTR(str, pattern, position, occurrence, modifier, subexpression)` | 10g R2 以降で利用可 | サブグループ抽出（第6引数）が鍵 |
| `REGEXP_REPLACE` | 10g 以降 | 不要な空白除去・エスケープ解除に利用 |
| `INSTR` / `SUBSTR` | バージョン非依存 | 単純な区切り文字ベースのパースに利用 |
| `DBMS_LOB.SUBSTR` / `DBMS_LOB.INSTR` | バージョン非依存 | CLOB の部分参照・検索 |
| JSON_VALUE / JSON_TABLE | **使用禁止**（12c R2 以降） | ポリシー違反のため不採用 |

### 2.5 冪等性（MERGE）の効かせ方

JSON 分解そのものは PK に紐づく決定論的な変換（同じ JSON 文字列からは常に同じ
分解結果が得られる）であるため、通常の MERGE パターンに自然に乗る。

```sql
MERGE INTO target_schema.orders t
USING (
    SELECT
        s.order_id,
        extract_json_string(s.shipping_address, 'postal_code') AS postal_code,
        extract_json_string(s.shipping_address, 'prefecture')  AS prefecture,
        extract_json_string(s.shipping_address, 'city')        AS city,
        extract_json_string(s.shipping_address, 'address')     AS address_detail
        -- 他の列も含む
    FROM staging_schema.orders s
    WHERE s.updated_at > :v_last_transform_at
) src
ON (t.order_id = src.order_id)
WHEN MATCHED THEN UPDATE SET
    t.postal_code    = src.postal_code,
    t.prefecture     = src.prefecture,
    t.city           = src.city,
    t.address_detail = src.address_detail
WHEN NOT MATCHED THEN INSERT (...) VALUES (...);
```

### 2.6 DELTA 増分での扱い

- `shipping_address`（JSON）が更新されれば `orders.updated_at` も更新される前提
  であれば、通常の `updated_at` スナップショット窓の MERGE で対応できる。
- 注意点: JSON の**一部キーだけ**が変わるケース（例: `postal_code` のみ訂正）でも、
  行全体が UPDATE 対象になるため再分解・再 MERGE で問題なく追従できる
  （行単位の差分なので、JOIN/集約系のような波及範囲特定の問題は生じにくい）。
- 解析失敗（JSON 不正）の扱いを `migration_error_log` 相当のログにどう記録するか
  （NULL化して継続するか、エラーとして停止するか）を方針として固定する必要がある。

### 2.7 FK・適用順の注意

- 分解結果が他テーブルの FK 値（例: 分解した郵便番号から地域マスタを引き当てる等）
  に使われる場合は、参照先マスタが先に変換済みであることを保証する
  （`transform_catalog.sort_order` で順序制御）。
- 分解先が同一テーブル内の追加列であれば（本例のように）、追加の適用順制約は
  生じない。

### 2.8 リスク

| リスク | 内容 | 緩和策 |
|--------|------|--------|
| JSON フォーマットの揺れ | キー順序の変化・エスケープ文字・ネスト構造・配列等、正規表現で対応しきれない構造が混入する | サンプリング調査でフォーマットパターンを事前に洗い出す。想定外パターンはエラーログに記録し、手動レビューに回す |
| CLOB サイズと正規表現の性能 | 大きな CLOB に対する REGEXP 系関数の処理コスト | `DBMS_LOB.SUBSTR` で範囲限定、またはバッチサイズを縮小 |
| 文字コード・エスケープ | `\"` や日本語混在時のマルチバイト処理 | `REGEXP_REPLACE` での前処理、NLS 設定の確認 |
| 部分的な解析失敗 | 一部キーのみ欠落するケースで NULL 列が増える | 必須キーの欠落を「エラー」、任意キーの欠落を「NULL許容」に分けて方針を明示する |

---

## 3. アーキタイプ2: 非正規化JOIN（N→1）

### 3.1 定義

複数の STAGING テーブルを JOIN し、参照先の属性値（コード値に対する名称等）を
非正規化（インライン展開）した1つの TARGET 行を生成する変換。

### 3.2 入力例

`orders`（shipping_region_id で `regions` を参照）から、`region_name` を
インライン化した「リッチな注文ビュー」相当の TARGET テーブルを生成する、
という形が代表例として想定される。`regions` は自己参照の階層構造を持つため、
親地域名まで含めて非正規化するケースもありうる。

### 3.3 変換ロジック方針

```
1. STAGING 側で対象テーブルと参照テーブルを JOIN した変換元データセットを定義する
   （ビューまたはカーソル SELECT として定義）
2. JOIN 結果から TARGET の列を 1:1 にマッピングして MERGE する
3. 階層構造（parent_region_id）を辿る場合は、階層の深さが可変であることに注意し、
   再帰サブクエリ（CONNECT BY または再帰 WITH 句）で名称チェーンを解決する
```

擬似コード:

```sql
SELECT
    o.order_id,
    o.order_no,
    o.customer_id,
    o.shipping_region_id,
    r.region_name        AS shipping_region_name,
    pr.region_name       AS shipping_region_parent_name,  -- 階層を遡る場合
    o.total_amount,
    o.order_date,
    o.updated_at         AS staging_updated_at
FROM staging_schema.orders o
LEFT JOIN staging_schema.regions r  ON r.region_id = o.shipping_region_id
LEFT JOIN staging_schema.regions pr ON pr.region_id = r.parent_region_id
WHERE o.updated_at > :v_last_transform_at
   OR r.updated_at  > :v_last_transform_at   -- ★ 後述: 参照側変更の波及
```

### 3.4 12c 互換の実装手段

| 手段 | 互換性 | 備考 |
|------|--------|------|
| 標準 JOIN（INNER/LEFT OUTER） | バージョン非依存 | 基本構文 |
| `CONNECT BY PRIOR` または再帰 `WITH` 句 | 12c で利用可 | 階層展開に使用。再帰 WITH は 11g R2 以降 |
| `LISTAGG` | 11g R2 以降で利用可 | 複数値の連結表示が必要な場合 |

### 3.5 冪等性（MERGE）の効かせ方

JOIN 結果を `USING` 句のサブクエリとして MERGE のソースに渡す形で、
通常の MERGE パターンに乗せられる。ON 句は変換元（中心テーブル）の PK を使う。

```sql
MERGE INTO target_schema.order_enriched t
USING ( /* 3.3 の JOIN クエリ */ ) src
ON (t.order_id = src.order_id)
WHEN MATCHED THEN UPDATE SET t.shipping_region_name = src.shipping_region_name, ...
WHEN NOT MATCHED THEN INSERT (...) VALUES (...);
```

### 3.6 DELTA 増分での扱い（最重要論点）

非正規化 JOIN の DELTA 増分対応における本質的な難所は、
**「中心テーブル（orders）が変わらなくても、参照テーブル（regions）側だけが
変わった場合に、どの中心テーブルの行を再変換すべきか」**という**影響波及
（再計算範囲）の特定**である。

```
ケースA: orders 側が変わった
   → orders.updated_at で検出可能。通常の MERGE で対応できる。

ケースB: regions 側だけが変わった（例: region_name の改称）
   → orders.updated_at は変化しない。
   → しかし regions.region_name をインライン化した TARGET 行は古い名称のまま残る。
   → 「regions の変更が、どの orders 行に波及するか」を特定する必要がある。
```

**対応方針の選択肢:**

| 方針 | 内容 | 利点 | 欠点 |
|------|------|------|------|
| A. 参照側も updated_at 条件に含める（上記擬似コードの `OR r.updated_at > ...`） | 参照テーブルが更新されたら、それを参照する全行を再 MERGE 対象にする | 実装がシンプル。MERGE は冪等なので再実行しても安全 | 参照テーブル1行の変更が大量の中心テーブル行の再 MERGE を誘発する可能性（性能リスク） |
| B. 参照テーブル変更時に「影響を受ける中心テーブルの PK 一覧」を別途特定し、対象を絞り込む | 再計算範囲を最小化できる | 影響範囲特定のロジックが複雑化（実質的に依存関係グラフの管理が必要） | 設計・実装コストが高い。階層構造（自己参照）がある場合はさらに複雑 |
| C. 非正規化をやめ、TARGET 側でも参照列（region_id）のみ保持し、名称表示は VIEW で JOIN する | 再計算問題そのものが消える | 「非正規化して名称をインライン化する」という変換要件自体を満たさなくなる（要件次第で不可） |

**推奨**: まず方針 A（参照側も `updated_at` 条件に含める）から着手する。
JOIN 対象の参照テーブル（`regions` 等のマスタ系）は更新頻度が低いことが
一般的であるため、再計算範囲の肥大化リスクは限定的であることが多い。
更新頻度が高いマスタに対して非正規化 JOIN を行う設計が判明した場合は、
方針 B（影響範囲の特定テーブルを別途設計する）を検討する。

**削除の影響**: 参照テーブル側の行（例: `regions` の特定地域）が削除された場合、
LEFT JOIN であれば中心テーブルの行は残り、インライン化した名称列が NULL になる
（参照整合性が壊れた状態を示す）。これを「削除前の名称を保持する（履歴化）」のか
「NULL にする」のかは業務要件によって決まるため、実ルール確定時の確認事項とする。

### 3.7 FK・適用順の注意

- JOIN 対象の参照テーブル（`regions`）は中心テーブル（`orders`）より**先に**
  変換が完了している必要がある（`transform_catalog.sort_order` で制御）。
- ただし「非正規化」変換では TARGET 側に FK 制約自体が存在しない設計も
  ありうる（インライン化により参照が不要になるため）。FK 制約の有無は
  TARGET スキーマ設計（実装フェーズ）で確定する。

### 3.8 リスク

| リスク | 内容 | 緩和策 |
|--------|------|--------|
| 参照側変更の波及見逃し | regions 側だけ変更された場合に再変換が漏れる | 3.6 の方針A/Bを明示的に選択し、テストケースに含める |
| 階層の循環参照 | `parent_region_id` の循環設定により無限ループ | `CONNECT BY NOCYCLE` または事前のデータ検証 |
| 性能劣化 | 大量の中心テーブル行に対して毎回参照テーブルを JOIN するコスト | 参照テーブルの行数は少ないことが一般的であり、適切な索引で緩和可能 |
| LEFT JOIN の NULL 展開漏れ | 参照キーが NULL または不整合な場合の扱いを失念する | テストデータに「参照先が存在しない」ケースを必ず含める |

---

## 4. アーキタイプ3: 正規化分割（1→N）

### 4.1 定義

1つの STAGING テーブルの列群を、複数の TARGET テーブルに分割して格納する変換
（非正規化されたレガシー構造を、新システムの正規化されたモデルへ分解する）。

### 4.2 入力例

`customers` テーブルの連絡先関連列（例: `email` / `phone` 等の連絡先情報）を
`customers`（基本情報）と `customer_contact`（連絡先、複数行になりうる）の
2テーブルに分割する、という形が代表例として想定される。
また `customer_contracts` のような既存の関連テーブルを、新スキーマでの
親子関係に合わせて再編成するケースもこの型に含まれる。

### 4.3 変換ロジック方針

```
1. STAGING の1行から、TARGET 親テーブル（例: customers）に入る列群と
   TARGET 子テーブル（例: customer_contact）に入る列群を仕分ける
2. 親テーブルへの MERGE を先に実行する（親キーが確定する）
3. 子テーブルへの MERGE は親キーを外部キーとして使用する
   （親キーが代理キーの場合はキー生成・マッピングが必要 → アーキタイプ6と組み合わせる）
4. 1つの STAGING 列値が複数の子テーブル行に展開される場合
   （例: "email1;email2" のような複合値を複数行へ）は、
   行展開ロジック（後述）が必要になる
```

擬似コード（親と子を別々に MERGE する基本形）:

```sql
-- (1) 親テーブルへの MERGE（基本属性のみ）
MERGE INTO target_schema.customers t
USING (SELECT customer_id, customer_code, company_name, ... FROM staging_schema.customers
       WHERE updated_at > :v_last_transform_at) src
ON (t.customer_id = src.customer_id)
WHEN MATCHED THEN UPDATE SET ...
WHEN NOT MATCHED THEN INSERT (...) VALUES (...);

-- (2) 子テーブルへの MERGE（連絡先情報を分離）
MERGE INTO target_schema.customer_contact t
USING (SELECT customer_id, 'EMAIL' AS contact_type, email AS contact_value
       FROM staging_schema.customers
       WHERE email IS NOT NULL
         AND updated_at > :v_last_transform_at
       UNION ALL
       SELECT customer_id, 'PHONE', phone
       FROM staging_schema.customers
       WHERE phone IS NOT NULL
         AND updated_at > :v_last_transform_at
      ) src
ON (t.customer_id = src.customer_id AND t.contact_type = src.contact_type)
WHEN MATCHED THEN UPDATE SET t.contact_value = src.contact_value
WHEN NOT MATCHED THEN INSERT (...) VALUES (...);
```

> 上記は「1列1値→複数行」へ展開する典型パターンの例示であり、
> 実際にどの列をどう分割するかは業務ルール確定後に決定する。

### 4.4 12c 互換の実装手段

| 手段 | 互換性 | 備考 |
|------|--------|------|
| `MERGE` の複数回呼び出し（親→子の順） | バージョン非依存 | 基本パターン |
| `UNION ALL` による行展開 | バージョン非依存 | 列→複数行の変換に有効 |
| SEQUENCE + トリガーによる代理キー採番 | 12c で利用可 | 子テーブルの PK 採番に使用（IDENTITY 列禁止のため） |

### 4.5 冪等性（MERGE）の効かせ方

- 親テーブルの MERGE は PK（または代理キー）で ON 句を構成する標準パターン。
- 子テーブルの MERGE は、**複合キー**（例: `customer_id + contact_type`）を
  ON 句にすることで、複数行展開でも冪等性を維持できる。
  単純な `customer_id` のみでは MATCHED の判定が一意にならず、再実行で
  重複行が発生するリスクがあるため、子テーブルの論理キー設計が重要になる。
- 子テーブルが「STAGING 側に存在しない値は捨てる」設計の場合、
  親の値が NULL に変わったときに子テーブルから対応行を DELETE する必要がある
  （MERGE の `WHEN MATCHED THEN ... DELETE WHERE` 句、または別途 DELETE 文）。

```sql
-- 親の値が NULL になった場合に子の対応行を削除する例（MERGE 内 DELETE 句）
MERGE INTO target_schema.customer_contact t
USING (...) src
ON (t.customer_id = src.customer_id AND t.contact_type = src.contact_type)
WHEN MATCHED THEN UPDATE SET t.contact_value = src.contact_value
    DELETE WHERE src.contact_value IS NULL
WHEN NOT MATCHED THEN INSERT (...) VALUES (...)
    WHERE src.contact_value IS NOT NULL;
```

### 4.6 DELTA 増分での扱い

- 親・子とも変換元は同じ STAGING テーブル（`customers`）の `updated_at` で
  検出できるため、JOIN/集約系のような「波及範囲の特定」問題は生じにくい
  （1テーブルの更新が分割先の親子テーブルに収まるため、影響範囲は自明）。
- 注意点: **適用順序**。親が確定する前に子を MERGE すると FK 違反になるため、
  同一バッチ内で「親 MERGE → 子 MERGE」の順序を厳密に守る必要がある
  （`transform_by_table` 内でサブステップとして直列に実行する設計とする）。
- 親の代理キーが新規採番される場合（アーキタイプ6と組み合わさる場合）は、
  子の MERGE 時に親キーのマッピング結果を参照できる必要がある
  （同一トランザクション内、または `key_map` の COMMIT 後に子を処理する）。

### 4.7 FK・適用順の注意

- `transform_catalog.sort_order` では「親子関係」を明示的に表現する必要がある。
  通常の独立テーブル間の依存（例: customers → orders）と異なり、
  **同一変換プロシージャ内でのサブステップ順序**として管理する点に注意。
- 親 MERGE と子 MERGE を別々の `transform_step_log` ステップとして記録するか、
  1つの `TRANSFORM_CUSTOMERS` ステップ内の処理として記録するかは、
  ログの粒度方針として実装フェーズで決定する（後者を推奨: 親子分割は
  1つの変換単位として扱う方が追跡しやすい）。

### 4.8 リスク

| リスク | 内容 | 緩和策 |
|--------|------|--------|
| 子テーブルの論理キー設計ミス | 複合キーが一意にならず MERGE で重複行が発生する | 子テーブルの論理キーを事前設計し、UNIQUE 制約で担保する |
| 親子の COMMIT 順序ミス | 子が親より先に確定し FK 違反になる | 同一プロシージャ内で順序を固定し、テストで検証する |
| 分割条件の解釈揺れ | 「どの列をどちらに入れるか」の境界が曖昧 | 業務ルール確定時にマッピング表（列単位の振り分け）を作成する |
| 子の削除漏れ | 親の値が NULL/削除されても子の対応行が残る（ゴースト行） | 4.5 の DELETE WHERE 句、または定期整合バッチで検出 |

---

## 5. アーキタイプ4: 集約/ロールアップ

### 5.1 定義

明細レベルのデータ（例: 注文明細）を集計し、親テーブルの集計列、または
独立した集計専用テーブル（サマリテーブル）に格納する変換。

### 5.2 入力例

`order_items`（注文明細）の `quantity * unit_price` を集計して
`orders.total_amount` を再計算する、または `order_summary`
（顧客別・期間別の売上集計表等）を生成する、という形が代表例として想定される。

### 5.3 変換ロジック方針

```
パターンA: 親テーブルの集計列を更新する
  UPDATE / MERGE で order_items を GROUP BY し、orders.total_amount 等を更新

パターンB: 独立したサマリテーブルを生成する
  customer_id・期間（年月等）等のキーで GROUP BY し、サマリ表に MERGE
```

擬似コード（パターンB: 月次サマリの例）:

```sql
MERGE INTO target_schema.order_summary t
USING (
    SELECT
        o.customer_id,
        TRUNC(o.order_date, 'MM')        AS summary_month,
        COUNT(*)                          AS order_count,
        SUM(o.total_amount)               AS total_sales
    FROM staging_schema.orders o
    WHERE o.order_date >= :v_period_start
      AND o.order_date <  :v_period_end
    GROUP BY o.customer_id, TRUNC(o.order_date, 'MM')
) src
ON (t.customer_id = src.customer_id AND t.summary_month = src.summary_month)
WHEN MATCHED THEN UPDATE SET
    t.order_count = src.order_count,
    t.total_sales = src.total_sales
WHEN NOT MATCHED THEN INSERT (...) VALUES (...);
```

### 5.4 12c 互換の実装手段

| 手段 | 互換性 | 備考 |
|------|--------|------|
| `GROUP BY` / 集計関数（`SUM`/`COUNT`/`AVG` 等） | バージョン非依存 | 標準 SQL |
| `TRUNC(date, fmt)` による期間グルーピング | バージョン非依存 | 月次・日次集計の基本 |
| 分析関数（`SUM() OVER (PARTITION BY ...)`） | 8i 以降で利用可 | 移動集計・累積集計が必要な場合 |
| `MERGE` | 9i 以降 | 集計結果の反映 |

### 5.5 冪等性（MERGE）の効かせ方

- サマリテーブルへの MERGE は「集計キー（顧客×期間 等）」を ON 句にすることで
  冪等になる。同じ期間を再集計しても、結果が同じであれば UPDATE で上書きされ
  重複は発生しない。
- **重要な前提**: 集計の元データ範囲（期間・対象 PK 集合）を**毎回同じ条件で
  再現できる**ことが決定論的変換の必須条件である。「直近1時間分の注文を集計」
  のような相対的な範囲指定は、実行タイミングによって結果が変わるため、
  **確定した期間境界**（例: 月初〜月末、または `commit_scn` 区間）を使う設計
  にする必要がある。

### 5.6 DELTA 増分での扱い（最重要論点）

集約/ロールアップの DELTA 対応は、HEAVY_TRANSFORM の中でも**最も再計算範囲の
特定が難しいパターン**である。

```
問題の本質:
  1件の order_items の変更（INSERT/UPDATE/DELETE）が、
  その明細が属する注文（orders）の集計列、
  さらにその注文が属する顧客×期間のサマリ行
  に波及する。

  「変更された明細行」だけを部分更新すると、集計の整合性を壊しやすい
  （例: SUM への加減算は、丸め誤差・二重計上・計上漏れのリスクが高い）。
```

**対応方針の選択肢:**

| 方針 | 内容 | 利点 | 欠点 |
|------|------|------|------|
| A. 影響キー単位で「全体再集計」する（推奨） | 変更された明細から「影響を受ける集計キー（注文ID、または顧客×期間）」を特定し、そのキーに属する明細を**全件**再集計して MERGE で洗い替える | 加減算方式に比べて整合性が保証されやすい（5.5の決定論的範囲の原則と相性が良い） | 影響キーに属する明細件数が多い場合、再集計のコストが高い |
| B. 差分加減算（インクリメンタル集計） | 変更された明細の差分量だけ集計列に加減算する | 計算コストは小さい | INSERT/UPDATE/DELETE の組み合わせで誤差が蓄積しやすく、決定論性・冪等性の保証が難しい（同じ差分を二重適用すると壊れる） |
| C. 集計を変換層で持たず、TARGET 側を VIEW / マテリアライズドビューにする | 集計ロジックの実装・保守をDB機能に委ねる | 再計算問題が事実上消える | マテリアライズド・ビューのリフレッシュ戦略が別途必要になり、「変換層で完結」という設計方針からは外れる |

**推奨**: 方針 A（影響キー単位の全体再集計＋ MERGE 洗い替え）を基本線とする。
理由は、決定論的変換・冪等性の原則（6.1節「同じ入力から常に同じ出力」）と
最も整合するため。具体的な影響キーの特定方法は次の手順を想定する。

```
1. STAGING.order_items から updated_at > last_transform_at の行を抽出
2. その行が属する order_id の集合を特定（影響を受けた注文）
3. order_id 集合から customer_id × summary_month の集合を特定（影響を受けたサマリキー）
4. 影響キーに属する明細を「全件」抽出して再集計
5. 再集計結果を MERGE（洗い替え）で反映
```

```sql
-- 影響キー（顧客×月）の特定
SELECT DISTINCT o.customer_id, TRUNC(o.order_date, 'MM') AS summary_month
FROM staging_schema.order_items oi
JOIN staging_schema.orders o ON o.order_id = oi.order_id
WHERE oi.updated_at > :v_last_transform_at;

-- 上記の影響キー集合に対して「全件再集計」を実行し MERGE で洗い替える
```

**削除の影響**: `order_items` から明細行が削除されると、対応する集計値は
減算が必要になる。差分加減算（方針B）では「削除された行の値」を遡って
取得できないと正しく減算できない（`delta_apply` が SQL_REDO の UNDO 情報を
保持していない限り、削除前の値の参照は難しい）。これも方針A（全体再集計）を
推奨する理由の一つである。全体再集計であれば、削除後の現在の明細行集合から
集計するため、削除の影響は自然に反映される。

### 5.7 FK・適用順の注意

- 明細（`order_items`）→ 親（`orders`）→ サマリ（`order_summary`）の順に
  依存関係があるため、`sort_order` をこの順に設定する。
- ただし「親の集計列を更新する」パターンA（5.3）の場合は、親テーブル自体の
  変換ステップの**後段**として実行する必要がある（同じ変換ステップ内の
  サブステップとするか、独立ステップとするかは設計判断）。

### 5.8 リスク

| リスク | 内容 | 緩和策 |
|--------|------|--------|
| 影響キー特定漏れ | 明細の変更が波及するキーを取りこぼし、サマリが古いまま残る | 影響キー特定クエリを慎重にレビューし、結合条件の漏れがないか確認する |
| 再集計範囲の肥大化 | 1件の変更で大量の影響キーが特定され、再集計コストが跳ね上がる | 影響キーの粒度設計（期間の区切り方等）を見直す。バッチサイズ調整 |
| 丸め誤差の蓄積 | 金額集計で NUMBER の精度・丸めルールの不一致 | 集計列の精度を STAGING 元データと揃え、ROUND の方針を明示する |
| 決定論性の崩れ | 「直近N時間」等の相対的範囲指定により実行タイミング依存の結果になる | 確定した期間境界（月初〜月末等）または commit_scn 区間で範囲を固定する |

---

## 6. アーキタイプ5: コード値マッピング（データ駆動）

### 6.1 定義

ステータスコード・地域コード等のコード値変換を、PL/SQL の `CASE` 式に
ハードコードするのではなく、**マッピング表（`code_mapping` 等）を参照して
動的に解決する**変換方式。

### 6.2 入力例

`orders.status`（'CONFIRMED' / 'DRAFT' 等）や `customers.status`
（'ACTIVE' / 'SUSPENDED' / 'CLOSED'）を新システムのコード体系に変換する際、
変換ルールをハードコードせず `code_mapping` 表に持たせる、という形が
代表例として想定される。

### 6.3 変換ロジック方針

```
1. マッピング表を設計する（domain, src_value, tgt_value, is_active, effective_from 等）
2. 変換時に対象列の値をキーとしてマッピング表を参照し、対応する新コードを取得する
3. マッピングが存在しない値（未定義コード）の扱いを方針として明示する
   （デフォルト値にフォールバックする / エラーとして記録する 等）
```

マッピング表の設計例:

```sql
CREATE TABLE log_schema.code_mapping (
    mapping_id     NUMBER(10)     NOT NULL,
    domain         VARCHAR2(50)   NOT NULL,  -- 例: 'ORDER_STATUS', 'CUSTOMER_STATUS'
    src_value      VARCHAR2(100)  NOT NULL,  -- 変換前コード（STAGING 値）
    tgt_value      VARCHAR2(100)  NOT NULL,  -- 変換後コード（TARGET 値）
    is_active      VARCHAR2(1)    DEFAULT 'Y',
    effective_from DATE,                      -- マッピングの有効開始日（履歴管理用、任意）
    remarks        VARCHAR2(400),
    CONSTRAINT pk_code_mapping PRIMARY KEY (mapping_id),
    CONSTRAINT uq_code_mapping UNIQUE (domain, src_value, effective_from)
);
```

変換時の参照（決定論性を保つため、`effective_from` を使う場合は
変換対象行の基準日付で結合する）:

```sql
SELECT
    o.order_id,
    NVL(cm.tgt_value, 'UNKNOWN') AS new_status   -- 未定義時のフォールバック例
FROM staging_schema.orders o
LEFT JOIN log_schema.code_mapping cm
       ON cm.domain    = 'ORDER_STATUS'
      AND cm.src_value = o.status
      AND cm.is_active = 'Y'
```

### 6.4 12c 互換の実装手段

| 手段 | 互換性 | 備考 |
|------|--------|------|
| 通常の表 + JOIN / サブクエリ | バージョン非依存 | マッピング表もただの表として扱える |
| `NVL` / `COALESCE` | バージョン非依存 | フォールバック値の指定 |
| ファンクションキャッシュ（`PRAGMA UDF` や `RESULT_CACHE`） | 11g 以降で利用可 | マッピング参照を関数化する場合の性能対策（任意） |

> マッピング表方式自体は標準的な表参照であり、12c 互換上の懸念はない。

### 6.5 冪等性（MERGE）の効かせ方

- マッピング参照を含む変換も、結果として「STAGING の1行 → TARGET の1行」の
  決定論的な対応関係になるため、通常の MERGE パターンに乗る。
- **前提条件**: 変換実行時点のマッピング表の内容が、変換結果の決定論性に
  影響する。すなわち「マッピング表の内容が変わると、過去に変換した結果も
  変わりうる」という、他のアーキタイプにはない特性を持つ
  （詳細は 6.6 節）。

### 6.6 DELTA 増分での扱い（最重要論点: マッピング表自体が更新されたとき）

コード値マッピングのアーキタイプ固有の難所は、**マッピング表自体が
更新されたときに、過去に変換済みの TARGET 行をどう扱うか**である。

```
ケースA: STAGING 側のコード値が変わった（通常の差分）
   → updated_at で検出可能。通常の MERGE で対応できる。

ケースB: マッピング表側が変わった（例: 'DRAFT' の変換先を 'PENDING' から 'DRAFT_SAVED' に変更）
   → STAGING 側の該当行の updated_at は変化しない。
   → しかし、過去に 'PENDING' として変換済みの TARGET 行は
     新しいマッピングルールでは 'DRAFT_SAVED' になるべき状態。
   → 「遡って再変換すべきか」「過去分はそのまま据え置くか」は業務要件次第。
```

**対応方針の選択肢:**

| 方針 | 内容 | 利点 | 欠点 |
|------|------|------|------|
| A. マッピング変更時は影響ドメインを全件再変換する | `code_mapping` の `domain` 単位で、対象列を持つ STAGING 全行を再変換対象にする | シンプルで取りこぼしがない | マッピング変更の都度、広範囲の再変換が走る（コスト増） |
| B. マッピングに有効期間（`effective_from`）を持たせ、変換時点のルールで変換した結果を「正」として固定する（履歴を変えない） | 決定論性の定義を「変換実行時点のマッピングルールに従う」と明確化できる。再変換コストが発生しない | 過去データと最新データでルールの異なる行が混在しうる（業務的に許容できるかは要確認） |
| C. マッピング変更を「業務上のマスタ更新」として扱い、変換層では対応せず、必要なら別途一括補正バッチを用意する | 変換層をシンプルに保てる | 補正バッチの設計・運用が別途必要 |

**推奨**: 方針 B を基本としつつ、運用上「過去分の遡及修正」が必要になった
場合に備えて方針 A の「特定ドメインの全件再変換」をオンデマンド実行できる
プロシージャ（`transform_by_table` の拡張、または専用の補正プロシージャ）を
用意しておく、というハイブリッドが現実的である。
**この点は実ルール確定時に「マッピングは変更されうるものか」「変更時に
過去データを遡及するか」を業務オーナーに確認すべき重要事項**である。

### 6.7 マッピング表自体の管理

- マッピング表は `log_schema`（または変換層専用のメタデータスキーマ）で
  一元管理し、`transform_catalog` と同様にメタデータとして扱う。
- マッピング表へのメンテナンスは、変換処理本体とは独立した運用フロー
  （承認・レビューを伴うマスタ更新作業）として設計する。
- 変更履歴を追跡できるよう、`effective_from`（有効開始日）に加えて
  `created_at` / `created_by` 等の監査列を持たせることが望ましい
  （アーキタイプ7a の SCD 的発想と接続する）。

### 6.8 FK・適用順の注意

- マッピング表は変換処理の「参照データ」であるため、変換バッチ実行前に
  最新の状態が確定している必要がある（変換中にマッピング表が更新されると、
  バッチ内で参照するマッピングルールが行ごとに変わってしまい、決定論性が
  崩れる）。変換バッチ実行中はマッピング表をロックする、またはスナップショット
  時点を固定する設計が望ましい。

### 6.9 リスク

| リスク | 内容 | 緩和策 |
|--------|------|--------|
| マッピング未定義値の見落とし | STAGING に新しいコード値が出現し、マッピング表に未登録のまま変換される | フォールバック方針（デフォルト値 / エラー記録）を明示し、未定義値検出のアラートを用意する |
| マッピング変更時の遡及方針の未決 | 6.6 の論点が未決のまま実装すると、運用後に手戻りが発生する | 実装着手前に業務オーナーへ確認する必須事項としてリストアップする（後述） |
| バッチ実行中のマッピング表変更 | 同一バッチ内で異なるルールが混在する | バッチ実行前にマッピングのスナップショットを取得し、バッチ内ではそれを参照する |
| マッピング表自体の品質劣化 | 重複登録・矛盾するルールの混入 | UNIQUE 制約（`domain + src_value + effective_from`）と登録時のレビュー運用 |

---

## 7. アーキタイプ6: 代理キー/ID 再マッピング

### 7.1 定義

旧システムの自然キー（業務コードをそのまま PK にしている等）を、
新システムの代理キー（サロゲートキー、システム内部で採番する数値 ID 等）に
置き換える変換。旧キーと新キーの対応関係を `key_map` テーブルで管理し、
FK を新キー体系に張り替える。

### 7.2 入力例

`customers.customer_code`（業務上の顧客コード、自然キー）を、新システムでは
`customer_id`（サロゲートキー、`SEQUENCE` 等で採番される数値）に置き換える、
という形が代表例として想定される。`orders.customer_id` の FK も新キー体系に
張り替える必要がある。

### 7.3 変換ロジック方針

```
1. key_map テーブルを設計する（domain, src_key, tgt_key の対応を保持）
2. 変換対象行ごとに、旧キーに対応する新キーが key_map に存在するか確認する
   - 存在する → 既存の対応関係を使う（決定論性の維持）
   - 存在しない → 新キーを採番し、key_map に登録する
3. 採番した新キーを使って TARGET 行を MERGE する
4. 子テーブル（FK 側）の変換時には、key_map を介して FK 値を新キーに変換する
```

`key_map` テーブルの設計例:

```sql
CREATE TABLE log_schema.key_map (
    map_id      NUMBER(10)     NOT NULL,   -- 採番（SEQUENCE + トリガー）
    domain      VARCHAR2(50)   NOT NULL,   -- 例: 'CUSTOMER', 'PRODUCT'
    src_key     VARCHAR2(200)  NOT NULL,   -- 旧自然キー（STAGING 側の値）
    tgt_key     NUMBER(18)     NOT NULL,   -- 新代理キー（TARGET 側の値）
    created_at  TIMESTAMP      DEFAULT SYSTIMESTAMP,
    CONSTRAINT pk_key_map PRIMARY KEY (map_id),
    CONSTRAINT uq_key_map_src UNIQUE (domain, src_key),
    CONSTRAINT uq_key_map_tgt UNIQUE (domain, tgt_key)
);
```

擬似コード（採番の決定論的な扱い）:

```sql
-- 既存マッピングがあれば再利用、なければ新規採番して登録する
-- (MERGE で「存在すれば何もしない、なければ INSERT」を表現)
MERGE INTO log_schema.key_map km
USING (
    SELECT DISTINCT 'CUSTOMER' AS domain, s.customer_code AS src_key
    FROM staging_schema.customers s
    WHERE s.updated_at > :v_last_transform_at
) src
ON (km.domain = src.domain AND km.src_key = src.src_key)
WHEN NOT MATCHED THEN INSERT (map_id, domain, src_key, tgt_key)
    VALUES (seq_key_map.NEXTVAL, src.domain, src.src_key, seq_customer_id.NEXTVAL);

-- 採番済みの key_map を介して TARGET へ MERGE
MERGE INTO target_schema.customers t
USING (
    SELECT km.tgt_key AS customer_id, s.company_name, ...
    FROM staging_schema.customers s
    JOIN log_schema.key_map km
      ON km.domain = 'CUSTOMER' AND km.src_key = s.customer_code
    WHERE s.updated_at > :v_last_transform_at
) src
ON (t.customer_id = src.customer_id)
WHEN MATCHED THEN UPDATE SET ...
WHEN NOT MATCHED THEN INSERT (...) VALUES (...);
```

### 7.4 12c 互換の実装手段

| 手段 | 互換性 | 備考 |
|------|--------|------|
| `SEQUENCE` + `BEFORE INSERT` トリガー、または `SEQUENCE.NEXTVAL` を MERGE 内で直接使用 | 12c で利用可 | IDENTITY 列はポリシーで禁止のため代替手段 |
| `MERGE ... WHEN NOT MATCHED THEN INSERT` による「存在しなければ採番」 | 9i 以降 | 採番の冪等性を保証する鍵 |
| UNIQUE 制約（`domain + src_key`） | バージョン非依存 | 重複採番の防止 |

### 7.5 冪等性の効かせ方（決定論的な採番）

代理キー採番は本質的に「初めて見た値には新しい番号を振る」という性質を持つため、
**素朴な `SEQUENCE.NEXTVAL` の直接利用は再実行のたびに異なる番号を生成しうる**
（決定論性が崩れるリスクがある）。これを防ぐ鍵は次の2点である。

```
1. key_map による「採番結果の固定化」
   一度 key_map に登録された対応関係（src_key → tgt_key）は、
   以後変更しない（再実行時は既存の対応をそのまま再利用する）。
   → MERGE の WHEN NOT MATCHED でのみ新規採番することで、
     「初回は採番、以後は参照」という決定論的な振る舞いになる。

2. 採番とTARGET反映を明確に分離する
   (a) key_map への登録（新規キーのみ採番）
   (b) key_map を参照した TARGET への MERGE
   の2段階に分けることで、(a)が失敗して再実行されても、
   (b)は常に key_map の内容に従う一貫した結果になる。
```

> **注意**: (a) と (b) の間でトランザクションが分断される場合
> （例: (a) が COMMIT された後に (b) が失敗した場合）、再実行時に (a) の
> MERGE が「既に存在する」ため何もしない（冪等）ことを確認する。
> これにより部分失敗からの再開でも採番がずれない。

### 7.6 DELTA 増分での扱い

- 新規顧客が STAGING に追加されれば、`key_map` への新規登録 → TARGET への
  INSERT という流れが自然に追従する。
- 既存顧客の更新は、`key_map` の対応関係はそのまま（`src_key` は不変のため）、
  TARGET 側の属性列のみ UPDATE される。
- **削除時の扱い**: STAGING から顧客が削除された場合、`key_map` の対応関係を
  削除するか残すかは設計判断が必要。
  - 残す場合: 同じ自然キーが将来再登録されたときに同じ代理キーが割り当てられる
    （履歴の連続性は保たれるが、`key_map` が肥大化する）
  - 削除する場合: 再登録時に新しい代理キーが採番される
    （削除と再登録の間で代理キーが変わり、外部システムとの整合性に影響しうる）
  - **推奨**: 既定では `key_map` のレコードは削除せず保持する
    （論理削除フラグを追加する案も検討可）。代理キーの再利用は事故のもとになりやすい。

### 7.7 FK・適用順の注意（最重要）

代理キー再マッピングは、HEAVY_TRANSFORM の中でも特に**適用順序の制約が厳しい**。

```
正しい順序:
  1. 親テーブル（customers）の key_map 登録（新規 src_key の採番）
  2. 親テーブル（customers）の TARGET MERGE（新キーで確定）
  3. 子テーブル（orders）の変換時に、FK 値（customer_id）を
     key_map 経由で新キーに変換してから MERGE

誤った順序で実行すると:
  - 子テーブルの FK 変換時に対応する key_map 行が存在せず、
    NULL になる（または FK 制約違反でエラーになる）
```

- `transform_catalog.sort_order` で「親の key_map 登録・MERGE が完了してから
  子を処理する」という順序を厳密に表現する必要がある。
- `regions` のような複数テーブルから参照されるマスタが代理キー化される場合、
  そのマスタの `key_map` 確定が他の全テーブルより先行する必要がある
  （依存グラフのトポロジカルソートに相当する設計が必要になる）。

### 7.8 リスク

| リスク | 内容 | 緩和策 |
|--------|------|--------|
| 採番の非決定論化 | SEQUENCE.NEXTVAL を直接 INSERT に使うと再実行で値がずれる | key_map による対応関係の固定化（7.5）を必ず実施する |
| 適用順序の誤り | 親の key_map 確定前に子を変換し、FK が解決できない | sort_order を厳密に設計し、依存関係のテストケースを用意する |
| 自然キーの変更 | STAGING 側で自然キー自体が変更される（本来あってはならないが、レガシーでは起こりうる） | UNIQUE 制約違反を検知し、エラーログに記録して個別対応する運用を用意する |
| key_map の肥大化 | 削除されたレコードの対応関係を保持し続けることでテーブルが増大する | パーティショニングやアーカイブ方針を運用設計で検討する |
| 複数ドメイン間の採番競合 | 異なる業務ドメインで同じ代理キー値域を使ってしまう | `domain` 列で名前空間を分離し、ドメインごとに独立した SEQUENCE を用意する |

---

## 8. アーキタイプ7a: SCD（緩やかに変化する次元）/ 履歴化

### 8.1 定義

マスタデータの変更履歴を保持しながら、現在値（最新値）も参照可能にする変換。
データウェアハウス領域で言う「SCD（Slowly Changing Dimension）Type 2」に
相当する設計を、移行先システムの履歴テーブルとして構築するパターン。

### 8.2 入力例

`order_status_history`（注文ステータスの変更履歴）や `price_history`
（価格改定履歴）を題材に、TARGET 側で「いつからいつまでこの状態だったか」
を表す履歴テーブル（`valid_from` / `valid_to` を持つ構造）を構築する、
という形が代表例として想定される。

### 8.3 変換ロジック方針

```
方針1: STAGING の履歴テーブルをそのまま履歴として引き継ぐ（構造変換のみ）
   → 列マッピング・型変換のみで完結する場合は LIGHT_TRANSFORM に近い

方針2: STAGING の「現在値」のスナップショットの差分から履歴を生成する
   → 変換バッチの実行のたびに「前回スナップショットとの差分」を検出し、
     変化があれば旧レコードの valid_to を確定し、新レコードを valid_from から開始する
```

擬似コード（方針2: 差分検出による履歴追加）:

```sql
-- 現在の「有効な」TARGET 履歴行と STAGING の最新値を比較し、変化があれば
-- 旧行を終了させ、新しい履歴行を追加する
MERGE INTO target_schema.customer_status_history t
USING (
    SELECT
        s.customer_id,
        s.status                          AS new_status,
        :v_transform_run_at               AS change_detected_at
    FROM staging_schema.customers s
    WHERE s.updated_at > :v_last_transform_at
) src
ON (t.customer_id = src.customer_id AND t.valid_to IS NULL)  -- 現在有効な行
WHEN MATCHED AND t.status != src.new_status THEN
    UPDATE SET t.valid_to = src.change_detected_at  -- 旧行を終了させる
;
-- (別途、終了させた行に対応する「新しい有効行」を INSERT する2段階処理が必要)
```

> **注記**: 1本の MERGE 文で「旧行の終了」と「新行の追加」を同時に行うのは
> 困難なため、(a) 旧行を終了させる UPDATE/MERGE と (b) 新行を追加する
> INSERT の2段階処理になるのが一般的。この2段階を1トランザクション内で
> 一貫して実行する設計が必要。

### 8.4 12c 互換の実装手段

| 手段 | 互換性 | 備考 |
|------|--------|------|
| `valid_from` / `valid_to`（DATE または TIMESTAMP）による有効期間表現 | バージョン非依存 | SCD Type 2 の標準的な実装方法 |
| `MERGE` + 追加 `INSERT` の2段階処理 | バージョン非依存 | |
| Flashback Data Archive（FDA） | 11g 以降で利用可だが、ライセンス・運用要件を要確認 | 本設計では採用を見送り、テーブルベースの履歴化を基本とする |

### 8.5 冪等性（MERGE）の効かせ方

- 「変化検出 → 履歴追加」は本質的に状態遷移を伴うため、素朴な MERGE の
  冪等性だけでは不十分。**同じ変換バッチを2回実行しても履歴行が重複しない**
  ようにする工夫が必要。
- 対策: 履歴行の論理キーに「変化を検出した基準時刻（`change_detected_at`）」
  ではなく、**STAGING 側の決定論的な値**（例: `staging_updated_at` や
  `commit_scn`）を使う。これにより、同じ STAGING 状態から再実行しても
  同じ履歴行（同じキー）が生成され、MERGE の ON 句で重複を防げる。

```sql
-- 履歴行の論理キーを (customer_id, src_updated_at) のように
-- STAGING 側の決定論的な値で構成する
ON (t.customer_id = src.customer_id AND t.src_updated_at = src.staging_updated_at)
```

### 8.6 DELTA 増分での扱い

- STAGING 側の履歴テーブル（`order_status_history` 等）が既に履歴構造を
  持っている場合、変換は「型変換・列マッピングのみ」で完結することが多く、
  実質的に LIGHT_TRANSFORM に近い扱いになる（このケースは
  `transform_catalog` 上は HEAVY ではなく LIGHT に分類されうる）。
- 一方、STAGING に「現在値」しかなく、TARGET 側で履歴化が必要な場合
  （方針2）は、**変換バッチの実行間隔の間に複数回変化した場合に、
  中間状態の履歴が失われる**という固有の課題がある。
  - 例: ある顧客のステータスが ACTIVE → SUSPENDED → ACTIVE と短時間で
    2回遷移した場合、変換バッチが「最新値（ACTIVE）」しか見えなければ、
    SUSPENDED だった期間の履歴が欠落する。
  - これを防ぐには、STAGING 側に変更の都度の履歴が残っている必要がある
    （= LogMiner の SQL_REDO から生成された変更ログを履歴の元データとして
    使う等、変換層より手前の層で履歴を保持する設計が必要）。
- **結論**: 「現在値からの履歴生成（方針2）」は継続的 CDC 環境では
  本質的に不完全になりうる。履歴が業務上重要な要件であれば、
  **STAGING 側、または delta_apply 層で変更履歴を保持する設計**を
  優先的に検討すべきである（変換層だけで解決しようとしない）。

### 8.7 FK・適用順の注意

- 履歴テーブルは対象エンティティ（customers 等）の後に変換する
  （対象エンティティの代理キーが確定している必要がある場合）。

### 8.8 リスク

| リスク | 内容 | 緩和策 |
|--------|------|--------|
| 中間状態の履歴欠落 | バッチ間隔の間の複数回変化を捉えられない | 8.6 の通り、履歴の情報源を変換層より手前に置く設計を検討する |
| 履歴行の重複生成 | 再実行のたびに同じ変化を新しい履歴行として記録してしまう | 8.5 の通り、決定論的な論理キーで MERGE する |
| valid_to の更新漏れ | 旧行を終了させ忘れ、複数の「現在有効な行」が併存する | UNIQUE 制約（`customer_id` かつ `valid_to IS NULL`）で防御する（部分一意索引等の設計を検討） |

---

## 9. アーキタイプ7b: 行→列ピボット／列→行アンピボット

### 9.1 定義

- **ピボット**: 複数行に分散した値を、1行の複数列に集約する変換
  （例: カテゴリ別の月次売上を「カテゴリごとの列」を持つ1行にまとめる）。
- **アンピボット**: 1行の複数列に格納された値を、複数行に展開する変換
  （例: `customers` の `email` / `phone` のような複数の連絡先列を、
  `customer_contact` の複数行として展開する。これはアーキタイプ3
  「正規化分割」とも重なる側面を持つ）。

### 9.2 入力例

- ピボット: `order_items` と `product_categories` を結合し、
  顧客ごとに「カテゴリA売上, カテゴリB売上, ...」という列を持つ
  レポート用テーブルを生成する、という形が代表例として想定される。
- アンピボット: `customers` の連絡先関連の複数列を `customer_contact`
  の行集合に展開する（4章の例と同型）。

### 9.3 変換ロジック方針（ピボット）

Oracle 11g 以降では `PIVOT` 句が使用できるが、列の集合（カテゴリ一覧）が
事前に確定していない場合は動的 SQL が必要になり複雑化する。
集計対象の集合が決定論的に確定できることが前提となる。

```sql
-- 静的 PIVOT の例（カテゴリが固定列挙できる場合）
SELECT *
FROM (
    SELECT o.customer_id, pc.category_name, oi.quantity * oi.unit_price AS amount
    FROM staging_schema.order_items oi
    JOIN staging_schema.orders o          ON o.order_id = oi.order_id
    JOIN staging_schema.products p        ON p.product_id = oi.product_id
    JOIN staging_schema.product_categories pc ON pc.category_id = p.category_id
)
PIVOT (
    SUM(amount)
    FOR category_name IN ('ELECTRONICS' AS electronics, 'APPAREL' AS apparel, 'OTHER' AS other)
);
```

カテゴリが可変の場合は、`PIVOT` ではなく条件付き集計
（`SUM(CASE WHEN category_name = 'ELECTRONICS' THEN amount END)`）の方が
保守しやすく、決定論性も保ちやすい。

### 9.4 変換ロジック方針（アンピボット）

```sql
-- UNION ALL による列→行展開（アーキタイプ3 4.3 節と同型）
SELECT customer_id, 'EMAIL' AS attr_type, email AS attr_value FROM staging_schema.customers WHERE email IS NOT NULL
UNION ALL
SELECT customer_id, 'PHONE', phone FROM staging_schema.customers WHERE phone IS NOT NULL;
```

### 9.5 12c 互換の実装手段

| 手段 | 互換性 | 備考 |
|------|--------|------|
| `PIVOT` / `UNPIVOT` 句 | 11g 以降で利用可 | 12c で問題なく利用可能。ただし列集合が固定されている必要あり |
| 条件付き集計（`CASE WHEN` + 集計関数） | バージョン非依存 | 列集合が可変、または PIVOT を避けたい場合の代替 |
| `UNION ALL` | バージョン非依存 | アンピボットの基本パターン |
| 動的 SQL（`EXECUTE IMMEDIATE`） | 利用可だが推奨しない | 列集合が実行時に変わる場合に必要だが、決定論性・保守性の観点で複雑化を招く |

### 9.6 冪等性・DELTA増分での扱い

- ピボットパターンは、本質的に「アーキタイプ4: 集約/ロールアップ」の
  特殊形（集計結果を列方向に展開したもの）であるため、DELTA 増分での
  難所は5.6節と同様（影響キー単位の全体再集計を推奨）。
- アンピボットパターンは、本質的に「アーキタイプ3: 正規化分割」と同型
  （1テーブルの更新が分割先に収まるため、波及範囲の特定は比較的容易）。
- **列集合が可変の場合の固有リスク**: ピボット対象のカテゴリ等が
  STAGING 側で増減すると、TARGET 側の列構成（テーブル定義）にまで
  影響する可能性がある。これは「データの変換」の範疇を超えて
  「スキーマの変更」を要求するため、変換層だけでは対応しきれない
  （DDL 変更を伴う運用が必要になる）。可能な限り、列集合が決定論的に
  確定できる設計（条件付き集計による疑似ピボット等）を選好すべきである。

### 9.7 FK・適用順の注意

ピボットは集約系（アーキタイプ4）、アンピボットは分割系（アーキタイプ3）
と同様の依存関係になる。各章の該当節を参照。

### 9.8 リスク

| リスク | 内容 | 緩和策 |
|--------|------|--------|
| 列集合の可変性 | カテゴリ等の値集合が増減し、TARGET の列構成に影響する | 条件付き集計＋固定列リストを基本とし、列追加が必要な場合は別途 DDL 変更手順を運用に組み込む |
| PIVOT の動的 SQL 化による複雑性増 | 動的に列を生成しようとして決定論性・保守性が低下する | 可能な限り静的な列リストで設計し、動的化は最終手段とする |
| アンピボットの重複行 | UNION ALL の条件設計ミスで同一値が複数回展開される | 各 SELECT の WHERE 条件を相互排他にする、または論理キーの UNIQUE 制約で防御する |

---

## 10. まとめ: ニアリアルタイム継続CDC下での HEAVY 変換の横断的課題

最終ゴールは「初期ダンプ後、LogMiner 差分を継続供給し TARGET をほぼリアルタイムに
変換し続ける」運用である。この継続運用下で、各 HEAVY パターンは
「DELTA 増分での扱い」の観点で共通する構造的難所を抱えている。
横断的に整理すると、以下の3つの論点に集約される。

### 10.1 論点1: 「片側だけ変更されたとき」の再計算範囲（影響波及）の特定

| アーキタイプ | 片側変更の典型例 | 波及範囲特定の難易度 | 推奨方針 |
|------------|----------------|-------------------|---------|
| 2. 非正規化JOIN | 参照テーブル（regions）だけが変わる | 中（参照テーブルの更新頻度に依存） | 参照側 updated_at も MERGE 条件に含める（3.6 方針A） |
| 4. 集約/ロールアップ | 明細（order_items）の一部だけが変わる | 高（影響キーの特定とその範囲の全件再集計が必要） | 影響キー単位の全体再集計＋洗い替え（5.6 方針A） |
| 5. コード値マッピング | マッピング表だけが変わる | 高（過去変換済みデータの遡及方針が業務要件次第） | 変換時点のルールで固定し、遡及は別バッチで対応（6.6 方針B＋補正バッチ） |
| 6. 代理キー再マッピング | （通常は片側変更が起こりにくい構造だが）自然キー自体が変わるレアケース | 高（あってはならない事象だが、レガシーでは起こりうる） | UNIQUE 制約違反検知＋個別対応運用（7.8） |
| 7a. SCD/履歴化 | バッチ間隔内に複数回変化する | 高（中間状態の履歴が構造的に失われうる） | 履歴の情報源を変換層より手前（STAGING/delta_apply層）に置く（8.6） |

**横断的な教訓**: 「中心となる入力（中心テーブルの updated_at）だけを見て
差分を判定する」設計は、JOIN・集約・マッピング参照を伴う変換では
**不十分**である。変換に関与する**すべての入力**（参照テーブル・明細・
マッピング表・履歴の元情報）の変化を捕捉できる設計にする必要がある。

### 10.2 論点2: 削除がJOIN/集約結果に与える影響

| アーキタイプ | 削除の影響 | 対応方針 |
|------------|----------|---------|
| 2. 非正規化JOIN | 参照行削除 → インライン化した名称が NULL 化 or 不整合 | LEFT JOIN の NULL 展開を許容するか、削除前値を保持するか業務要件で確定（3.6） |
| 3. 正規化分割 | 親値が NULL/削除 → 子テーブルにゴースト行が残る | MERGE 内 DELETE WHERE 句で子を能動的に削除する（4.5） |
| 4. 集約/ロールアップ | 明細削除 → 集計値の減算が必要 | 全体再集計（方針A）であれば削除後の現在状態から自然に正しい値が得られる（5.6） |
| 6. 代理キー再マッピング | 旧キー削除 → key_map の扱い（保持/削除） | 既定では key_map を保持し代理キーの再利用を避ける（7.6） |

**横断的な教訓**: 「削除」は STAGING → TARGET の単純な行削除だけでなく、
**他の行の集計値・結合結果・履歴に波及する**。削除検知の仕組み
（`docs/phase2-transform-design.md` 6.2節「削除の扱い」）と、
HEAVY 変換の再計算ロジックを連動させる設計が必要になる。

### 10.3 論点3: マッピング表・参照マスタが更新されたときの再変換

これは論点1の特殊形だが、運用上の重要性から独立して扱う。

```
マッピング表・参照マスタの更新は「業務ルールの変更」を意味することが多く、
データの変更（STAGING の差分）とは性格が異なる。

  - 業務ルール変更が「今後の変換にのみ適用される」のか
  - 「過去に変換したデータにも遡及されるべき」なのか

は、技術的な設計判断ではなく業務要件の確認事項である。
```

**推奨運用フロー（提案）:**

```
1. マッピング表・参照マスタの変更は、通常の DELTA 変換とは独立した
   「再変換要求」イベントとして扱う
2. 影響ドメイン・影響範囲を特定するための専用クエリ／プロシージャを用意する
   （例: 「ORDER_STATUS ドメインに関連する全注文を再変換対象として抽出する」）
3. 再変換は通常の DELTA バッチとは別枠で（例えば夜間バッチ等で）実行し、
   通常運用への影響を限定する
4. 再変換の実行履歴も migration_run_log に記録し、追跡可能にする
   （run_name に 'RECALC_' 等のプレフィックスを付与する等）
```

### 10.4 総括: HEAVY変換とニアリアルタイムCDCの相性に関する設計上の指針

1. **「中心テーブルの updated_at だけを見る」設計は HEAVY 変換では破綻しうる**。
   関与する全入力の変化を捕捉する設計（複合的な差分検出条件）が必須。
2. **「全体再計算 ＋ 冪等な洗い替え（MERGE）」を基本線とする**。
   差分加減算は実装が軽量に見えるが、決定論性・冪等性の保証が難しく、
   誤差の蓄積という致命的なリスクを抱える。
3. **再計算範囲が広すぎる場合は、「定期バッチの間隔調整」と「影響キー特定の
   精緻化」のトレードオフで調整する**。完璧な最小範囲特定を最初から
   目指すのではなく、まず広めの範囲で正しく動くものを作り、性能課題が
   顕在化した箇所から最適化する、という段階的アプローチが現実的。
4. **「履歴」「マッピング遡及」など、変換層だけでは原理的に解決できない
   要件は、変換層より手前（STAGING/delta_apply層）または業務運用フロー側に
   解決を委ねる設計判断が必要**になる場合がある。これを変換層の責務の
   範囲外として明確に切り分けることも、設計上重要な判断である。

---

## 11. フレームワーク（transform_catalog / pkg_transform）に不足している拡張点

`docs/phase2-transform-design.md` で定義した現行フレームワークは
PASS_THROUGH / LIGHT_TRANSFORM の運用、および HEAVY_TRANSFORM の
「単一中心テーブル・単一 updated_at 条件」での差分検出を前提としている。
本書で整理した HEAVY アーキタイプを実装するには、以下の拡張が必要になると
見込まれる。

| # | 拡張点 | 必要性の理由 | 関連アーキタイプ |
|---|--------|------------|----------------|
| 1 | `transform_catalog` への「複合差分条件」表現の追加（参照テーブル・関連テーブルの updated_at も条件に含める設定） | 中心テーブルの updated_at だけでは検出できない変更を捕捉するため | 2, 4 |
| 2 | 「影響キー特定クエリ」をメタデータとして登録する仕組み（または専用プロシージャの命名規則の標準化） | 集約・JOIN 系で再計算範囲を特定するロジックを一元管理するため | 2, 4 |
| 3 | `code_mapping` / `key_map` 等のメタデータテーブルの標準スキーマ定義とカタログ登録（変換テーブルとは別の「参照データ」として管理） | コード変換・代理キー変換を横展開する際に二重設計を避けるため | 5, 6 |
| 4 | 親子関係（1→N分割）を表現する `transform_catalog` の拡張（同一変換ステップ内のサブステップ順序を表現する列、または親子関係を示す自己参照列） | 正規化分割で「同一プロシージャ内の順序保証」を一般化するため | 3 |
| 5 | 「再変換要求」（マッピング変更等による遡及再変換）をログ・実行管理できる仕組み（`migration_run_log` への run種別の追加、影響範囲を限定実行するインターフェース） | 10.3 の推奨運用フローを実現するため | 5, 6 |
| 6 | 履歴テーブル（SCD）向けの共通ユーティリティ（`pkg_transform_util` への valid_from/valid_to 操作関数の追加） | 履歴化パターンの実装を標準化するため | 7a |
| 7 | CLOB/JSON 文字列解析の共通関数（`pkg_transform_util` への `extract_json_string` 等の追加） | 半構造化データ分解を複数テーブルで再利用するため | 1 |
| 8 | LOB（CLOB/BLOB）を含む行のバッチ処理方針の確立（G13 のフォールバック設計との統合） | LOB 列を含む `customers.avatar_image` / `customers.remarks` / `orders.shipping_address` 等の扱いを明確にするため | 1（および全般） |
| 9 | 「決定論的な期間境界・基準点」の標準化（集計・ピボットで使う期間の確定方法を共通関数化） | 集計系アーキタイプで決定論性を保証するため | 4, 7b |

---

## 12. 実装フェーズで業務ルール確定が必要な点

実際の変換ルールが業務オーナーから開示された段階で、最優先に確認・決定すべき
事項を以下に整理する。これらが未確定のままでは、本書のアーキタイプの
どれに当てはまるかを最終決定できない。

### 必須確認事項（実装着手前に業務オーナーに確認すべきもの）

| # | 確認事項 | 関連アーキタイプ | 確認しないとどうなるか |
|---|---------|----------------|----------------------|
| 1 | `shipping_address`（および他の半構造化データ）の実際の JSON フォーマット（キー名・ネスト有無・配列有無・エンコーディング） | 1 | 正規表現パターンを誤設計し、解析失敗が多発する |
| 2 | 非正規化対象の参照マスタ（regions 等）の更新頻度・改廃方針 | 2 | 影響波及範囲の見積りを誤り、性能設計を誤る |
| 3 | 1→N 分割の具体的な列振り分けルールと、子テーブルの論理キー設計 | 3 | 子テーブルで重複行・キー不整合が発生する |
| 4 | 集約/ロールアップの集計範囲の確定方法（期間の区切り方、対象スコープ） | 4 | 決定論性が保証できず、再実行のたびに結果が変わるリスクがある |
| 5 | コード値マッピングが将来変更される可能性の有無、変更時に過去データへ遡及するか否か | 5 | 6.6 の論点が宙に浮いたまま実装し、運用後に大きな手戻りが発生する |
| 6 | 代理キー採番の既存実績の有無（新システム側で既に一部運用が始まっている場合の整合方針） | 6 | key_map の初期化方針を誤り、既存運用とキーが衝突する |
| 7 | 履歴化（SCD）が要件に含まれるか、含まれる場合は中間状態（バッチ間隔内の複数回変化）の扱い | 7a | 8.6 の通り、変換層だけでは構造的に対応できない要件である可能性がある |
| 8 | 削除データの扱い（論理削除 / 物理削除、TARGET への伝播要否、関連する集計・結合結果への波及範囲） | 全般（特に 2, 3, 4） | 削除伝播の設計（`docs/phase2-transform-design.md` 6.2節）と HEAVY 変換の再計算ロジックの連動方針が決まらない |
| 9 | LOB 列（avatar_image, remarks, shipping_address 等）の TARGET 側での扱い（そのまま引き継ぐか、加工・分解するか） | 1（および G13 全般） | LOB フォールバック設計（G13）との統合方針が決まらず、変換バッチの設計に影響する |
| 10 | 変換失敗時の許容範囲（1件のエラーで全体を止めるか、エラー行をスキップして継続するか。アーキタイプ・テーブルごとに方針が異なりうるか） | 全般 | `migration_error_log` の記録方針・再実行方針が固まらない |

### 確認後にただちに着手できる準備作業

上記の業務ルールが確定する前でも、以下は本書の設計を土台に先行着手できる。

```
- transform_catalog / code_mapping / key_map のテーブル定義（DDL）の準備
- pkg_transform_util への共通関数（extract_json_string, safe_to_date 等）の雛形実装
- 影響キー特定クエリのテンプレート化（5.6 / 3.6 のパターンを一般化）
- テストデータ生成（data-generator）への HEAVY 変換検証用パターンの追加検討
  （JSON 文字列を含む shipping_address のバリエーション、
    マッピング未定義値、参照先削除等の異常系シナリオ）
```

これらは「実際の変換ルールがどれであっても」必要になる共通基盤であるため、
ルール開示を待たずに準備を進めることで、ルール確定後の実装リードタイムを
短縮できる。
