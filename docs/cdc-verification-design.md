# CDC検証設計書

## 1. 目的と位置付け

本番Oracleデータベース移行における **「初期スナップショット（サブバックアップ）＋redo logベースCDC（継続同期）」** 方式の動作・設計を検証する。

### 移行全体フローにおける位置付け

```
[本設計の対象]
  ┌──────────────────────────────────────────────────────┐
  │  Phase A: 初期スナップショット（サブバックアップ）        │
  │    → 移行元から移行先へ特定SCN時点の全データを一括コピー  │
  │                                                      │
  │  Phase B: redo log CDC（継続同期）                    │
  │    → スナップショット取得後の差分をredo logで継続適用     │
  └──────────────────────────────────────────────────────┘
           ↓ CDCを停止して切り替え
  [既存設計書 migration-design.md の対象]
       スキーマ変換移行（型変換・列構成変更等）

```

本設計では、スキーマ変換前の「同構造テーブル間での完全同期確立」を検証する。

---

## 2. アーキテクチャ

### 構成方針

PDBレベルでの完全分離を確保するため、**2コンテナ構成**を採用する。  
Oracle 21c XEのPDB数制限（最大1ユーザーPDB）を回避し、2つの独立したOracle instanceとして動作させることで、本番環境（2つの独立したOracle DBサーバー間の移行）に近い構成を実現する。

```
┌───────────────────────────────────────────────────────────────────┐
│ Docker Network: cdc-migration-net                                  │
│                                                                    │
│  ┌──────────────────────┐    ┌──────────────────────┐             │
│  │  oracle-src          │    │  oracle-tgt          │             │
│  │  Oracle 21c XE       │    │  Oracle 21c XE       │             │
│  │  CDB: XE             │    │  CDB: XE             │             │
│  │  PDB: SRCPDB1        │    │  PDB: TGTPDB1        │             │
│  │  port: 1521 (host)   │    │  port: 1522 (host)   │             │
│  │                      │    │                      │             │
│  │  src_schema          │    │  tgt_schema          │             │
│  │  cdc_schema          │    │  (移行先テーブル群)   │             │
│  │  (移行元テーブル群)   │    │                      │             │
│  └──────┬───────┬───────┘    └──────────┬───────────┘             │
│         │       │ redo log読み取り         │ DML適用                │
│         │       └──────────────┬──────────┘                       │
│         │ DML発行              │                                   │
│         │            ┌─────────▼──────────────────────────────┐   │
│         │            │  CDCプロセス（oracle-src内 PL/SQL）      │   │
│         │            │  PKG_CDC_SNAPSHOT: 初期スナップショット  │   │
│         │            │  PKG_CDC_LOGMINER: redo log→DBリンク適用 │   │
│         │            └────────────────────────────────────────┘   │
│         │                                                          │
│  ┌──────▼──────────────────────────────────────────────────────┐  │
│  │  data-generator（Pythonコンテナ）                            │  │
│  │  python-oracledb で oracle-src に接続                        │  │
│  │  継続的にsrc_schemaへDMLを発行（強度切替: LOW/MEDIUM/HIGH）   │  │
│  └─────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────┘
```

### コンポーネント役割

| コンポーネント | 役割 |
|--------------|------|
| oracle-src | 移行元DB。redo log生成元。CDC_SCHEMAでCDC状態管理 |
| oracle-tgt | 移行先DB。CDCプロセスがDMLを適用する対象 |
| CDCプロセス | oracle-src上のPL/SQLパッケージ。LogMiner→DBリンク経由でoracle-tgtに適用 |
| data-generator | **Pythonコンテナ**（python-oracledb使用）。oracle-srcへ継続的にDMLを発行 |

### 接続情報

Oracle XE 21c コンテナはデフォルトで `XEPDB1` という名前の PDB を作成する。  
設計書中の SRCPDB1 / TGTPDB1 はホスト名で区別する（コンテナ間通信では `oracle-src` / `oracle-tgt` がそれぞれ対応）。

| 接続先 | サービス名 | ホスト（コンテナ内） | ホスト（ホスト側） | ポート |
|--------|-----------|--------------------|--------------------|--------|
| oracle-src CDB | XE | oracle-src | localhost | 1521 |
| oracle-src PDB | XEPDB1 | oracle-src | localhost | 1521 |
| oracle-tgt CDB | XE | oracle-tgt | localhost | 1522 |
| oracle-tgt PDB | XEPDB1 | oracle-tgt | localhost | 1522 |

---

## 3. ソーススキーマ設計（SRC_SCHEMA @ oracle-src）

### テーブル一覧とDMLパターン

