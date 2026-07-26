# 統合移行管理スキーマ設計書（最小コア）

- 作成日: 2026-07-26
- 対象スキーマ: `migration_ctl`（新設）
- 設計範囲: `MIGRATION_RUN` / `PHASE_STATUS` / `MIGRATION_OBJECT` の3テーブル
- 前提文書: `docs/gap-analysis-5phase-schema.md`, `docs/oracle-compatibility-policy.md`

---

## 1. 設計の目的と背景

### 1.1 既存管理体制の問題点

現行の data-transfer 検証環境では、移行管理情報が以下の3スキーマに分散して管理されており、フェーズ横断の統合的な実行追跡が困難な状態にある（`gap-analysis-5phase-schema.md` §3.1）。

| スキーマ | 役割 | 主なテーブル |
|---|---|---|
| `cdc_schema`（移行元側） | 抽出制御 | `cdc_table_catalog`（replay_category分類）, `cdc_state`, `ops_config` |
| `staging_ctl`（移行先側） | CDC適用制御 | `delta_queue`, `apply_ledger`, `delta_apply_state` |
| `log_schema`（移行先側） | 全量移行・変換ログ | `migration_run_log`, `migration_step_log`, `migration_error_log` |

**課題**:

1. **実行を横断する親キーがない**: `log_schema.migration_run_log.run_id` はフェーズ2（全量Import相当）・フェーズ5（変換）のログ専用。フェーズ1のExportジョブ管理やフェーズ3のArchived Redo収集と紐付いていない。CDC側（`cdc_schema` / `staging_ctl`）には「実行ID」という概念が存在しない。

2. **PoC/リハーサル/本番の分離機構がない**: 同一DB間でも実行ごとに状態を分けて追跡できず、過去実行の記録が上書きされるリスクがある。

3. **BASELINE_SCN と MINING_START_SCN が分離されていない**: 現行は単純な `SCN > last_scn` フィルタの単一値のみで管理される。長時間トランザクションが基準断面を跨ぐケース（既存最優先ギャップ G2/G3/G4）への対応がなく、`COMMITTED_DATA_ONLY` オプションも未使用。

### 1.2 今回の解決方針

上記3課題を解消する最小構成として、新スキーマ `migration_ctl` に以下3テーブルを設計する。

| テーブル | 役割 |
|---|---|
| `MIGRATION_RUN` | 全5フェーズ＋先行準備を束ねる実行単位の親キー。`BASELINE_SCN` と `MINING_START_SCN` を別カラムで保持。 |
| `PHASE_STATUS` | 7フェーズ（PREP_A, PREP_B, PHASE1〜PHASE5）の状態・開始終了時刻を追跡。 |
| `MIGRATION_OBJECT` | 移行対象テーブルの台帳。`cdc_schema.cdc_table_catalog` を破壊せず参照可能な形で、移行方式・処理順序・容量見積りを追加保持。 |

**基本方針**:
- 既存テーブル（`log_schema.*`, `cdc_schema.*`, `staging_ctl.*`）は**一切改変しない**（参照のみ）。
- 既存スキーマへのクロススキーマFKは設けない（ソフト参照に留める）。
- 実装は SEQUENCE + BEFORE INSERT トリガー方式のみ（IDENTITY 列禁止）。

---

## 2. スキーマ配置方針

新規スキーマ `migration_ctl` を作成し、本設計の3テーブルをすべてここに置く。

### 既存スキーマとの役割分担

| スキーマ | 管理範囲 | 変更有無 |
|---|---|---|
| `migration_ctl` | **全フェーズ統合管理**（MIGRATION_RUN親キー・フェーズ進捗・対象オブジェクト台帳） | **新設（本設計対象）** |
| `log_schema` | 全量移行バッチのステップ詳細ログ（`migration_run_log` 等） | **変更なし**（参照される側） |
| `cdc_schema` | CDC抽出制御・テーブルカタログ（`cdc_table_catalog` 等） | **変更なし**（参照される側） |
| `staging_ctl` | CDC適用制御（`delta_queue`, `apply_ledger` 等） | **変更なし** |

`migration_ctl` を分離することで、既存実装を一切壊さずに統合管理機能を段階的に追加できる。

---

## 3. テーブル設計仕様

### 命名規約