| # | テーブル名 | 用途 | DMLパターン | 特殊要素 |
|---|-----------|------|------------|---------|
| 1 | REGIONS | 地域マスタ | INSERT/UPDATE | 自己参照FK |
| 2 | PRODUCT_CATEGORIES | 商品カテゴリ | INSERT/UPDATE | 自己参照FK、BLOB、CLOB |
| 3 | CUSTOMERS | 顧客マスタ | INSERT/UPDATE/DELETE | BLOB（avatar）、CLOB（remarks）、FK→REGIONS |
| 4 | PRODUCTS | 商品マスタ | INSERT/UPDATE（論理削除） | BLOB（thumbnail）、CLOB×2、FK→PRODUCT_CATEGORIES |
| 5 | ORDERS | 注文ヘッダ | INSERT/UPDATE/DELETE | CLOB（住所JSON）、FK→CUSTOMERS/REGIONS |
| 6 | ORDER_ITEMS | 注文明細 | **INSERT ONLY** | 複合UK、FK→ORDERS/PRODUCTS |
| 7 | CUSTOMER_CONTRACTS | 顧客契約書 | INSERT/UPDATE/DELETE | BLOB×2（PDF/署名）、CLOB（契約文書） |
| 8 | ORDER_STATUS_HISTORY | 注文ステータス履歴 | **INSERT ONLY** | RANGE PARTITION（月次）、FK→ORDERS |
| 9 | PRICE_HISTORY | 価格変更履歴 | **INSERT ONLY** | FK→PRODUCTS |
| 10 | SYSTEM_EVENTS | システムイベント | **INSERT ONLY** | CLOB（JSON payload）、FKなし（独立） |

### ER関連図

```
REGIONS（自己参照: parent_region_id）
  ├── CUSTOMERS.region_id
  │     ├── ORDERS.customer_id
  │     │     ├── ORDER_ITEMS.order_id ──→ PRODUCTS
  │     │     ├── ORDER_STATUS_HISTORY.order_id
  │     └── CUSTOMER_CONTRACTS.customer_id
  └── ORDERS.shipping_region_id

PRODUCT_CATEGORIES（自己参照: parent_category_id）
  └── PRODUCTS.category_id
        ├── ORDER_ITEMS.product_id
        └── PRICE_HISTORY.product_id

SYSTEM_EVENTS（独立、FK参照なし）
```

---

### テーブル詳細定義

#### 1. REGIONS（地域マスタ）

```sql
CREATE TABLE src_schema.regions (
    region_id        NUMBER(6)      NOT NULL,
    region_code      VARCHAR2(10)   NOT NULL,
    region_name      VARCHAR2(100)  NOT NULL,
    parent_region_id NUMBER(6),                          -- 自己参照FK（NULLは最上位）
    display_order    NUMBER(4)      DEFAULT 0,
    is_active        NUMBER(1)      DEFAULT 1 NOT NULL,  -- 1:有効 0:無効
    created_at       TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at       TIMESTAMP,
    CONSTRAINT pk_regions        PRIMARY KEY (region_id),
    CONSTRAINT uq_regions_code   UNIQUE (region_code),
    CONSTRAINT fk_regions_parent FOREIGN KEY (parent_region_id)
                                 REFERENCES src_schema.regions(region_id),
    CONSTRAINT ck_regions_active CHECK (is_active IN (0, 1))
);
-- DMLパターン: INSERT/UPDATE（DELETEなし、is_activeで論理削除）
-- CDC検証観点: 自己参照FK適用順序（親→子の適用順序制御が必要）
```

#### 2. PRODUCT_CATEGORIES（商品カテゴリマスタ）

```sql
CREATE TABLE src_schema.product_categories (
    category_id        NUMBER(10)    NOT NULL,
    category_code      VARCHAR2(20)  NOT NULL,
    category_name      VARCHAR2(200) NOT NULL,
    parent_category_id NUMBER(10),                           -- 自己参照FK
    depth_level        NUMBER(3)     DEFAULT 1 NOT NULL,     -- 階層深さ（1=ルート）
    display_order      NUMBER(4)     DEFAULT 0,
    is_active          NUMBER(1)     DEFAULT 1 NOT NULL,
    icon_image         BLOB,                                  -- カテゴリアイコン画像
    description        CLOB,                                  -- カテゴリ説明文
    created_at         TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at         TIMESTAMP,
    CONSTRAINT pk_product_categories      PRIMARY KEY (category_id),
    CONSTRAINT uq_product_categories_code UNIQUE (category_code),
    CONSTRAINT fk_product_categories_prnt FOREIGN KEY (parent_category_id)
                                          REFERENCES src_schema.product_categories(category_id),
    CONSTRAINT ck_prod_cat_active         CHECK (is_active IN (0, 1)),
    CONSTRAINT ck_prod_cat_depth          CHECK (depth_level BETWEEN 1 AND 10)
);
-- DMLパターン: INSERT/UPDATE（DELETEなし）
-- CDC検証観点: BLOB/CLOBを含む行のredo log記録精度
```