| 対象 | 規則 | 例 |
|---|---|---|
| テーブル名・カラム名 | 英大文字、アンダースコア区切り | `MIGRATION_RUN`, `MIG_RUN_ID` |
| シーケンス名 | `SEQ_` プレフィックス | `SEQ_MIGRATION_RUN` |
| トリガー名 | `TRG_` プレフィックス + `_BI` サフィックス | `TRG_MIGRATION_RUN_BI` |
| 主キー制約 | `PK_` プレフィックス | `PK_MIGRATION_RUN` |
| 外部キー制約 | `FK_` プレフィックス | `FK_PHASE_STATUS_RUN` |
| UNIQUE制約 | `UQ_` プレフィックス | `UQ_MIGRATION_RUN_NAME` |
| CHECK制約 | `CHK_` プレフィックス | `CHK_MIG_RUN_TYPE` |
| 主キーカラム | `_ID` サフィックス | `MIG_RUN_ID` |

すべての制約名・トリガー名・シーケンス名は Oracle 12.1 の識別子長上限（30文字）以内に収める。

---

### 3.1 MIGRATION_RUN（移行実行親テーブル）

#### 設計意図

全5フェーズ＋先行準備を束ねる実行単位の親キーテーブル。`MIG_RUN_ID` を起点に、フェーズ進捗・対象オブジェクトをすべて参照できる。

**BASELINE_SCN と MINING_START_SCN の設計根拠**（`gap-analysis-5phase-schema.md` §4）:

- `BASELINE_SCN`: Data Pump Export（フェーズ1）取得時のSCN。全量ロードデータはこのSCNを断面として確定する。フェーズ1完了後に設定する。
- `MINING_START_SCN`: LogMiner解析（フェーズ3・4）の開始SCN。`BASELINE_SCN` より過去の値に設定することで、「基準断面を跨いで開始し、断面後に確定した長時間トランザクション」の変更を再構成できる。フェーズ3開始前に設定する。
- 制約: `MINING_START_SCN <= BASELINE_SCN`（両方が設定済みの場合）。

現行実装では `SCN > last_scn` フィルタの単一値のみで管理されており、この2値分離がなかったことが G2/G3/G4 最優先ギャップの根因となっていた。本テーブルはその解消策と直結する。

**RUN_TYPE による実行種別分離**:

| RUN_TYPE | 目的 |
|---|---|
| `POC` | 技術検証・実現可能性確認。本番データは使わない。 |
| `REHEARSAL` | 本番相当データを使ったリハーサル。複数回実施して所要時間を測定。 |
| `PRODUCTION` | 本番移行。`MIG_RUN_ID` を分けることで過去実行の記録が上書きされない。 |

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| MIG_RUN_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| RUN_NAME | VARCHAR2(100) | YES | - | 実行名（例: `2026-Q1-PROD-01`）。UNIQUE制約。 |
| RUN_TYPE | VARCHAR2(20) | YES | - | `POC` / `REHEARSAL` / `PRODUCTION` |
| STATUS | VARCHAR2(20) | YES | `CREATED` | `CREATED` / `RUNNING` / `DONE` / `FAILED` / `ABORTED` |
| BASELINE_SCN | NUMBER(20) | NO | NULL | 全量断面用SCN。フェーズ1完了後に設定。 |
| MINING_START_SCN | NUMBER(20) | NO | NULL | LogMiner解析開始SCN。フェーズ3開始前に設定。`BASELINE_SCN` 以下の値。 |
| STARTED_AT | TIMESTAMP | NO | NULL | 移行実行の開始日時（フェーズ1着手時）。 |
| FINISHED_AT | TIMESTAMP | NO | NULL | 移行完了日時（フェーズ5完了時）。 |
| LOG_RUN_ID | NUMBER(10) | NO | NULL | `log_schema.migration_run_log.run_id` へのソフト参照（FK制約なし）。 |
| REMARKS | VARCHAR2(4000) | NO | NULL | 備考・運用メモ。 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時。 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時（UPDATE時に呼び出し元が設定）。 |

#### DDL（設計ドラフト）