#### 3. CUSTOMERS（顧客マスタ）

```sql
CREATE TABLE src_schema.customers (
    customer_id    NUMBER(12)    NOT NULL,
    customer_code  VARCHAR2(20)  NOT NULL,
    company_name   VARCHAR2(300),
    last_name      VARCHAR2(100) NOT NULL,
    first_name     VARCHAR2(100) NOT NULL,
    email          VARCHAR2(255) NOT NULL,
    phone          VARCHAR2(20),
    region_id      NUMBER(6),                              -- FK→REGIONS
    credit_limit   NUMBER(15,2)  DEFAULT 0 NOT NULL,
    status         VARCHAR2(20)  DEFAULT 'ACTIVE' NOT NULL,-- ACTIVE/SUSPENDED/CLOSED
    avatar_image   BLOB,                                   -- プロフィール画像
    remarks        CLOB,                                   -- 備考（長文テキスト）
    created_at     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at     TIMESTAMP,
    created_by     VARCHAR2(100),
    CONSTRAINT pk_customers       PRIMARY KEY (customer_id),
    CONSTRAINT uq_customers_code  UNIQUE (customer_code),
    CONSTRAINT uq_customers_email UNIQUE (email),
    CONSTRAINT fk_customers_rgn   FOREIGN KEY (region_id)
                                  REFERENCES src_schema.regions(region_id),
    CONSTRAINT ck_customers_status CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
    CONSTRAINT ck_customers_credit CHECK (credit_limit >= 0)
);
-- DMLパターン: INSERT/UPDATE/DELETE（物理削除あり）
-- CDC検証観点: DELETE伝播（子テーブルへのCASCADE or 事前削除制御）
```

#### 4. PRODUCTS（商品マスタ）

```sql
CREATE TABLE src_schema.products (
    product_id      NUMBER(12)    NOT NULL,
    product_code    VARCHAR2(50)  NOT NULL,
    product_name    VARCHAR2(500) NOT NULL,
    category_id     NUMBER(10),                             -- FK→PRODUCT_CATEGORIES
    unit_price      NUMBER(12,2)  NOT NULL,
    stock_quantity  NUMBER(10)    DEFAULT 0 NOT NULL,
    weight_kg       NUMBER(8,3),
    is_discontinued NUMBER(1)     DEFAULT 0 NOT NULL,       -- 0:販売中 1:廃番
    thumbnail       BLOB,                                   -- 商品サムネイル画像
    description     CLOB,                                   -- 商品説明文
    spec_json       CLOB,                                   -- スペック情報（JSON文字列）
    created_at      TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at      TIMESTAMP,
    CONSTRAINT pk_products          PRIMARY KEY (product_id),
    CONSTRAINT uq_products_code     UNIQUE (product_code),
    CONSTRAINT fk_products_cat      FOREIGN KEY (category_id)
                                    REFERENCES src_schema.product_categories(category_id),
    CONSTRAINT ck_products_price    CHECK (unit_price > 0),
    CONSTRAINT ck_products_stock    CHECK (stock_quantity >= 0),
    CONSTRAINT ck_products_discon   CHECK (is_discontinued IN (0, 1))
);
-- DMLパターン: INSERT/UPDATE（物理DELETEなし、is_discontinuedで論理削除）
-- CDC検証観点: 複数CLOB/BLOBを持つ行のredo log記録
```

#### 5. ORDERS（注文ヘッダ）

```sql
CREATE TABLE src_schema.orders (
    order_id           NUMBER(15)    NOT NULL,
    order_no           VARCHAR2(30)  NOT NULL,
    customer_id        NUMBER(12)    NOT NULL,              -- FK→CUSTOMERS
    shipping_region_id NUMBER(6),                           -- FK→REGIONS（配送先地域）
    status             VARCHAR2(30)  DEFAULT 'DRAFT' NOT NULL,
    order_date         DATE          NOT NULL,
    ship_date          DATE,
    delivery_date      DATE,
    total_amount       NUMBER(15,2)  DEFAULT 0 NOT NULL,
    tax_amount         NUMBER(15,2)  DEFAULT 0 NOT NULL,
    shipping_address   CLOB,                                -- 配送先住所（JSON文字列）
    notes              VARCHAR2(2000),
    created_at         TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at         TIMESTAMP,
    CONSTRAINT pk_orders         PRIMARY KEY (order_id),
    CONSTRAINT uq_orders_no      UNIQUE (order_no),
    CONSTRAINT fk_orders_cust    FOREIGN KEY (customer_id)
                                 REFERENCES src_schema.customers(customer_id),
    CONSTRAINT fk_orders_rgn     FOREIGN KEY (shipping_region_id)
                                 REFERENCES src_schema.regions(region_id),
    CONSTRAINT ck_orders_status  CHECK (status IN
                                 ('DRAFT','CONFIRMED','SHIPPED','DELIVERED','CANCELLED')),
    CONSTRAINT ck_orders_amounts CHECK (total_amount >= 0 AND tax_amount >= 0)
);
-- DMLパターン: INSERT → UPDATE（status遷移） → DELETE（キャンセル後物理削除）
-- CDC検証観点: ステータス更新の連続UPDATE、FK依存順のDELETE制御
```

#### 6. ORDER_ITEMS（注文明細）— INSERT ONLY

```sql
CREATE TABLE src_schema.order_items (
    item_id       NUMBER(15)    NOT NULL,
    order_id      NUMBER(15)    NOT NULL,                   -- FK→ORDERS
    product_id    NUMBER(12)    NOT NULL,                   -- FK→PRODUCTS
    line_no       NUMBER(4)     NOT NULL,                   -- 明細行番号
    quantity      NUMBER(10)    NOT NULL,
    unit_price    NUMBER(12,2)  NOT NULL,                   -- 注文時点の価格を記録
    discount_rate NUMBER(5,4)   DEFAULT 0 NOT NULL,         -- 割引率（0.0000〜1.0000）
    line_amount   NUMBER(15,2)  NOT NULL,                   -- quantity * unit_price * (1-discount_rate)
    notes         VARCHAR2(1000),
    created_at    TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_order_items      PRIMARY KEY (item_id),
    CONSTRAINT uq_order_items_line UNIQUE (order_id, line_no),
    CONSTRAINT fk_order_items_ord  FOREIGN KEY (order_id)
                                   REFERENCES src_schema.orders(order_id),
    CONSTRAINT fk_order_items_prd  FOREIGN KEY (product_id)
                                   REFERENCES src_schema.products(product_id),
    CONSTRAINT ck_order_items_qty  CHECK (quantity > 0),
    CONSTRAINT ck_order_items_disc CHECK (discount_rate BETWEEN 0 AND 1)
);
-- DMLパターン: INSERT ONLY（確定後のUPDATE/DELETEなし）
-- CDC検証観点: INSERT ONLYテーブルの冪等性検証（重複INSERT防止）
```

#### 7. CUSTOMER_CONTRACTS（顧客契約書）— BLOB/CLOB重負荷

```sql
CREATE TABLE src_schema.customer_contracts (
    contract_id    NUMBER(15)    NOT NULL,
    customer_id    NUMBER(12)    NOT NULL,                  -- FK→CUSTOMERS
    contract_type  VARCHAR2(50)  NOT NULL,                  -- BASIC/PREMIUM/ENTERPRISE
    contract_no    VARCHAR2(50)  NOT NULL,
    start_date     DATE          NOT NULL,
    end_date       DATE,
    status         VARCHAR2(20)  DEFAULT 'ACTIVE' NOT NULL, -- ACTIVE/EXPIRED/TERMINATED
    contract_text  CLOB,                                    -- 契約書全文テキスト
    contract_pdf   BLOB,                                    -- 契約書PDFバイナリ
    signed_image   BLOB,                                    -- 署名画像バイナリ
    created_at     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at     TIMESTAMP,
    created_by     VARCHAR2(100),
    CONSTRAINT pk_customer_contracts       PRIMARY KEY (contract_id),
    CONSTRAINT uq_customer_contracts_no    UNIQUE (contract_no),
    CONSTRAINT fk_customer_contracts_cust  FOREIGN KEY (customer_id)
                                           REFERENCES src_schema.customers(customer_id),
    CONSTRAINT ck_contracts_status         CHECK (status IN ('ACTIVE','EXPIRED','TERMINATED')),
    CONSTRAINT ck_contracts_dates          CHECK (end_date IS NULL OR end_date > start_date)
);
-- DMLパターン: INSERT/UPDATE/DELETE
-- CDC検証観点: 複数BLOBカラムを含む行の変更をredo logが正確に記録できるか
--              （out-of-line LOBのredo log記録は最重要検証項目）
```

#### 8. ORDER_STATUS_HISTORY（注文ステータス履歴）— INSERT ONLY + RANGE PARTITION

```sql
-- パーティション定義（月次RANGE）
-- 注意: Oracle 12c互換。INTERVAL PARTITIONを使用（12c R1以降で利用可能）
CREATE TABLE src_schema.order_status_history (
    history_id    NUMBER(15)    NOT NULL,
    order_id      NUMBER(15)    NOT NULL,                   -- FK→ORDERS
    from_status   VARCHAR2(30),                             -- 変更前ステータス（NULL=初回）
    to_status     VARCHAR2(30)  NOT NULL,
    changed_by    VARCHAR2(100),
    change_reason VARCHAR2(2000),
    created_at    TIMESTAMP     NOT NULL,
    CONSTRAINT pk_order_status_history     PRIMARY KEY (history_id, created_at),
    CONSTRAINT fk_order_status_history_ord FOREIGN KEY (order_id)
                                           REFERENCES src_schema.orders(order_id)
)
PARTITION BY RANGE (created_at)
INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
(
    PARTITION p_initial VALUES LESS THAN (TIMESTAMP '2026-01-01 00:00:00')
);
-- DMLパターン: INSERT ONLY（追記専用の監査テーブル）
-- CDC検証観点: パーティションテーブルへのINSERT適用、partitionキーを含むredo logエントリ
```