```sql
-- SEQUENCE
CREATE SEQUENCE migration_ctl.SEQ_MIGRATION_RUN
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- TABLE
CREATE TABLE migration_ctl.MIGRATION_RUN (
    MIG_RUN_ID        NUMBER(10)     NOT NULL,
    RUN_NAME          VARCHAR2(100)  NOT NULL,
    RUN_TYPE          VARCHAR2(20)   NOT NULL,
    STATUS            VARCHAR2(20)   DEFAULT 'CREATED' NOT NULL,
    BASELINE_SCN      NUMBER(20),
    MINING_START_SCN  NUMBER(20),
    STARTED_AT        TIMESTAMP,
    FINISHED_AT       TIMESTAMP,
    LOG_RUN_ID        NUMBER(10),
    REMARKS           VARCHAR2(4000),
    CREATED_AT        TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT        TIMESTAMP,
    CONSTRAINT PK_MIGRATION_RUN
        PRIMARY KEY (MIG_RUN_ID),
    CONSTRAINT UQ_MIGRATION_RUN_NAME
        UNIQUE (RUN_NAME),
    CONSTRAINT CHK_MIG_RUN_TYPE
        CHECK (RUN_TYPE IN ('POC', 'REHEARSAL', 'PRODUCTION')),
    CONSTRAINT CHK_MIG_RUN_STATUS
        CHECK (STATUS IN ('CREATED', 'RUNNING', 'DONE', 'FAILED', 'ABORTED')),
    CONSTRAINT CHK_MIG_RUN_SCN
        CHECK (MINING_START_SCN IS NULL
               OR BASELINE_SCN IS NULL
               OR MINING_START_SCN <= BASELINE_SCN)
);

-- BEFORE INSERT TRIGGER（採番）
CREATE OR REPLACE TRIGGER migration_ctl.TRG_MIGRATION_RUN_BI
BEFORE INSERT ON migration_ctl.MIGRATION_RUN
FOR EACH ROW
BEGIN
    IF :NEW.MIG_RUN_ID IS NULL THEN
        SELECT migration_ctl.SEQ_MIGRATION_RUN.NEXTVAL
        INTO :NEW.MIG_RUN_ID FROM DUAL;
    END IF;
END;
/
```

**CHECK制約 `CHK_MIG_RUN_SCN` の意図**:

`MINING_START_SCN <= BASELINE_SCN` を強制するが、両値とも NULL を許容する（フェーズ1・3 完了前の状態）。`BASELINE_SCN` のみ設定済みで `MINING_START_SCN` が NULL の状態（フェーズ1完了後・フェーズ3未着手）も正常として許容する。

---

### 3.2 PHASE_STATUS（フェーズ進捗テーブル）

#### 設計意図

1回の `MIGRATION_RUN` ごとに7フェーズ分のレコードを持ち、各フェーズの状態遷移・開始終了時刻・エラー情報を追跡する。`UQ_PHASE_STATUS_CODE` により1実行につき同一フェーズのレコードは1件のみ保証される。

**フェーズコード定義**:

| PHASE_CODE | フェーズ名 | 概要 |
|---|---|---|
| `PREP_A` | 先行準備A | `migration_ctl` スキーマ・テーブルの最小構築。 |
| `PREP_B` | 先行準備B | Supplemental Logging設定、辞書ビルド（CDB$ROOTで `STORE_IN_REDO_LOGS` 実行）、`V$ARCHIVED_LOG` マーカー確認。 |
| `PHASE1` | 初回全量Export | Data Pump Exportによる全量バックアップ取得・`BASELINE_SCN` 確定。 |
| `PHASE2` | 初回全量Import | Data Pump Importによる移行先（DB2.0）への全量ロード。 |
| `PHASE3` | Archived Redo収集 | アーカイブログ転送・`MINING_START_SCN` 確定。 |
| `PHASE4` | LogMiner解析・差分反映 | LogMiner解析（DB2.0側で `DICT_FROM_REDO_LOGS` 使用）→変更をDB2.0へ適用。 |
| `PHASE5` | 1.0→2.0変換 | 旧スキーマから新スキーマへの変換（型変換・コード変換・アドレス分解等）。 |

**状態遷移**:

```
NOT_STARTED  -->  RUNNING  -->  DONE
                          |
                          +-->  FAILED
```

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| PHASE_STATUS_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | - | FK: `MIGRATION_RUN.MIG_RUN_ID` |
| PHASE_CODE | VARCHAR2(20) | YES | - | フェーズ識別子（後述のCHECK制約参照） |
| STATUS | VARCHAR2(20) | YES | `NOT_STARTED` | `NOT_STARTED` / `RUNNING` / `DONE` / `FAILED` |
| STARTED_AT | TIMESTAMP | NO | NULL | フェーズ開始日時。RUNNING遷移時に設定。 |
| FINISHED_AT | TIMESTAMP | NO | NULL | フェーズ完了日時。DONE/FAILED遷移時に設定。 |
| ERROR_MESSAGE | VARCHAR2(4000) | NO | NULL | エラー内容の要約（FAILED時）。詳細は `log_schema.migration_error_log` を参照。 |
| REMARKS | VARCHAR2(4000) | NO | NULL | 備考（所要時間メモ・手動対応事項等）。 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時。 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時（UPDATE時に呼び出し元が設定）。 |

#### DDL（設計ドラフト）

```sql
-- SEQUENCE
CREATE SEQUENCE migration_ctl.SEQ_PHASE_STATUS
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- TABLE
CREATE TABLE migration_ctl.PHASE_STATUS (
    PHASE_STATUS_ID   NUMBER(10)     NOT NULL,
    MIG_RUN_ID        NUMBER(10)     NOT NULL,
    PHASE_CODE        VARCHAR2(20)   NOT NULL,
    STATUS            VARCHAR2(20)   DEFAULT 'NOT_STARTED' NOT NULL,
    STARTED_AT        TIMESTAMP,
    FINISHED_AT       TIMESTAMP,
    ERROR_MESSAGE     VARCHAR2(4000),
    REMARKS           VARCHAR2(4000),
    CREATED_AT        TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT        TIMESTAMP,
    CONSTRAINT PK_PHASE_STATUS
        PRIMARY KEY (PHASE_STATUS_ID),
    CONSTRAINT FK_PHASE_STATUS_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES migration_ctl.MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT UQ_PHASE_STATUS_CODE
        UNIQUE (MIG_RUN_ID, PHASE_CODE),
    CONSTRAINT CHK_PHASE_STATUS_CODE
        CHECK (PHASE_CODE IN
               ('PREP_A', 'PREP_B', 'PHASE1', 'PHASE2', 'PHASE3', 'PHASE4', 'PHASE5')),
    CONSTRAINT CHK_PHASE_STATUS_STS
        CHECK (STATUS IN ('NOT_STARTED', 'RUNNING', 'DONE', 'FAILED'))
);

-- BEFORE INSERT TRIGGER（採番）
CREATE OR REPLACE TRIGGER migration_ctl.TRG_PHASE_STATUS_BI
BEFORE INSERT ON migration_ctl.PHASE_STATUS
FOR EACH ROW
BEGIN
    IF :NEW.PHASE_STATUS_ID IS NULL THEN
        SELECT migration_ctl.SEQ_PHASE_STATUS.NEXTVAL
        INTO :NEW.PHASE_STATUS_ID FROM DUAL;
    END IF;
END;
/
```

**利用パターン**: `MIGRATION_RUN` レコード作成直後に、7フェーズ分の `PHASE_STATUS` レコードを `NOT_STARTED` で一括挿入する。各フェーズの着手・完了時に STATUS と STARTED_AT / FINISHED_AT を UPDATE する。再実行時は STATUS を `NOT_STARTED` に戻してから再度 `RUNNING` に遷移させる（既存レコードをUPDATEするため再INSERTは不要）。

---

### 3.3 MIGRATION_OBJECT（対象オブジェクト台帳）

#### 設計意図

1回の `MIGRATION_RUN` における移行対象テーブルのカタログ。`cdc_schema.cdc_table_catalog` が保持する `replay_category` 中心の既存設計を**改変せず**、「移行方式（FULL/CDC/TRANSFORM）」「処理順序」「容量見積り」の情報を追加で保持する。

**MIGRATION_METHOD の定義**（移行方式の主分類）:

| MIGRATION_METHOD | 説明 | 対象テーブルの例 |
|---|---|---|
| `FULL` | Data Pump全量ロードのみ（静的参照テーブル等。CDC追跡対象外）。 | 変更が発生しないコードマスタ等 |
| `CDC` | 全量ロード + LogMiner CDC同期（スキーマ変換なし）。 | 構造変更なしのトランザクションテーブル |
| `TRANSFORM` | 全量ロード + CDC同期 + スキーマ変換（フェーズ5対象）。 | 型変換・コード変換・列分割が必要なテーブル |
| `SKIP` | 移行対象外（除外）。 | 一時テーブル・内部管理テーブル等 |

`TRANSFORM` は `CDC` を含意し、`CDC` は `FULL` を含意する（上位メソッドほど下位の処理も行う）。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| MIG_OBJECT_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | - | FK: `MIGRATION_RUN.MIG_RUN_ID` |
| OBJECT_SCHEMA | VARCHAR2(100) | YES | - | 移行元スキーマ名（大文字）。例: `SRC_SCHEMA` |
| OBJECT_NAME | VARCHAR2(100) | YES | - | テーブル名（大文字）。例: `CUSTOMERS` |
| MIGRATION_METHOD | VARCHAR2(20) | YES | - | `FULL` / `CDC` / `TRANSFORM` / `SKIP` |
| PROCESS_ORDER | NUMBER(5) | NO | NULL | 処理順序（小さい値を先に処理。FK依存を考慮した全体順序）。 |
| EST_ROW_COUNT | NUMBER(20) | NO | NULL | 移行前の概算行数見積り。 |
| EST_SIZE_MB | NUMBER(10,2) | NO | NULL | 移行前の概算データサイズ（MB）見積り。 |
| CDC_CATALOG_TABLE_NAME | VARCHAR2(100) | NO | NULL | `cdc_schema.cdc_table_catalog.table_name` へのソフト参照（FK制約なし）。`MIGRATION_METHOD = 'SKIP'` または CDC対象外の場合はNULL。 |
| STATUS | VARCHAR2(20) | YES | `PENDING` | `PENDING` / `IN_PROGRESS` / `DONE` / `FAILED` / `SKIPPED` |
| REMARKS | VARCHAR2(4000) | NO | NULL | 備考（LOB有無・特記事項・前提条件等）。 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時。 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時（UPDATE時に呼び出し元が設定）。 |