#### 9. PRICE_HISTORY（価格変更履歴）— INSERT ONLY

```sql
CREATE TABLE src_schema.price_history (
    history_id     NUMBER(15)    NOT NULL,
    product_id     NUMBER(12)    NOT NULL,                  -- FK→PRODUCTS
    old_price      NUMBER(12,2),                            -- NULL=初回登録時
    new_price      NUMBER(12,2)  NOT NULL,
    changed_by     VARCHAR2(100),
    effective_date DATE          NOT NULL,
    reason         VARCHAR2(500),
    created_at     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_price_history      PRIMARY KEY (history_id),
    CONSTRAINT fk_price_history_prd  FOREIGN KEY (product_id)
                                     REFERENCES src_schema.products(product_id),
    CONSTRAINT ck_price_history_new  CHECK (new_price > 0)
);
-- DMLパターン: INSERT ONLY
-- CDC検証観点: INSERT ONLYテーブルへの高頻度INSERTのラグ計測
```

#### 10. SYSTEM_EVENTS（システムイベントログ）— INSERT ONLY、FK独立

```sql
CREATE TABLE src_schema.system_events (
    event_id       NUMBER(18)    NOT NULL,
    event_type     VARCHAR2(100) NOT NULL,                  -- 例: ORDER_CREATED, CDC_LAG_ALERT
    source_system  VARCHAR2(100),
    severity       VARCHAR2(10)  DEFAULT 'INFO' NOT NULL,   -- DEBUG/INFO/WARN/ERROR/FATAL
    message        VARCHAR2(4000),
    event_payload  CLOB,                                    -- イベント詳細（JSON文字列）
    created_at     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_system_events     PRIMARY KEY (event_id),
    CONSTRAINT ck_system_events_sev CHECK (severity IN ('DEBUG','INFO','WARN','ERROR','FATAL'))
);
-- DMLパターン: INSERT ONLY（FKなしの完全独立テーブル）
-- CDC検証観点: FKなしテーブルは適用順序が自由→最もシンプルなCDC検証基準として使用
```

### シーケンス・トリガー設計

Oracle 12c互換のためIDENTITY列を使用せず、SEQUENCE + BEFORE INSERT TRIGGERで自動採番する。

```
シーケンス一覧:
  seq_regions                  (regions.region_id)
  seq_product_categories       (product_categories.category_id)
  seq_customers                (customers.customer_id)
  seq_products                 (products.product_id)
  seq_orders                   (orders.order_id)
  seq_order_items              (order_items.item_id)
  seq_customer_contracts       (customer_contracts.contract_id)
  seq_order_status_history     (order_status_history.history_id)
  seq_price_history            (price_history.history_id)
  seq_system_events            (system_events.event_id)

トリガー一覧（各テーブルにBEFORE INSERT）:
  trg_regions_bi
  trg_product_categories_bi
  trg_customers_bi
  trg_products_bi
  trg_orders_bi
  trg_order_items_bi
  trg_customer_contracts_bi
  trg_order_status_history_bi
  trg_price_history_bi
  trg_system_events_bi
```

---

## 4. ターゲットスキーマ設計（TGT_SCHEMA @ oracle-tgt）

CDC検証フェーズでは**ソーススキーマと同一構造**のテーブルを作成する。  
スキーマ変換（型変換・列構成変更）は別フェーズ（migration-design.md参照）で実施。

- テーブル定義はSRC_SCHEMAと完全一致
- シーケンス・トリガーも同一構造で作成
- Supplemental Logging設定はoracle-tgt側には不要

---

## 5. Phase A: 初期スナップショット設計

### 手順概要

```
1. oracle-src側で現在SCNを取得（スナップショット基準時刻の確定）
   SELECT CURRENT_SCN FROM V$DATABASE;  -- → :snapshot_scn

2. スナップショット実行中もDML継続（生産停止なし）

3. 全テーブルを :snapshot_scn 時点のデータとしてoracle-tgtへコピー
   - FK依存順に実施（親テーブルから子テーブルへ）
   - LOBカラムはDBMS_LOBを使用してコピー
   - ORDER_STATUS_HISTORYはパーティション単位で実施

4. コピー完了後、:snapshot_scn をCDC開始SCNとして記録
   → Phase Bはこのscnから開始

5. スナップショット整合性検証
   → 各テーブルの件数比較
   → PKの一致確認
```