#### DDL（設計ドラフト）

```sql
-- SEQUENCE
CREATE SEQUENCE migration_ctl.SEQ_MIGRATION_OBJECT
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- TABLE
CREATE TABLE migration_ctl.MIGRATION_OBJECT (
    MIG_OBJECT_ID          NUMBER(10)     NOT NULL,
    MIG_RUN_ID             NUMBER(10)     NOT NULL,
    OBJECT_SCHEMA          VARCHAR2(100)  NOT NULL,
    OBJECT_NAME            VARCHAR2(100)  NOT NULL,
    MIGRATION_METHOD       VARCHAR2(20)   NOT NULL,
    PROCESS_ORDER          NUMBER(5),
    EST_ROW_COUNT          NUMBER(20),
    EST_SIZE_MB            NUMBER(10,2),
    CDC_CATALOG_TABLE_NAME VARCHAR2(100),
    STATUS                 VARCHAR2(20)   DEFAULT 'PENDING' NOT NULL,
    REMARKS                VARCHAR2(4000),
    CREATED_AT             TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT             TIMESTAMP,
    CONSTRAINT PK_MIGRATION_OBJECT
        PRIMARY KEY (MIG_OBJECT_ID),
    CONSTRAINT FK_MIG_OBJECT_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES migration_ctl.MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT UQ_MIG_OBJECT_NAME
        UNIQUE (MIG_RUN_ID, OBJECT_SCHEMA, OBJECT_NAME),
    CONSTRAINT CHK_MIG_OBJECT_METHOD
        CHECK (MIGRATION_METHOD IN ('FULL', 'CDC', 'TRANSFORM', 'SKIP')),
    CONSTRAINT CHK_MIG_OBJECT_STATUS
        CHECK (STATUS IN ('PENDING', 'IN_PROGRESS', 'DONE', 'FAILED', 'SKIPPED'))
);

-- BEFORE INSERT TRIGGER（採番）
CREATE OR REPLACE TRIGGER migration_ctl.TRG_MIGRATION_OBJECT_BI
BEFORE INSERT ON migration_ctl.MIGRATION_OBJECT
FOR EACH ROW
BEGIN
    IF :NEW.MIG_OBJECT_ID IS NULL THEN
        SELECT migration_ctl.SEQ_MIGRATION_OBJECT.NEXTVAL
        INTO :NEW.MIG_OBJECT_ID FROM DUAL;
    END IF;
END;
/
```

---

## 4. ER図（テキスト表現）