### 実行順序（FK依存順）

```
1. REGIONS
2. PRODUCT_CATEGORIES
3. CUSTOMERS
4. PRODUCTS
5. ORDERS
6. ORDER_ITEMS
7. CUSTOMER_CONTRACTS
8. ORDER_STATUS_HISTORY
9. PRICE_HISTORY
10. SYSTEM_EVENTS
```

### 実装: PKG_CDC_SNAPSHOT パッケージ

```
プロシージャ:
  take_snapshot(p_run_name VARCHAR2)
    → snapshot_scnの取得 → 全テーブルコピー（FK依存順） → SCN記録

  copy_table_via_dblink(p_table_name VARCHAR2, p_scn NUMBER)
    → AS OF SCN :p_scn で SELECT → DBリンク経由でINSERT
    → LOBカラムはDBMS_LOBで個別コピー

  verify_snapshot(p_scn NUMBER)
    → 各テーブルの件数照合レポート出力

  get_snapshot_scn RETURN NUMBER
    → 最新のスナップショットSCNを返す（Phase B開始点として使用）
```

---

## 6. Phase B: redo log CDC設計

### Supplemental Logging設定（oracle-src側）

```sql
-- CDB$ROOTレベルで有効化（SYS権限必要）
-- Phase A実行前に設定しておく必要がある

ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
-- → 全カラムの変更前後値をredo logに記録（CDCの正確性に必要）
```

### LogMiner動作フロー

```
1. 前回処理済みSCN（:last_scn）を取得
   → 初回はPhase AのスナップショットSCN

2. DBMS_LOGMNR.ADD_LOGFILE でアクティブなredo logファイルを追加
   （必要に応じてarchive logも追加）

3. DBMS_LOGMNR.START_LOGMNR(
       STARTSCN => :last_scn,
       OPTIONS  => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG
                 + DBMS_LOGMNR.CONTINUOUS_MINE
                 + DBMS_LOGMNR.NO_ROWID_IN_STMT
   )

4. V$LOGMNR_CONTENTSから変更レコードを読み取り
   WHERE SEG_OWNER = 'SRC_SCHEMA'
     AND OPERATION IN ('INSERT','UPDATE','DELETE')
     AND SCN > :last_scn
   ORDER BY SCN, RS_ID, SSN

5. 各レコードのSQL_REDOをoracle-tgt（DBリンク経由）で実行
   → INSERTはそのまま適用
   → UPDATE/DELETEはPK条件で適用
   → LOBカラムは後述の特殊処理

6. DBMS_LOGMNR.END_LOGMNR

7. :last_scn を更新して記録

8. 指定インターバル後に 1. へ戻る
```

### LOBカラムのCDC特殊処理

redo logにLOBの全データがインライン記録されない場合がある（out-of-line LOB）。  
これは本検証の**最重要確認ポイント**。

```
対処方針:
  CASE 1: SQL_REDOにLOB値が含まれる場合
    → そのまま適用

  CASE 2: SQL_REDOにLOB値が含まれない場合（出力がEMPTY_BLOB()等）
    → FLASHBACK QUERYで現在値を取得して適用
       SELECT <lob_column> FROM src_schema.<table>
       AS OF SCN :change_scn WHERE <pk_condition>

  LOBカラムを持つテーブル:
    PRODUCT_CATEGORIES (icon_image BLOB, description CLOB)
    CUSTOMERS          (avatar_image BLOB, remarks CLOB)
    PRODUCTS           (thumbnail BLOB, description CLOB, spec_json CLOB)
    ORDERS             (shipping_address CLOB)
    CUSTOMER_CONTRACTS (contract_text CLOB, contract_pdf BLOB, signed_image BLOB)
    SYSTEM_EVENTS      (event_payload CLOB)
```

### CDC適用順序制御（FK制約対応）

INSERT/UPDATE/DELETEの適用順序をFK依存順に制御する必要がある。

```
INSERT適用順序: 親→子（スナップショットと同じ順）
  1. REGIONS → 2. PRODUCT_CATEGORIES → 3. CUSTOMERS → 4. PRODUCTS
  → 5. ORDERS → 6. ORDER_ITEMS / 7. CUSTOMER_CONTRACTS
  → 8. ORDER_STATUS_HISTORY → 9. PRICE_HISTORY → 10. SYSTEM_EVENTS

DELETE適用順序: 子→親（INSERTの逆順）
  10. SYSTEM_EVENTS → ... → 1. REGIONS

同一SCN内の複数操作:
  → RS_ID + SSN でトランザクション内の操作順序を保持
  → 同一SCN内はSEG_NAME（テーブル名）でFK依存順にソート
```

### 実装: PKG_CDC_LOGMINER パッケージ

```
プロシージャ/ファンクション:
  start_cdc(p_start_scn NUMBER DEFAULT NULL)
    → CDC処理の開始。p_start_scn未指定時はPhase AのSCNから開始
    → DBMS_SCHEDULER JOBを起動

  stop_cdc
    → DBMS_SCHEDULER JOBを停止

  process_batch(p_max_scn NUMBER DEFAULT NULL)
    → 1バッチ分の変更をLogMinerで読み取り→DBリンク経由で適用
    → last_processed_scnを更新

  apply_insert(p_table_name VARCHAR2, p_sql_redo CLOB, p_scn NUMBER)
  apply_update(p_table_name VARCHAR2, p_sql_redo CLOB, p_scn NUMBER)
  apply_delete(p_table_name VARCHAR2, p_sql_redo CLOB, p_scn NUMBER)

  get_cdc_lag RETURN NUMBER
    → 現在の遅延（oracle-srcの最新SCN - last_processed_scn）を返す
```

### CDC制御テーブル（oracle-src側 CDC_SCHEMA）

```sql
-- CDC実行状態管理テーブル
CREATE TABLE cdc_schema.cdc_state (
    state_id         NUMBER(10) NOT NULL,
    snapshot_scn     NUMBER(20) NOT NULL,    -- Phase AのスナップショットSCN
    last_applied_scn NUMBER(20),             -- 最後に適用完了したSCN
    status           VARCHAR2(20) DEFAULT 'IDLE',  -- IDLE/RUNNING/ERROR
    last_run_at      TIMESTAMP,
    error_message    VARCHAR2(4000),
    CONSTRAINT pk_cdc_state PRIMARY KEY (state_id)
);

-- CDCエラーログテーブル
CREATE TABLE cdc_schema.cdc_error_log (
    error_id     NUMBER(15) NOT NULL,
    scn          NUMBER(20),
    table_name   VARCHAR2(100),
    operation    VARCHAR2(20),
    sql_redo     CLOB,
    error_code   NUMBER,
    error_message VARCHAR2(4000),
    occurred_at  TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_cdc_error_log PRIMARY KEY (error_id)
);
```

---

## 7. データジェネレータ設計

### 目的

oracle-src上で継続的にDMLを発行し、CDCの動作検証に必要なworkloadを生成する。

### 構成

**Pythonコンテナ**として実装する。oracle-srcと同一Dockerネットワーク上に配置し、`python-oracledb` ライブラリでoracle-srcに接続する。

```
data-generator/
├── Dockerfile
├── requirements.txt          (python-oracledb, faker, click)
├── generator.py              (メインエントリポイント)
├── workload/
│   ├── customers.py          (顧客DML: INSERT/UPDATE/DELETE + LOB生成)
│   ├── orders.py             (注文DML: ステータス遷移制御)
│   ├── products.py           (商品DML: 価格変更 + PRICE_HISTORY連動)
│   ├── contracts.py          (契約書DML: BLOB/CLOB重負荷)
│   └── events.py             (SYSTEM_EVENTS: 高頻度INSERT)
└── init/
    └── seed_master.py        (初期マスタデータ投入)
```

### 主要モジュール

```
generator.py:
  main(intensity: str = 'MEDIUM')
    → LOW/MEDIUM/HIGH 強度で全ワークロードを並列実行
    → Ctrl+C または SIGTERM で安全停止

customers.py:
  run(conn, batch_size: int)
    → 新規顧客INSERT（30%）: Fakerで氏名/メール生成, avatar_imageにランダムバイナリ
    → 既存顧客UPDATE（50%）: remarks CLOB更新
    → 廃止顧客DELETE（20%）: CLOSED状態の顧客を物理削除

orders.py:
  run(conn, batch_size: int)
    → 新規注文INSERT（DRAFT状態）
    → ステータス遷移UPDATE（DRAFT→CONFIRMED→SHIPPED→DELIVERED）
    → キャンセル処理（ORDER_ITEMSを先に削除 → ORDERS DELETE）

contracts.py:
  run(conn, batch_size: int)
    → 契約書INSERT: contract_pdfにランダムバイナリ(1KB〜100KB)
    → 契約書UPDATE: signed_image更新
    → 期限切れ契約DELETE
```

### ワークロード強度設定

### ワークロード強度設定

| 強度 | 実行間隔 | 1バッチのDML数 | LOB操作 |
|------|---------|--------------|---------|
| LOW | 10秒 | 各テーブル1〜3件 | BLOB 1KB以下 |
| MEDIUM | 5秒 | 各テーブル5〜10件 | BLOB 10KB以下 |
| HIGH | 1秒 | 各テーブル20〜50件 | BLOB 100KB以下 |

---

## 8. DBリンク設計

oracle-srcからoracle-tgtへのデータ適用に使用。