```
┌─────────────────────────────────────────────────────────────────────┐
│ migration_ctl スキーマ（新設）                                       │
│                                                                     │
│  MIGRATION_RUN                                                      │
│  ┌────────────────────────────────┐                                 │
│  │ MIG_RUN_ID        PK           │                                 │
│  │ RUN_NAME          UQ           │                                 │
│  │ RUN_TYPE          POC/REHEARSAL│                                 │
│  │                   /PRODUCTION  │                                 │
│  │ STATUS            CREATED/...  │                                 │
│  │ BASELINE_SCN   ←─フェーズ1後  │                                 │
│  │ MINING_START_SCN ←フェーズ3前 │                                 │
│  │   (≦ BASELINE_SCN)            │                                 │
│  │ LOG_RUN_ID  ─ ─ ─ ─ ─ ─ ─ ─ ─│─ ─ ─► log_schema.              │
│  │ REMARKS                        │        MIGRATION_RUN_LOG        │
│  │ CREATED_AT / UPDATED_AT        │        (既存・改変なし)         │
│  └────────────┬───────────────────┘                                 │
│               │ 1:N FK                                              │
│               ├──────────────────────────────────────────┐          │
│               │ 1:N FK                                   │          │
│               │                                          │          │
│  PHASE_STATUS │                          MIGRATION_OBJECT│          │
│  ┌────────────┴────────────┐         ┌──────────────────┴──┐        │
│  │ PHASE_STATUS_ID  PK     │         │ MIG_OBJECT_ID  PK    │        │
│  │ MIG_RUN_ID       FK     │         │ MIG_RUN_ID     FK    │        │
│  │ PHASE_CODE              │         │ OBJECT_SCHEMA        │        │
│  │  PREP_A / PREP_B        │         │ OBJECT_NAME   UQ     │        │
│  │  PHASE1 〜 PHASE5       │         │  (RUN+SCHEMA+NAME)   │        │
│  │  ※ (RUN_ID,PHASE_CODE) │         │ MIGRATION_METHOD     │        │
│  │   に UNIQUE制約         │         │  FULL/CDC/TRANSFORM  │        │
│  │ STATUS                  │         │  /SKIP               │        │
│  │  NOT_STARTED → RUNNING  │         │ PROCESS_ORDER        │        │
│  │          → DONE/FAILED  │         │ EST_ROW_COUNT        │        │
│  │ STARTED_AT              │         │ EST_SIZE_MB          │        │
│  │ FINISHED_AT             │         │ CDC_CATALOG_TABLE_NAME│        │
│  │ ERROR_MESSAGE           │         │  ─ ─ ─ ─ ─ ─ ─ ─ ─►│─ ─ ─► │
│  └─────────────────────────┘         │ STATUS               │        │
│                                      └──────────────────────┘        │
└─────────────────────────────────────────────────────────────────────┘

                                           cdc_schema.CDC_TABLE_CATALOG
                                           (既存・改変なし)
                                           FK制約なし・ソフト参照

凡例:
  ──┬──   : FK制約あり（migration_ctl スキーマ内）
  ─ ─ ─►  : ソフト参照（FK制約なし・外スキーマへの論理的な対応）
```

---

## 5. 既存テーブルとの関連性

### 5.1 log_schema.migration_run_log との関係

#### 現状の役割

`log_schema.migration_run_log` は `log_schema.pkg_migration.migrate_all` が実行するバッチ移行の実行ログとして機能する。フェーズ5（スキーマ変換）相当の処理ステップ別件数・エラー詳細が `migration_step_log` / `migration_error_log` に記録される。既存実装の中で最も整備されている管理テーブル群。

#### 新設計での位置づけ

`migration_ctl.MIGRATION_RUN` が全フェーズの**統合親キー**となる。`log_schema.migration_run_log` はフェーズ5のバッチ処理ステップ詳細ログとして**そのまま存続**させる（廃止しない）。両テーブルの対応は `MIGRATION_RUN.LOG_RUN_ID` のソフト参照で示す。

`LOG_RUN_ID` はFK制約なしとする理由:
- クロススキーマFKは技術的には可能だが、`log_schema` への依存を `migration_ctl` 側に作ることで、将来 `log_schema` の構造変更時に `migration_ctl` に波及するリスクを避ける。
- 論理的な紐付けの記録が目的であり、参照整合性の強制は必要としない。

#### 段階的移行方針

| 段階 | 方針 |
|---|---|
| 近期（本設計） | `migration_ctl.MIGRATION_RUN` を新設。`log_schema.migration_run_log` は改変しない。バッチ移行実行後に `LOG_RUN_ID` へ対応する `run_id` を手動または自動で記録する。 |
| 中期（将来） | `MIGRATION_RUN.MIG_RUN_ID` を `migration_step_log` / `migration_error_log` から参照できるよう連携強化を検討する。ただし既存テーブルへのカラム追加は別設計として扱う。 |
| 長期（将来） | `log_schema.migration_run_log` の廃止・統合の是非を別途判断する。本設計の範囲外。 |

### 5.2 cdc_schema.cdc_table_catalog との関係

#### cdc_table_catalog の現行設計（改変しない）

`cdc_schema.cdc_table_catalog` は以下の情報を保持する。

| カラム | 意味 |
|---|---|
| `table_name` | 追跡対象テーブル名（PK）。SRC_SCHEMA内のテーブル名。 |
| `replay_category` | 差分適用分類（A: SQL_REDO直接適用候補 / B: STG変換必要 / C: LOB複雑型あり / D: DDLリスクあり） |
| `lob_present` | LOB列有無（Y/N）。SQL_REDO直接適用禁止の判定に使用。 |
| `is_active` | CDC追跡有効フラグ（Y/N）。 |
| `sort_order` | CDC追跡処理順序（cdc_state管理用）。 |
| `baseline_ddl_time` | DDL凍結基準タイムスタンプ。 |

#### MIGRATION_OBJECT での拡張情報

`MIGRATION_OBJECT` は `cdc_table_catalog` に存在しない情報を**追加**で保持する。既存テーブルには追加しない。

| MIGRATION_OBJECT カラム | cdc_table_catalog との差分 |
|---|---|
| `MIGRATION_METHOD` | 全体移行戦略の分類（FULL/CDC/TRANSFORM）。`replay_category` は差分適用の技術分類であり、全量/CDC/変換の区分は持たない。 |
| `PROCESS_ORDER` | 移行処理の全体順序（FK依存を考慮した全体観点）。`sort_order` はCDC追跡処理専用の独立した値。 |
| `EST_ROW_COUNT` / `EST_SIZE_MB` | 移行前の容量見積り。`cdc_table_catalog` には存在しない。 |
| `STATUS` | オブジェクト単位の移行全体の進捗状態。 |
| `MIG_RUN_ID` | 実行単位への紐付け。`cdc_table_catalog` は実行IDの概念を持たない。 |

#### ソフト参照による結合（参照サンプル）

```sql
-- MIGRATION_OBJECT と cdc_table_catalog を結合して移行方式とCDC分類を統合参照する
SELECT
    mo.MIG_OBJECT_ID,
    mo.OBJECT_SCHEMA,
    mo.OBJECT_NAME,
    mo.MIGRATION_METHOD,
    mo.PROCESS_ORDER,
    mo.EST_ROW_COUNT,
    mo.EST_SIZE_MB,
    mo.STATUS,
    ctc.replay_category,
    ctc.lob_present,
    ctc.is_active
FROM migration_ctl.MIGRATION_OBJECT mo
LEFT JOIN cdc_schema.cdc_table_catalog ctc
  ON ctc.table_name = mo.CDC_CATALOG_TABLE_NAME
WHERE mo.MIG_RUN_ID = :mig_run_id
ORDER BY mo.PROCESS_ORDER NULLS LAST, mo.OBJECT_NAME;
```

`CDC_CATALOG_TABLE_NAME` が NULL（FULL専用テーブルやSKIPオブジェクト）の場合、LEFT JOINにより `ctc.*` は NULL になる。CDC対象テーブルのみ `cdc_table_catalog` の情報が付与される。

---

## 6. Oracle 12c 互換性の確認メモ

本設計で使用する機能・構文の互換性を確認する（`oracle-compatibility-policy.md` に基づく）。

| 設計要素 | 12c (12.1) 互換性 | 根拠・備考 |
|---|---|---|
| `SEQUENCE` | ○ | 全バージョンで利用可能。 |
| `BEFORE INSERT` トリガー | ○ | 全バージョンで利用可能。 |
| `IDENTITY` 列 | 使用しない | `oracle-compatibility-policy.md` により禁止。SEQUENCE + トリガー方式を採用。 |
| `TIMESTAMP` 型 | ○ | Oracle 9i 以降で利用可能。デフォルト精度（6桁小数）を使用。 |
| `NUMBER(20)` 型（SCN用） | ○ | NUMBER は全バージョン標準。SCN値は整数のため SCALE なし。 |
| `NUMBER(10,2)` 型（サイズ見積り用） | ○ | NUMBER は全バージョン標準。 |
| `VARCHAR2(4000)` | ○ | STANDARD モード（`MAX_STRING_SIZE=EXTENDED` は前提にしない）の上限4000バイト以内。 |
| `CLOB` 型 | 使用しない | REMARKS等は VARCHAR2(4000) で収まる想定。CLOB使用を避けることでシンプルさを保つ。 |
| `DEFAULT SYSTIMESTAMP` | ○ | Oracle 9i 以降で利用可能。 |
| `CHECK` 制約（IN リスト） | ○ | 標準 SQL。全バージョン対応。 |
| `UNIQUE` 制約（複合列） | ○ | 標準 SQL。全バージョン対応。 |
| `FOREIGN KEY` 制約 | ○（スキーマ内のみ使用） | `migration_ctl` スキーマ内の FK のみ。クロススキーマ FK は使用しない。 |
| `JSON_*` 関数 | 使用しない | 12c R2（12.2）以降限定のため禁止。 |
| `FETCH FIRST` / `OFFSET` | 使用しない | バージョン依存のため禁止。ページネーションは `ROW_NUMBER()` + サブクエリで代替。 |
| `WITH FUNCTION`（インライン関数）| 使用しない | 禁止。通常のパッケージ関数で代替。 |
| 識別子長（30文字上限） | ○ | 全制約名・トリガー名・シーケンス名を30文字以内に収めている（12.1の上限）。 |

---

## 7. 次段タスクリスト（今回スコープ外）

以下は本設計文書の対象外。将来の設計段階で別途対応する（`gap-analysis-5phase-schema.md` §3.2 を参照）。

### 優先度: 高（本番移行設計に直結）