```sql
-- oracle-src CDB$ROOT 上で作成
CREATE DATABASE LINK tgt_db
    CONNECT TO tgt_admin IDENTIFIED BY <password>
    USING '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=oracle-tgt)(PORT=1521))
           (CONNECT_DATA=(SERVICE_NAME=XEPDB1)))';

-- 接続確認
SELECT 1 FROM DUAL@tgt_db;
```

---

## 9. 検証観点

### 9.1 スナップショット整合性

| 検証項目 | 確認方法 |
|---------|---------|
| 全テーブルの件数一致 | COUNT(*) on src vs tgt |
| PK値の完全一致 | MINUS演算子によるPK集合比較 |
| FK整合性 | tgt側でCONSTRAINT ENABLE VALIDATE実行 |
| LOBデータの同一性 | DBMS_LOB.COMPARE でサンプル比較 |

### 9.2 CDC精度（DMLパターン別）

| 検証項目 | 対象テーブル |
|---------|------------|
| INSERT ONLY テーブルの冪等性 | ORDER_ITEMS, ORDER_STATUS_HISTORY, PRICE_HISTORY, SYSTEM_EVENTS |
| UPDATE連続適用の最終値一致 | CUSTOMERS, PRODUCTS, ORDERS |
| DELETE伝播（子→親順制御） | ORDERS（→ORDER_ITEMS→ORDER_STATUS_HISTORYが先に削除されること）|
| LOBカラムの変更反映精度 | CUSTOMER_CONTRACTS（BLOB×2+CLOB） |
| パーティションテーブルへの適用 | ORDER_STATUS_HISTORY |
| 自己参照FK整合性 | REGIONS, PRODUCT_CATEGORIES |

### 9.3 CDC遅延（ラグ）計測

| 計測項目 | 方法 |
|---------|------|
| 平均CDCラグ（秒） | src側DMLのcreated_at vs tgt側適用時刻 |
| LOB操作時の追加遅延 | CUSTOMER_CONTRACTSのLOB操作前後でラグ比較 |
| HIGH負荷時のラグ変化 | gen_workload('HIGH')実行中のラグ推移 |

### 9.4 redo log LOB記録の検証（最重要）

Oracle redo logはout-of-line LOBの変更を完全に記録しない場合がある。  
本検証でFLASHBACK QUERYフォールバックの必要性と有効性を確認する。

```
期待結果:
  - FLASHBACK QUERYフォールバックでLOB変更が正確に適用されること
  - フォールバック発生率をcdc_error_logで計測できること
```

---

## 10. 実装順序

| # | 対象 | 担当設計書 |
|---|------|----------|
| 1 | docker-compose.yml 更新（oracle-src / oracle-tgt / data-generator 3コンテナ構成） | environment-design.md |
| 2 | oracle-src: SRC_SCHEMA DDL（10テーブル + SEQ + TRG） | 本設計書 Section 3 |
| 3 | oracle-tgt: TGT_SCHEMA DDL（同構造） | 本設計書 Section 4 |
| 4 | oracle-src: CDC_SCHEMA + cdc_state/cdc_error_log作成 | 本設計書 Section 6 |
| 5 | oracle-src: Supplemental Logging有効化 | 本設計書 Section 6 |
| 6 | oracle-srcからoracle-tgtへのDBリンク作成 | 本設計書 Section 8 |
| 7 | data-generator Pythonコンテナ作成（Dockerfile + workloadモジュール） | 本設計書 Section 7 |
| 8 | oracle-src: PKG_CDC_SNAPSHOT作成 | 本設計書 Section 5 |
| 9 | oracle-src: PKG_CDC_LOGMINER作成（CONTINUOUS_MINE動作確認込み） | 本設計書 Section 6 |
| 10 | 検証スクリプト（整合性チェック・ラグ計測） | 本設計書 Section 9 |

---

## 11. 未解決事項・リスク

| 項目 | 内容 | 対処方針 |
|------|------|---------|
| LOBのredo log記録範囲 | out-of-line LOBがSQL_REDOに含まれないケースの頻度・条件が不明 | 検証で実測し、FLASHBACK QUERYフォールバックの実装を確定 |
| Oracle XE のarchivelog保持期間 | XEではarchivelogが自動削除される可能性 | CDC処理間隔をarchivelog保持期間内に収める設定を確認 |
| DBリンクでのLOBコピー性能 | DB間LOBコピーは遅延が大きい可能性 | MEDIUM強度での実測後に調整 |
| CONTINUOUS_MINE オプション | Oracle 19c以降でCONTINUOUS_MINEが非推奨。21c XEでの動作が不明 | **まず実際に動作確認する**。動作すればそのまま採用。ORA-エラーが出た場合はオンラインredo logを個別ADD_LOGFILEで追加する方式に切り替え |