| テーブル | 目的 | 現行の欠落 |
|---|---|---|
| `DATAPUMP_JOB` | Data Pumpジョブ単位の状態管理（ジョブ名・STATUS・開始終了時刻・実行ホスト） | 現行: シェルログのみ。SQLで状態追跡不可。 |
| `DATAPUMP_JOB_OBJECT` | ジョブ内の各テーブル単位の処理状態・件数 | 現行: なし。 |
| `DATAPUMP_FILE` | Export生成 `.dmp` ファイルの管理（チェックサム・搬送状態・サイズ） | 現行: なし。チェックサム記録もスクリプト任せ。 |
| `ARCHIVE_LOG` | Archived Redoログの永続台帳（Thread・Sequence・SCN範囲・`DICTIONARY_BEGIN`/`DICTIONARY_END` フラグ） | 現行: `V$ARCHIVED_LOG` 直接クエリのみ（`47_archive_gap_check.sh`）。PoCで判明した「辞書ビルド成否を機械的に検証する」必要性に対応。 |
| `ARCHIVE_LOG_COPY` | ファイルサーバへの物理コピー追跡（搬送状態・コピー先パス） | 現行: なし。 |

### 優先度: 中（CDC管理の精緻化）

| テーブル | 目的 |
|---|---|
| `LOGMINER_BATCH` | LogMiner解析バッチ単位の管理（開始/終了SCN・使用ログファイルリスト）。現行は `17b_sys_cdc_runner.sql` 内でその場実行・永続記録なし。 |
| `LOGMINER_BATCH_LOG` | バッチ単位の解析セッションログ。 |
| `MINED_TRANSACTION` | XIDレベルのトランザクション表。現行 `cdc_schema.delta_queue` はフラット構造（XID単位の分離なし）。 |
| `MINED_CHANGE` | DML明細（現行 `delta_queue` と近いがXID紐付けを強化）。 |
| `APPLY_BATCH` / `APPLY_TASK` | 差分適用のバッチ・タスク単位追跡。現行 `staging_ctl.apply_ledger` を補完。 |
| `MIG_CHECKPOINT` | コンポーネント別・Thread別の汎用チェックポイント。現行 `staging_ctl.delta_apply_state.last_applied_id` 等に相当するが非汎用。 |

### 優先度: 低（既存実装が先行している領域）

| テーブル | 目的 |
|---|---|
| `TRANSFORM_BATCH` | 変換バッチ単位の管理。現行 `log_schema.transform_state` を補完。 |
| `KEY_MAPPING` | 汎用キー対応表（旧キー↔新キーの1対多等）。現行 `log_schema.code_mapping` はステータスコード変換専用。 |
| `VALIDATION_RUN` / `VALIDATION_RESULT` | 検証実行・結果の構造化記録。現行 `scripts/49_two_stage_verify.sh` の結果をDBに永続化。 |
| `ERROR_EVENT` | 全フェーズ横断エラーイベント台帳。現行は `migration_error_log`（全量移行用）・`apply_ledger.FAILED`・`delta_manual_review_queue` に分散。 |
| `MIG_STATUS_HISTORY` | `MIGRATION_RUN` / `PHASE_STATUS` の状態変化履歴（監査証跡）。 |

---

## 付録: 設計レビューチェックリスト

- [x] 移行ロジックが PL/SQL 内に完結しているか（本設計はDDL/データモデルのみ。PL/SQL実装は implementation-engineer の担当）
- [x] BASELINE_SCN と MINING_START_SCN が別カラムとして設計されているか
- [x] PoC/REHEARSAL/PRODUCTION の実行種別が区別できるか（`RUN_TYPE` 列）
- [x] 7フェーズ分の状態追跡テーブルが設計されているか（`PHASE_STATUS.PHASE_CODE`）
- [x] `cdc_table_catalog` を改変せずに参照できる設計か（`CDC_CATALOG_TABLE_NAME` ソフト参照）
- [x] `log_schema.migration_run_log` の段階的移行方針が記載されているか（§5.1）
- [x] IDENTITY 列を使用していないか（SEQUENCE + BEFORE INSERT トリガーで代替済み）
- [x] 全識別子が Oracle 12.1 の30文字上限以内か（§3 各 DDL ドラフト参照）
- [x] JSON関数・FETCH FIRST 等の禁止構文を使用していないか
- [x] クロススキーマ FK を設けず、既存テーブルへの影響がゼロか
- [x] 途中失敗後の再実行方針が記載されているか（§3.2 利用パターン参照）
- [x] `CHK_MIG_RUN_SCN` により `MINING_START_SCN <= BASELINE_SCN` の設計整合性制約があるか
