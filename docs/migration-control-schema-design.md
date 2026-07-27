# 統合移行管理スキーマ設計書（v3.0 - フェーズ1・2管理テーブル連携対応版）

- 作成日: 2026-07-26
- 改訂日: 2026-07-27（v3.0）
- 対象スキーマ: `migration_ctl`（DB2.0 同一PDB内）
- 設計範囲: 先行準備A対象の9コアテーブル、フェーズ1・2対応の追加3テーブル・列追加・API追加、およびPKG_MIG_ADMIN API仕様
- 前提文書: `docs/private/design-memo-2-5phase.md`（原典・最優先）, `docs/oracle-compatibility-policy.md`, `docs/phase1-2-deliverables-and-flow.md`

---

## 改訂履歴

| バージョン | 日付 | 主な変更 |
|---|---|---|
| v1.0 | 2026-07-26 | 初版（3テーブル：MIGRATION_RUN / PHASE_STATUS / MIGRATION_OBJECT） |
| v2.0 | 2026-07-26 | 9テーブルへ拡張。DB Link前提の誤り是正。状態値をCOMPLETED統一。PKG_MIG_ADMIN API仕様追加。 |
| v3.0 | 2026-07-27 | フェーズ1・2管理テーブル連携対応。新規3テーブル（ERROR_EVENT / VALIDATION_RUN / VALIDATION_RESULT）追加。既存4テーブルへの列追加（DATAPUMP_FILE / DATAPUMP_JOB / MIGRATION_OBJECT / PHASE_STATUS）。PKG_MIG_ADMIN API 8本追加（REGISTER_DATAPUMP_FILE 等）。DDL実装方式として 04/05 の新規ファイル追加方式を採用。 |

---

## 1. 設計の目的と背景

### 1.1 v1.0 からの主な是正

v1.0 設計には以下の誤りが判明したため、本バージョン（v2.0）で是正する。

| 誤り | 内容 | 是正内容 |
|---|---|---|
| DB Link前提の記述 | `CDC_CATALOG_TABLE_NAME` 列が cdc_schema への DB Link 参照を前提として設計されていた | 列を削除。すべてのスキーマは同一 PDB 内に存在し、通常のクロススキーマ SQL で参照できる（DB Link 不要） |
| コアテーブルが3個 | 設計書対象が MIGRATION_RUN / PHASE_STATUS / MIGRATION_OBJECT の3テーブルのみ | 設計メモ §2.1.1 の先行準備A定義に従い9テーブルへ拡張 |
| MIGRATION_RUN 列不足 | `TARGET_END_SCN`・`LAST_APPLIED_SCN` が未定義 | 追加（§15.1 対応） |
| MIGRATION_OBJECT 列設計 | 単一 MIGRATION_METHOD enum で3フラグを兼用、移行先テーブル名不在 | 独立フラグ（FULL_LOAD_FLAG / CDC_FLAG / TRANSFORM_FLAG）および SOURCE / STAGE / TARGET 系列の列を追加 |
| 状態値 DONE | PHASE_STATUS / MIGRATION_RUN 等が `DONE` を使用 | `COMPLETED` へ統一（設計メモ §2.2.3 準拠） |
| PKG_MIG_ADMIN 未定義 | API 仕様が設計書に存在しなかった | API 仕様を §7 に記述 |

### 1.2 設計対象の位置づけ

**v2.0**: 先行準備A（フェーズ0相当）で作成するコアテーブル群9本。全フェーズ横断の管理基盤となる。

**v3.0 追加**: フェーズ1（Data Pump Export）とフェーズ2（Data Pump Import）を管理テーブル連携ありで動かすために必要な追加設計を盛り込んだ。具体的には以下のとおり。

- 新規テーブル3本（ERROR_EVENT / VALIDATION_RUN / VALIDATION_RESULT）: `docs/phase1-2-deliverables-and-flow.md` §3.3「管理スキーマ側の不足」で「フェーズ2完了判定に直接必要」と確認されたため、「次段以降」から格上げ。
- 既存4テーブルへの列追加（DATAPUMP_FILE / DATAPUMP_JOB / MIGRATION_OBJECT / PHASE_STATUS）: フェーズ2の Import パラメータ管理・ファイル消費追跡・承認記録に必要。
- PKG_MIG_ADMIN 追加 API 8本: ファイル管理（REGISTER / VERIFY / CONSUME）、検証管理（START / COMPLETE / RECORD）、エラー記録（RAISE_ERROR_EVENT）、フェーズ完了機械判定（COMPLETE_PHASE）。

LogMiner解析・差分適用・変換管理の詳細テーブル（LOGMINER_BATCH 等）は引き続き次段（フェーズ4実装前）に追加する。

---

## 2. 設計上の判断事項

本節は設計根拠を記録する。実装エンジニアはこの判断を変更しない。

### 2.1 PHASE_STATUS 行数：案B（7行）採用

**採用**: 案B — `PREP_A`, `PREP_B`, `PHASE1`, `PHASE2`, `PHASE3`, `PHASE4`, `PHASE5` の7行。

設計メモ §2.2.2 は「`CREATE_RUN` 時に6行INSERT」（PHASE0〜5）と記述しているが、**7行を採用**する理由は以下のとおり。

1. 設計メモ §2.1.4 が「先行準備A → 先行準備B → ...」と明示的に2段階の順序を定義している。PREP_A（管理スキーマ構築）と PREP_B（Supplemental Logging 有効化・Archived Redo 収集開始）は担当者・完了条件・継続期間のすべてが異なる独立した作業単位である。
2. PREP_A は一度完了すれば変わらない。PREP_B は最終切替まで継続する（RUNNING のまま）。これを単一 PHASE0 でモデル化すると、先行準備の進捗が追跡不能になる。
3. 既存 DDL が既に7行構成で実装されており、変更コストが高い。
4. §2.2.2 の「6行」記述は §2.1.1・§2.1.4 での A/B 分離より前に書かれた記述であり、後の詳細化（A/B 分離）によって7行が正となる。

**結論**: PHASE_CODE の CHECK 制約値は `('PREP_A','PREP_B','PHASE1','PHASE2','PHASE3','PHASE4','PHASE5')` の7値とする。

### 2.2 MIGRATION_OBJECT フェーズ別状態管理：先行準備A外

設計メモ §15.2 が提案する `MIGRATION_OBJECT_PHASE_STATUS` 新設（表×フェーズ単位管理）は**優先度B（本番設計までに必要）**であり、先行準備Aには含めない。

先行準備Aでは独立フラグ（`FULL_LOAD_FLAG` / `CDC_FLAG` / `TRANSFORM_FLAG`）で代替する。各フラグが 'Y'/'N' で当該処理の対象可否を表す。

設計メモ §15.2 は「後者（MIGRATION_OBJECT_PHASE_STATUS）の方が、表単位の除外、再実行、承認、完了時刻を拡張しやすい」と述べており、この将来拡張方向は次段判断として記録する。

**結論**: `MIGRATION_OBJECT_PHASE_STATUS` テーブルの新設は次段（本番設計フェーズ）にて実施する。

### 2.3 MIG_CHECKPOINT の扱い：先行準備A外

設計メモ §2.1.1 末尾: 「LogMiner解析、DMLキュー、チェックポイント、エラー再処理、キー対応、検証結果のテーブルは、フェーズ4・5の実装前までに追加する」

設計メモ §2.2.2 では `MIG_CHECKPOINT` の主フェーズを「3・4・5」と定義しており、フェーズ3（Archived Redo収集）のチェックポイント管理にも使用される。このため、**先行準備A には含めないが、「フェーズ3実装前に先行追加するかどうかを次段で判断する」** と明記する。フェーズ4実装前には必ず追加する。

**結論（初版）**: `MIG_CHECKPOINT` は先行準備Aの対象外。次段でフェーズ3用途の先行追加可否を判断すること。

**結論（更新: 2026-07-27）**: フェーズ3実装時に採用することが確定した。`sql/migration_ctl/06_mig_checkpoint.sql` として実装する。`COMPONENT_NAME='ARCHIVE_COLLECTOR'` で Thread 別進捗を管理し、フェーズ3完了条件（`MIG_CHECKPOINT.CHECKPOINT_SCN >= TARGET_END_SCN`）の機械判定に使用する。詳細設計は `docs/phase3-design.md` §3 を参照。

### 2.4 DDL変更方式：全体再作成

既存3テーブル（MIGRATION_RUN / PHASE_STATUS / MIGRATION_OBJECT）の変更は、**ALTER TABLE 積み増しでなく DROP → 全 DDL 再作成**とする。理由は以下のとおり。

1. `STATUS` の CHECK 制約値変更（`DONE` → `COMPLETED`、値追加）は ALTER TABLE で CHECK 制約を再定義する必要があり、一旦 DROP CONSTRAINT → ADD CONSTRAINT が必要になる。
2. MIGRATION_OBJECT は列の追加・削除・リネームが複合的に発生し、ALTER の積み重ねより全 DDL 再定義の方が最終 DDL が明快で検証しやすい。
3. 先行準備Aの段階（本番データなし）であり、既存データの保護より DDL の正確性を優先できる。

**結論**: 実装エンジニアは既存 DDL ファイルを v2.0 仕様で全体再作成する。既存テーブルを DROP してから CREATE する方式で実施する。

### 2.5 DDL変更方式（フェーズ1・2追加分）

v3.0 で追加する DDL（新規テーブル3本・列追加・CHECK制約変更・新規パッケージプロシージャ）は、**既存ファイルを修正せず新規ファイルとして追加**する方式とする。

| ファイル | 内容 |
|---|---|
| `sql/migration_ctl/04_phase1_2_additions.sql` | 新テーブル3本（ERROR_EVENT / VALIDATION_RUN / VALIDATION_RESULT）、ALTER TABLE による列追加、CHECK制約の DROP → ADD |
| `sql/migration_ctl/05_pkg_mig_admin_phase1_2.sql` | PKG_MIG_ADMIN へのプロシージャ追加（PACKAGE BODY を OR REPLACE で全体再作成） |

**採用理由**:

1. 既存テーブルにはE2E通過済みのデータが存在する可能性があり、DROP → 全再作成（§2.4 方式）を適用すると既存テストデータが消える。
2. 新規列は `ALTER TABLE ADD` で追加でき、既存行には NULL が入るため後方互換を保てる。
3. CHECK制約の値変更（STATUS に `CONSUMED` / `IN_SCOPE` / `READY` 追加）は `ALTER TABLE DROP CONSTRAINT → ADD CONSTRAINT` で対応できる。開発環境では既存データが0件の前提で制約を再作成する。

**ALTER TABLE による列追加の構文例**（Oracle 12c 互換）:

```sql
ALTER TABLE DATAPUMP_FILE ADD (
    CONSUMED_BY_IMPORT_JOB_ID NUMBER(10),
    CONSUMED_AT               TIMESTAMP,
    TARGET_VERIFIED_AT        TIMESTAMP
);
```

**CHECK制約変更の構文例**:

```sql
-- 既存制約を削除してから再作成する（開発環境・既存データなし前提）
ALTER TABLE DATAPUMP_FILE DROP CONSTRAINT CHK_DATAPUMP_FILE_STS;
ALTER TABLE DATAPUMP_FILE ADD CONSTRAINT CHK_DATAPUMP_FILE_STS
    CHECK (STATUS IN ('EXPECTED','CREATED','VERIFIED','CORRUPT','LOST','CONSUMED'));
```

**結論**: フェーズ1・2対応の追加 DDL は `04_phase1_2_additions.sql`、追加パッケージは `05_pkg_mig_admin_phase1_2.sql` として新規作成する。既存 `02` / `03` は変更しない。

---

## 3. 前提・制約

### 3.1 DB構成前提（設計メモ §12.1）

- DB1.0 は Oracle Database 12c、CDB内PDB、RAC構成。
- DB2.0 は Oracle Database 19c。
- **DB2.0 の同一 PDB 内**に、1.0スキーマ・2.0スキーマ・移行管理スキーマ（`migration_ctl` を含む）をすべて構築する。
- スキーマ間アクセスは通常のクロススキーマ SQL（`schema.table`）で可能。**DB Link は使用しない**。
- `cdc_schema`・`staging_ctl`・`log_schema` はすべて DB2.0 の同一 PDB 内に存在する前提で設計する。

### 3.2 Oracle 12c 互換制約

- IDENTITY 列は使用しない（SEQUENCE + BEFORE INSERT トリガーで代替）。
- `JSON_*` 関数・`FETCH FIRST`・`WITH FUNCTION` は使用しない。
- 識別子長は Oracle 12.1 上限の **30文字以内** に収める。
- `VARCHAR2(4000)` が上限（`MAX_STRING_SIZE=EXTENDED` を前提にしない）。
- `DEFAULT SYSTIMESTAMP` は Oracle 9i 以降で利用可能（使用可）。

---

## 4. スキーマ配置方針

新規スキーマ `migration_ctl` を DB2.0 同一 PDB 内に作成し、本設計の9テーブルをすべてここに置く。

| スキーマ | 管理範囲 | 変更有無 |
|---|---|---|
| `migration_ctl` | 全フェーズ統合管理（本設計対象） | **新設** |
| `log_schema` | 全量移行バッチのステップ詳細ログ（`migration_run_log` 等） | **変更なし**（参照のみ） |
| `cdc_schema` | CDC抽出制御・テーブルカタログ（`cdc_table_catalog` 等） | **変更なし**（参照のみ） |
| `staging_ctl` | CDC適用制御（`delta_queue`, `apply_ledger` 等） | **変更なし** |

クロススキーマ FK は `migration_ctl` 内部にのみ設ける。`log_schema`・`cdc_schema`・`staging_ctl` への参照は FK なしのソフト参照とする（同一 PDB 内なので SQL JOIN は可能だが、参照整合性の強制は波及リスクを避けるため設けない）。

---

## 5. 状態値一覧（確定版）

本節の状態値はすべての DDL・PL/SQL・運用手順で共通使用する。`DONE` は使用しない。v3.0 で追加・変更した値は末尾に（v3.0追加）と記す。

| テーブル | 列 | 許容値 |
|---|---|---|
| `MIGRATION_RUN` | `STATUS` | `CREATED`, `ARCHIVE_READY`, `BASELINE_FIXED`, `EXPORTING`, `IMPORTING`, `RUNNING`, `COMPLETED`, `FAILED`, `ABORTED` |
| `PHASE_STATUS` | `STATUS` | `NOT_STARTED`, `RUNNING`, `COMPLETED`, `FAILED`, `PAUSED` |
| `PHASE_STATUS` | `APPROVAL_STATUS`（v3.0追加） | `PENDING`, `APPROVED`, `REJECTED`（NULL許容） |
| `DATAPUMP_JOB` | `STATUS` | `PLANNED`, `RUNNING`, `COMPLETED`, `FAILED`, `RETRY` |
| `DATAPUMP_JOB` | `TABLE_EXISTS_ACTION`（v3.0追加） | `SKIP`, `APPEND`, `TRUNCATE`, `REPLACE`（NULL許容） |
| `DATAPUMP_JOB_OBJECT` | `STATUS` | `PLANNED`, `RUNNING`, `COMPLETED`, `FAILED`, `SKIPPED` |
| `DATAPUMP_FILE` | `STATUS` | `EXPECTED`, `CREATED`, `VERIFIED`, `CORRUPT`, `LOST`, `CONSUMED`（v3.0追加） |
| `ARCHIVE_LOG` | `COLLECT_STATUS` | `EXPECTED`, `RECEIVED`, `VERIFIED`, `CORRUPT`, `MISSING`, `IGNORED` |
| `ARCHIVE_LOG_COPY` | `COPY_STATUS` | `EXPECTED`, `RECEIVED`, `VERIFIED`, `REGISTERED`, `CORRUPT`, `LOST`, `DELETED` |
| `MIGRATION_OBJECT` | `STATUS` | `PENDING`, `IN_SCOPE`（v3.0追加）, `READY`（v3.0追加）, `IN_PROGRESS`, `COMPLETED`, `FAILED`, `SKIPPED` |
| `MIG_STATUS_HISTORY` | （追記専用・更新・削除禁止） | — |
| `ERROR_EVENT`（v3.0追加） | `SEVERITY` | `FATAL`, `ERROR`, `WARN` |
| `ERROR_EVENT`（v3.0追加） | `RESOLVE_STATUS` | `OPEN`, `RESOLVED`, `IGNORED` |
| `VALIDATION_RUN`（v3.0追加） | `STATUS` | `PLANNED`, `RUNNING`, `COMPLETED`, `FAILED` |
| `VALIDATION_RUN`（v3.0追加） | `OVERALL_RESULT` | `PASS`, `WARN`, `FAIL`（NULL許容） |
| `VALIDATION_RUN`（v3.0追加） | `VALIDATION_TYPE` | `ROW_COUNT`, `KEY_SET`, `AGGREGATE`, `LOB_HASH` |
| `VALIDATION_RESULT`（v3.0追加） | `RESULT` | `PASS`, `WARN`, `FAIL` |
| `VALIDATION_RESULT`（v3.0追加） | `APPROVED_FLAG` | `Y`, `N` |

**MIGRATION_OBJECT.STATUS 状態遷移補足**（v3.0追加）:

```
PENDING     → IN_SCOPE（移行対象スコープ確定時）
IN_SCOPE    → READY（Export グループ割当済み・Import パラメータ確定時）
READY       → IN_PROGRESS（処理開始時）
IN_PROGRESS → COMPLETED / FAILED / SKIPPED
```

**DATAPUMP_FILE.STATUS 状態遷移補足**（v3.0追加）:

```
EXPECTED → CREATED（ファイル生成後 REGISTER_DATAPUMP_FILE 呼び出し時）
CREATED  → VERIFIED（VERIFY_DATAPUMP_FILE でサイズ・チェックサム確定時）
VERIFIED → CONSUMED（CONSUME_DATAPUMP_FILE でImportジョブが消費時）
CREATED / VERIFIED → CORRUPT / LOST（異常時）
```

**状態遷移の基本パターン**:

```
MIGRATION_RUN.STATUS:
  CREATED → ARCHIVE_READY → BASELINE_FIXED → EXPORTING → IMPORTING
          → RUNNING → COMPLETED
          いずれの状態からも → FAILED / ABORTED

PHASE_STATUS.STATUS:
  NOT_STARTED → RUNNING → COMPLETED
                       → FAILED
                       → PAUSED → RUNNING（再開）

ARCHIVE_LOG.COLLECT_STATUS:
  EXPECTED → RECEIVED → VERIFIED
                    → CORRUPT / MISSING / IGNORED

ARCHIVE_LOG_COPY.COPY_STATUS:
  EXPECTED → RECEIVED → VERIFIED → REGISTERED
               → CORRUPT / LOST
  REGISTERED / VERIFIED → DELETED（保持期限終了等）
```

---

## 6. テーブル設計仕様

### 6.1 命名規約

| 対象 | 規則 | 例 |
|---|---|---|
| テーブル名・カラム名 | 英大文字、アンダースコア区切り | `MIGRATION_RUN`, `MIG_RUN_ID` |
| シーケンス名 | `SEQ_` プレフィックス | `SEQ_MIGRATION_RUN` |
| トリガー名 | `TRG_` プレフィックス + `_BI` サフィックス | `TRG_MIGRATION_RUN_BI` |
| 主キー制約 | `PK_` プレフィックス | `PK_MIGRATION_RUN` |
| 外部キー制約 | `FK_` プレフィックス | `FK_PHASE_STATUS_RUN` |
| UNIQUE 制約 | `UQ_` プレフィックス | `UQ_MIGRATION_RUN_NAME` |
| CHECK 制約 | `CHK_` プレフィックス | `CHK_MIG_RUN_TYPE` |
| 主キーカラム | `_ID` サフィックス | `MIG_RUN_ID` |

すべての制約名・トリガー名・シーケンス名は Oracle 12.1 識別子長上限（30文字）以内に収める。

---

### 6.2 MIGRATION_RUN（移行実行親テーブル）

#### 設計意図

全5フェーズ＋先行準備を束ねる実行単位の親キーテーブル。PoC・リハーサル・本番を別 `MIG_RUN_ID` で管理し、過去実行レコードを上書きしない。`BASELINE_SCN` と `MINING_START_SCN` を分離し、基準断面を跨ぐ長時間トランザクションを再構成できる設計にする。

v2.0 追加列: `SOURCE_DB_INFO`・`TARGET_DB_INFO`（CREATE_RUN API 入力）、`ARCHIVE_READY_AT`・`BASELINE_FIXED_AT`（SCN確定タイムスタンプ）、`TARGET_END_SCN`（最終同期点）、`LAST_APPLIED_SCN`（最終適用SCN）。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| MIG_RUN_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| RUN_NAME | VARCHAR2(100) | YES | — | 実行名（例: `2026-Q1-PROD-01`）。UNIQUE |
| RUN_TYPE | VARCHAR2(20) | YES | — | `POC` / `REHEARSAL` / `PRODUCTION` |
| SOURCE_DB_INFO | VARCHAR2(500) | NO | NULL | 移行元 DB/PDB/スキーマ情報（CREATE_RUN 入力） |
| TARGET_DB_INFO | VARCHAR2(500) | NO | NULL | 移行先 DB/PDB/スキーマ情報（CREATE_RUN 入力） |
| STATUS | VARCHAR2(20) | YES | `CREATED` | §5 状態値一覧参照 |
| BASELINE_SCN | NUMBER(20) | NO | NULL | 全量断面用SCN。FIX_BASELINE_SCN で確定後は不変。 |
| BASELINE_FIXED_AT | TIMESTAMP | NO | NULL | BASELINE_SCN 確定日時。 |
| MINING_START_SCN | NUMBER(20) | NO | NULL | LogMiner 解析開始 SCN。`BASELINE_SCN` 以下の値。 |
| ARCHIVE_READY_AT | TIMESTAMP | NO | NULL | MARK_ARCHIVE_READY 実行日時。 |
| TARGET_END_SCN | NUMBER(20) | NO | NULL | 最終同期点 SCN。SET_TARGET_END_SCN で確定後は不変。 |
| LAST_APPLIED_SCN | NUMBER(20) | NO | NULL | 最終適用済み SCN（UPDATE_LAST_APPLIED_SCN で更新）。 |
| STARTED_AT | TIMESTAMP | NO | NULL | 移行実行の開始日時。 |
| FINISHED_AT | TIMESTAMP | NO | NULL | 移行完了日時。 |
| LOG_RUN_ID | NUMBER(10) | NO | NULL | `log_schema.migration_run_log.run_id` へのソフト参照（FK制約なし・同一PDB内）。 |
| REMARKS | VARCHAR2(4000) | NO | NULL | 備考・運用メモ。 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時。 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時。 |

#### DDL（設計ドラフト）

```sql
CREATE SEQUENCE SEQ_MIGRATION_RUN
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE MIGRATION_RUN (
    MIG_RUN_ID         NUMBER(10)     NOT NULL,
    RUN_NAME           VARCHAR2(100)  NOT NULL,
    RUN_TYPE           VARCHAR2(20)   NOT NULL,
    SOURCE_DB_INFO     VARCHAR2(500),
    TARGET_DB_INFO     VARCHAR2(500),
    STATUS             VARCHAR2(20)   DEFAULT 'CREATED' NOT NULL,
    BASELINE_SCN       NUMBER(20),
    BASELINE_FIXED_AT  TIMESTAMP,
    MINING_START_SCN   NUMBER(20),
    ARCHIVE_READY_AT   TIMESTAMP,
    TARGET_END_SCN     NUMBER(20),
    LAST_APPLIED_SCN   NUMBER(20),
    STARTED_AT         TIMESTAMP,
    FINISHED_AT        TIMESTAMP,
    LOG_RUN_ID         NUMBER(10),
    REMARKS            VARCHAR2(4000),
    CREATED_AT         TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT         TIMESTAMP,
    CONSTRAINT PK_MIGRATION_RUN
        PRIMARY KEY (MIG_RUN_ID),
    CONSTRAINT UQ_MIGRATION_RUN_NAME
        UNIQUE (RUN_NAME),
    CONSTRAINT CHK_MIG_RUN_TYPE
        CHECK (RUN_TYPE IN ('POC', 'REHEARSAL', 'PRODUCTION')),
    CONSTRAINT CHK_MIG_RUN_STATUS
        CHECK (STATUS IN (
            'CREATED', 'ARCHIVE_READY', 'BASELINE_FIXED',
            'EXPORTING', 'IMPORTING', 'RUNNING',
            'COMPLETED', 'FAILED', 'ABORTED')),
    CONSTRAINT CHK_MIG_RUN_SCN
        CHECK (MINING_START_SCN IS NULL
               OR BASELINE_SCN IS NULL
               OR MINING_START_SCN <= BASELINE_SCN)
);

CREATE OR REPLACE TRIGGER TRG_MIGRATION_RUN_BI
BEFORE INSERT ON MIGRATION_RUN
FOR EACH ROW
BEGIN
    IF :NEW.MIG_RUN_ID IS NULL THEN
        SELECT SEQ_MIGRATION_RUN.NEXTVAL
        INTO :NEW.MIG_RUN_ID FROM DUAL;
    END IF;
END;
/
```

---

### 6.3 PHASE_STATUS（フェーズ進捗テーブル）

#### 設計意図

1回の `MIGRATION_RUN` ごとに7フェーズ分のレコードを持ち、各フェーズの状態遷移・開始終了時刻を追跡する。`CREATE_RUN` API 実行時に7行を `NOT_STARTED` で一括作成する（§2.1 判断事項参照）。

#### フェーズコード定義

| PHASE_CODE | フェーズ名 | 概要 |
|---|---|---|
| `PREP_A` | 先行準備A | `migration_ctl` スキーマ・9コアテーブルの最小構築。 |
| `PREP_B` | 先行準備B | Supplemental Logging 有効化、LogMiner Dictionary ビルド（CDB$ROOT で `STORE_IN_REDO_LOGS`）、Archived Redo 収集開始。最終切替まで継続。 |
| `PHASE1` | 初回全量 Export | Data Pump Export による全量バックアップ取得・`BASELINE_SCN` 確定。 |
| `PHASE2` | 初回全量 Import | Data Pump Import による DB2.0 側 1.0 スキーマへの全量ロード。 |
| `PHASE3` | Archived Redo 収集 | アーカイブログ転送・`MINING_START_SCN` 確定。実運用ではフェーズ1より前から開始する。 |
| `PHASE4` | LogMiner 解析・差分反映 | LogMiner 解析（DB2.0 側で `DICT_FROM_REDO_LOGS` 使用）→ 変更を DB2.0 へ適用。 |
| `PHASE5` | 1.0→2.0 変換 | 旧スキーマから新スキーマへの変換（型変換・コード変換等）。 |

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| PHASE_STATUS_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | — | FK: `MIGRATION_RUN.MIG_RUN_ID` |
| PHASE_CODE | VARCHAR2(20) | YES | — | フェーズ識別子（CHECK制約参照） |
| STATUS | VARCHAR2(20) | YES | `NOT_STARTED` | §5 状態値一覧参照 |
| STARTED_AT | TIMESTAMP | NO | NULL | フェーズ開始日時。RUNNING 遷移時に設定。 |
| FINISHED_AT | TIMESTAMP | NO | NULL | フェーズ完了日時。COMPLETED / FAILED 遷移時に設定。 |
| ERROR_MESSAGE | VARCHAR2(4000) | NO | NULL | エラー内容の要約（FAILED 時）。 |
| REMARKS | VARCHAR2(4000) | NO | NULL | 備考。 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時。 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時。 |

#### DDL（設計ドラフト）

```sql
CREATE SEQUENCE SEQ_PHASE_STATUS
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE PHASE_STATUS (
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
        REFERENCES MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT UQ_PHASE_STATUS_CODE
        UNIQUE (MIG_RUN_ID, PHASE_CODE),
    CONSTRAINT CHK_PHASE_STATUS_CODE
        CHECK (PHASE_CODE IN
               ('PREP_A','PREP_B','PHASE1','PHASE2',
                'PHASE3','PHASE4','PHASE5')),
    CONSTRAINT CHK_PHASE_STATUS_STS
        CHECK (STATUS IN
               ('NOT_STARTED','RUNNING','COMPLETED','FAILED','PAUSED'))
);

CREATE OR REPLACE TRIGGER TRG_PHASE_STATUS_BI
BEFORE INSERT ON PHASE_STATUS
FOR EACH ROW
BEGIN
    IF :NEW.PHASE_STATUS_ID IS NULL THEN
        SELECT SEQ_PHASE_STATUS.NEXTVAL
        INTO :NEW.PHASE_STATUS_ID FROM DUAL;
    END IF;
END;
/
```

**利用パターン**: `CREATE_RUN` API 実行時に7フェーズ分を `NOT_STARTED` で一括 INSERT する。再実行時は STATUS を `NOT_STARTED` に戻してから再度 `RUNNING` に遷移させる（既存レコードを UPDATE するため再 INSERT 不要）。

---

### 6.4 MIGRATION_OBJECT（対象オブジェクト台帳）

#### 設計意図

1回の `MIGRATION_RUN` における移行対象テーブルのカタログ。v2.0 では単一 `MIGRATION_METHOD` enum を廃止し、`FULL_LOAD_FLAG` / `CDC_FLAG` / `TRANSFORM_FLAG` の独立フラグへ変更する。移行元（SOURCE）・中間（STAGE: DB2.0側 1.0スキーマ）・最終（TARGET: DB2.0側 2.0スキーマ）の3層スキーマ情報を保持する。

v1.0 から削除した列: `MIGRATION_METHOD`（フラグに置換）、`OBJECT_SCHEMA`（`SOURCE_OWNER` に改称）、`OBJECT_NAME`（`SOURCE_TABLE_NAME` に改称）、`PROCESS_ORDER`（`APPLY_ORDER_NO` / `TRANSFORM_ORDER_NO` に分離）、`EST_ROW_COUNT`（`ESTIMATED_ROWS` に改称）、`EST_SIZE_MB`（`ESTIMATED_DATA_BYTES` に置換）、`CDC_CATALOG_TABLE_NAME`（DB Link前提の誤りのため削除）。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| MIG_OBJECT_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | — | FK: `MIGRATION_RUN.MIG_RUN_ID` |
| SOURCE_OWNER | VARCHAR2(100) | YES | — | 移行元スキーマ名（大文字）。DB1.0 側 1.0 スキーマ。 |
| SOURCE_TABLE_NAME | VARCHAR2(100) | YES | — | 移行元テーブル名（大文字）。 |
| STAGE_OWNER | VARCHAR2(100) | NO | NULL | DB2.0 側 1.0 スキーマ名（中間保持先）。 |
| STAGE_TABLE_NAME | VARCHAR2(100) | NO | NULL | DB2.0 側 1.0 スキーマのテーブル名。 |
| TARGET_OWNER | VARCHAR2(100) | NO | NULL | DB2.0 側 2.0 スキーマ名（変換先）。TRANSFORM_FLAG='Y' 時のみ使用。 |
| TARGET_TABLE_NAME | VARCHAR2(100) | NO | NULL | DB2.0 側 2.0 スキーマのテーブル名。 |
| FULL_LOAD_FLAG | CHAR(1) | YES | `'Y'` | 全量ロード対象: 'Y'/'N' |
| CDC_FLAG | CHAR(1) | YES | `'N'` | CDC（差分反映）対象: 'Y'/'N' |
| TRANSFORM_FLAG | CHAR(1) | YES | `'N'` | スキーマ変換（フェーズ5）対象: 'Y'/'N' |
| PRIMARY_KEY_COLUMNS | VARCHAR2(1000) | NO | NULL | 主キー列名（カンマ区切り）。 |
| HAS_LOB_FLAG | CHAR(1) | YES | `'N'` | LOB 列有無: 'Y'/'N' |
| ESTIMATED_ROWS | NUMBER(20) | NO | NULL | 概算行数見積り。 |
| ESTIMATED_DATA_BYTES | NUMBER(20) | NO | NULL | 概算データサイズ（バイト）見積り。 |
| ESTIMATED_LOB_BYTES | NUMBER(20) | NO | NULL | 概算 LOB サイズ（バイト）見積り。 |
| EXPORT_GROUP_CODE | VARCHAR2(100) | NO | NULL | Data Pump Export グループ識別子（ジョブ分割単位）。 |
| APPLY_ORDER_NO | NUMBER(5) | NO | NULL | CDC 適用処理順序（フェーズ4）。FK 依存を考慮した順序。 |
| TRANSFORM_ORDER_NO | NUMBER(5) | NO | NULL | 変換処理順序（フェーズ5）。 |
| STATUS | VARCHAR2(20) | YES | `'PENDING'` | §5 状態値一覧参照。 |
| REMARKS | VARCHAR2(4000) | NO | NULL | 備考。 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時。 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時。 |

#### DDL（設計ドラフト）

```sql
CREATE SEQUENCE SEQ_MIGRATION_OBJECT
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE MIGRATION_OBJECT (
    MIG_OBJECT_ID         NUMBER(10)     NOT NULL,
    MIG_RUN_ID            NUMBER(10)     NOT NULL,
    SOURCE_OWNER          VARCHAR2(100)  NOT NULL,
    SOURCE_TABLE_NAME     VARCHAR2(100)  NOT NULL,
    STAGE_OWNER           VARCHAR2(100),
    STAGE_TABLE_NAME      VARCHAR2(100),
    TARGET_OWNER          VARCHAR2(100),
    TARGET_TABLE_NAME     VARCHAR2(100),
    FULL_LOAD_FLAG        CHAR(1)        DEFAULT 'Y' NOT NULL,
    CDC_FLAG              CHAR(1)        DEFAULT 'N' NOT NULL,
    TRANSFORM_FLAG        CHAR(1)        DEFAULT 'N' NOT NULL,
    PRIMARY_KEY_COLUMNS   VARCHAR2(1000),
    HAS_LOB_FLAG          CHAR(1)        DEFAULT 'N' NOT NULL,
    ESTIMATED_ROWS        NUMBER(20),
    ESTIMATED_DATA_BYTES  NUMBER(20),
    ESTIMATED_LOB_BYTES   NUMBER(20),
    EXPORT_GROUP_CODE     VARCHAR2(100),
    APPLY_ORDER_NO        NUMBER(5),
    TRANSFORM_ORDER_NO    NUMBER(5),
    STATUS                VARCHAR2(20)   DEFAULT 'PENDING' NOT NULL,
    REMARKS               VARCHAR2(4000),
    CREATED_AT            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT            TIMESTAMP,
    CONSTRAINT PK_MIGRATION_OBJECT
        PRIMARY KEY (MIG_OBJECT_ID),
    CONSTRAINT FK_MIG_OBJECT_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT UQ_MIG_OBJECT_SRC
        UNIQUE (MIG_RUN_ID, SOURCE_OWNER, SOURCE_TABLE_NAME),
    CONSTRAINT CHK_MIG_OBJ_STATUS
        CHECK (STATUS IN
               ('PENDING','IN_PROGRESS','COMPLETED','FAILED','SKIPPED')),
    CONSTRAINT CHK_MIG_OBJ_FL_FLAG
        CHECK (FULL_LOAD_FLAG IN ('Y','N')),
    CONSTRAINT CHK_MIG_OBJ_CDC_FLAG
        CHECK (CDC_FLAG IN ('Y','N')),
    CONSTRAINT CHK_MIG_OBJ_TRF_FLAG
        CHECK (TRANSFORM_FLAG IN ('Y','N')),
    CONSTRAINT CHK_MIG_OBJ_LOB_FLAG
        CHECK (HAS_LOB_FLAG IN ('Y','N'))
);

CREATE OR REPLACE TRIGGER TRG_MIGRATION_OBJECT_BI
BEFORE INSERT ON MIGRATION_OBJECT
FOR EACH ROW
BEGIN
    IF :NEW.MIG_OBJECT_ID IS NULL THEN
        SELECT SEQ_MIGRATION_OBJECT.NEXTVAL
        INTO :NEW.MIG_OBJECT_ID FROM DUAL;
    END IF;
END;
/
```

**cdc_table_catalog とのクロススキーマ結合例**（DB Link なし・同一 PDB 内）:

```sql
-- CDC分類情報が必要な場合は SOURCE_TABLE_NAME で直接結合する（FK制約なし・ソフト参照）
SELECT
    mo.MIG_OBJECT_ID,
    mo.SOURCE_OWNER,
    mo.SOURCE_TABLE_NAME,
    mo.FULL_LOAD_FLAG,
    mo.CDC_FLAG,
    mo.TRANSFORM_FLAG,
    mo.STATUS,
    ctc.replay_category,
    ctc.lob_present
FROM migration_ctl.MIGRATION_OBJECT mo
LEFT JOIN cdc_schema.cdc_table_catalog ctc
  ON ctc.table_name = mo.SOURCE_TABLE_NAME
WHERE mo.MIG_RUN_ID = :mig_run_id
ORDER BY mo.APPLY_ORDER_NO NULLS LAST, mo.SOURCE_TABLE_NAME;
```

---

### 6.5 DATAPUMP_JOB（Data Pump ジョブ管理テーブル）

#### 設計意図

Data Pump の Export / Import / SQLFILE ジョブを1行1ジョブで管理する。直接 UPDATE でなく `PKG_MIG_ADMIN` の API 経由で状態遷移・時刻・件数を記録することで、実装ごとのばらつきを防ぐ。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| DATAPUMP_JOB_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | — | FK: `MIGRATION_RUN.MIG_RUN_ID` |
| JOB_NAME | VARCHAR2(128) | YES | — | Data Pump ジョブ名（Oracle 内部ジョブ名と一致させる） |
| OPERATION | VARCHAR2(20) | YES | — | `EXPORT` / `IMPORT` / `SQLFILE` |
| STATUS | VARCHAR2(20) | YES | `'PLANNED'` | §5 状態値一覧参照 |
| BASELINE_SCN | NUMBER(20) | NO | NULL | Export 時の `FLASHBACK_SCN`（EXPORT のみ）。 |
| PARALLEL | NUMBER(5) | NO | NULL | 並列度設定値。 |
| DIRECTORY_NAME | VARCHAR2(128) | NO | NULL | Oracle DIRECTORY オブジェクト名。 |
| LOG_FILE_NAME | VARCHAR2(500) | NO | NULL | Data Pump ログファイル名。 |
| ORACLE_JOB_NAME | VARCHAR2(128) | NO | NULL | Oracle 内部ジョブ名（DBA_DATAPUMP_JOBS 参照用）。 |
| EXECUTE_HOST | VARCHAR2(200) | NO | NULL | 実行ホスト名。 |
| EXECUTE_INSTANCE | VARCHAR2(200) | NO | NULL | RAC インスタンス名。 |
| STARTED_AT | TIMESTAMP | NO | NULL | ジョブ開始日時。 |
| FINISHED_AT | TIMESTAMP | NO | NULL | ジョブ終了日時。 |
| PROCESSED_ROWS | NUMBER(20) | NO | NULL | 処理行数（完了後に記録）。 |
| PROCESSED_BYTES | NUMBER(20) | NO | NULL | 処理バイト数（完了後に記録）。 |
| ERROR_COUNT | NUMBER(10) | NO | NULL | エラー件数（完了後に記録）。 |
| REMARKS | VARCHAR2(4000) | NO | NULL | 備考。 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時。 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時。 |

#### DDL（設計ドラフト）

```sql
CREATE SEQUENCE SEQ_DATAPUMP_JOB
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE DATAPUMP_JOB (
    DATAPUMP_JOB_ID   NUMBER(10)     NOT NULL,
    MIG_RUN_ID        NUMBER(10)     NOT NULL,
    JOB_NAME          VARCHAR2(128)  NOT NULL,
    OPERATION         VARCHAR2(20)   NOT NULL,
    STATUS            VARCHAR2(20)   DEFAULT 'PLANNED' NOT NULL,
    BASELINE_SCN      NUMBER(20),
    PARALLEL          NUMBER(5),
    DIRECTORY_NAME    VARCHAR2(128),
    LOG_FILE_NAME     VARCHAR2(500),
    ORACLE_JOB_NAME   VARCHAR2(128),
    EXECUTE_HOST      VARCHAR2(200),
    EXECUTE_INSTANCE  VARCHAR2(200),
    STARTED_AT        TIMESTAMP,
    FINISHED_AT       TIMESTAMP,
    PROCESSED_ROWS    NUMBER(20),
    PROCESSED_BYTES   NUMBER(20),
    ERROR_COUNT       NUMBER(10),
    REMARKS           VARCHAR2(4000),
    CREATED_AT        TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT        TIMESTAMP,
    CONSTRAINT PK_DATAPUMP_JOB
        PRIMARY KEY (DATAPUMP_JOB_ID),
    CONSTRAINT FK_DATAPUMP_JOB_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT CHK_DATAPUMP_JOB_OP
        CHECK (OPERATION IN ('EXPORT','IMPORT','SQLFILE')),
    CONSTRAINT CHK_DATAPUMP_JOB_STS
        CHECK (STATUS IN
               ('PLANNED','RUNNING','COMPLETED','FAILED','RETRY'))
);

CREATE OR REPLACE TRIGGER TRG_DATAPUMP_JOB_BI
BEFORE INSERT ON DATAPUMP_JOB
FOR EACH ROW
BEGIN
    IF :NEW.DATAPUMP_JOB_ID IS NULL THEN
        SELECT SEQ_DATAPUMP_JOB.NEXTVAL
        INTO :NEW.DATAPUMP_JOB_ID FROM DUAL;
    END IF;
END;
/
```

---

### 6.6 DATAPUMP_JOB_OBJECT（ジョブ×対象テーブル対応テーブル）

#### 設計意図

`DATAPUMP_JOB` と `MIGRATION_OBJECT` の N:M 中間テーブル。1ジョブが複数テーブルを処理し、1テーブルが複数ジョブ（Export + Import など）で扱われる関係を表す。テーブル単位の処理行数・結果を記録する。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| DP_JOB_OBJECT_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| DATAPUMP_JOB_ID | NUMBER(10) | YES | — | FK: `DATAPUMP_JOB.DATAPUMP_JOB_ID` |
| MIG_OBJECT_ID | NUMBER(10) | YES | — | FK: `MIGRATION_OBJECT.MIG_OBJECT_ID` |
| STATUS | VARCHAR2(20) | YES | `'PLANNED'` | §5 状態値一覧参照 |
| PROCESSED_ROWS | NUMBER(20) | NO | NULL | テーブル単位の処理行数。 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時。 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時。 |

#### DDL（設計ドラフト）

```sql
CREATE SEQUENCE SEQ_DATAPUMP_JOB_OBJECT
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE DATAPUMP_JOB_OBJECT (
    DP_JOB_OBJECT_ID  NUMBER(10)     NOT NULL,
    DATAPUMP_JOB_ID   NUMBER(10)     NOT NULL,
    MIG_OBJECT_ID     NUMBER(10)     NOT NULL,
    STATUS            VARCHAR2(20)   DEFAULT 'PLANNED' NOT NULL,
    PROCESSED_ROWS    NUMBER(20),
    CREATED_AT        TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT        TIMESTAMP,
    CONSTRAINT PK_DATAPUMP_JOB_OBJECT
        PRIMARY KEY (DP_JOB_OBJECT_ID),
    CONSTRAINT FK_DP_JOB_OBJ_JOB
        FOREIGN KEY (DATAPUMP_JOB_ID)
        REFERENCES DATAPUMP_JOB (DATAPUMP_JOB_ID),
    CONSTRAINT FK_DP_JOB_OBJ_MIG_OBJ
        FOREIGN KEY (MIG_OBJECT_ID)
        REFERENCES MIGRATION_OBJECT (MIG_OBJECT_ID),
    CONSTRAINT UQ_DP_JOB_OBJECT
        UNIQUE (DATAPUMP_JOB_ID, MIG_OBJECT_ID),
    CONSTRAINT CHK_DP_JOB_OBJ_STATUS
        CHECK (STATUS IN
               ('PLANNED','RUNNING','COMPLETED','FAILED','SKIPPED'))
);

CREATE OR REPLACE TRIGGER TRG_DP_JOB_OBJECT_BI
BEFORE INSERT ON DATAPUMP_JOB_OBJECT
FOR EACH ROW
BEGIN
    IF :NEW.DP_JOB_OBJECT_ID IS NULL THEN
        SELECT SEQ_DATAPUMP_JOB_OBJECT.NEXTVAL
        INTO :NEW.DP_JOB_OBJECT_ID FROM DUAL;
    END IF;
END;
/
```

---

### 6.7 DATAPUMP_FILE（ダンプ・ログ・関連ファイル管理テーブル）

#### 設計意図

物理ファイル1個につき1行で管理する（ダンプ、ログ、PARFILE、SQLFILE、チェックサムファイル、マニフェスト）。ファイル実体が存在しない状態で `STATUS='VERIFIED'` にしてはならない（不変条件 §7.2）。`DATAPUMP_JOB_ID` は計画段階では NULL でも可（PARFILE 等は事前生成）。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| DATAPUMP_FILE_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | — | FK: `MIGRATION_RUN.MIG_RUN_ID` |
| DATAPUMP_JOB_ID | NUMBER(10) | NO | NULL | FK: `DATAPUMP_JOB.DATAPUMP_JOB_ID`（計画段階は NULL 可） |
| FILE_ROLE | VARCHAR2(20) | YES | — | `DUMP` / `EXPORT_LOG` / `IMPORT_LOG` / `PARFILE` / `SQLFILE` / `CHECKSUM` / `MANIFEST` |
| STATUS | VARCHAR2(20) | YES | `'EXPECTED'` | §5 状態値一覧参照 |
| FILE_NAME | VARCHAR2(500) | YES | — | ファイル名。 |
| FILE_PATH | VARCHAR2(1000) | NO | NULL | ファイルフルパス（保存先媒体含む）。 |
| STORAGE_LOCATION | VARCHAR2(200) | NO | NULL | 保存場所識別子（例: `MIGRATION_FILE_SERVER`, `8TB_SSD`, `DB2_LOCAL`）。 |
| FILE_SIZE_BYTES | NUMBER(20) | NO | NULL | ファイルサイズ（バイト）。 |
| CHECKSUM_ALGO | VARCHAR2(20) | NO | NULL | チェックサムアルゴリズム（例: `SHA256`）。 |
| CHECKSUM_VALUE | VARCHAR2(200) | NO | NULL | チェックサム値。 |
| VERIFIED_AT | TIMESTAMP | NO | NULL | ファイル検証完了日時。 |
| REMARKS | VARCHAR2(4000) | NO | NULL | 備考。 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時。 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時。 |

#### DDL（設計ドラフト）

```sql
CREATE SEQUENCE SEQ_DATAPUMP_FILE
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE DATAPUMP_FILE (
    DATAPUMP_FILE_ID   NUMBER(10)     NOT NULL,
    MIG_RUN_ID         NUMBER(10)     NOT NULL,
    DATAPUMP_JOB_ID    NUMBER(10),
    FILE_ROLE          VARCHAR2(20)   NOT NULL,
    STATUS             VARCHAR2(20)   DEFAULT 'EXPECTED' NOT NULL,
    FILE_NAME          VARCHAR2(500)  NOT NULL,
    FILE_PATH          VARCHAR2(1000),
    STORAGE_LOCATION   VARCHAR2(200),
    FILE_SIZE_BYTES    NUMBER(20),
    CHECKSUM_ALGO      VARCHAR2(20),
    CHECKSUM_VALUE     VARCHAR2(200),
    VERIFIED_AT        TIMESTAMP,
    REMARKS            VARCHAR2(4000),
    CREATED_AT         TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT         TIMESTAMP,
    CONSTRAINT PK_DATAPUMP_FILE
        PRIMARY KEY (DATAPUMP_FILE_ID),
    CONSTRAINT FK_DATAPUMP_FILE_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT FK_DATAPUMP_FILE_JOB
        FOREIGN KEY (DATAPUMP_JOB_ID)
        REFERENCES DATAPUMP_JOB (DATAPUMP_JOB_ID),
    CONSTRAINT CHK_DATAPUMP_FILE_ROLE
        CHECK (FILE_ROLE IN
               ('DUMP','EXPORT_LOG','IMPORT_LOG',
                'PARFILE','SQLFILE','CHECKSUM','MANIFEST')),
    CONSTRAINT CHK_DATAPUMP_FILE_STS
        CHECK (STATUS IN
               ('EXPECTED','CREATED','VERIFIED','CORRUPT','LOST'))
);

CREATE OR REPLACE TRIGGER TRG_DATAPUMP_FILE_BI
BEFORE INSERT ON DATAPUMP_FILE
FOR EACH ROW
BEGIN
    IF :NEW.DATAPUMP_FILE_ID IS NULL THEN
        SELECT SEQ_DATAPUMP_FILE.NEXTVAL
        INTO :NEW.DATAPUMP_FILE_ID FROM DUAL;
    END IF;
END;
/
```

---

### 6.8 ARCHIVE_LOG（Archived Redo Log 論理台帳）

#### 設計意図

Thread・Sequence 単位の論理的な Archived Redo Log を管理する。同一ログが複数媒体へコピーされる場合は `ARCHIVE_LOG_COPY` に物理コピー行を追加し、`ARCHIVE_LOG` を重複 INSERT しない（論理/物理分離。設計メモ §5.2.2）。

`DICTIONARY_BEGIN_FLAG` / `DICTIONARY_END_FLAG` は LogMiner Dictionary ビルドのマーカーを機械的に検証するための列（PDB 内 BUILD の成否を `V$ARCHIVED_LOG` の `DICTIONARY_BEGIN`/`DICTIONARY_END` で確認する運用と連動する）。

**論理一意キー**: `(MIG_RUN_ID, SOURCE_RESETLOGS_ID, THREAD_NO, SEQUENCE_NO)`

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| ARCHIVE_LOG_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | — | FK: `MIGRATION_RUN.MIG_RUN_ID` |
| SOURCE_DBID | NUMBER(20) | NO | NULL | DB1.0 の DBID。 |
| SOURCE_RESETLOGS_ID | NUMBER(20) | YES | — | RESETLOGS 識別子（論理一意キー構成要素）。 |
| THREAD_NO | NUMBER(5) | YES | — | RAC Thread 番号。 |
| SEQUENCE_NO | NUMBER(20) | YES | — | アーカイブログ Sequence 番号。 |
| FIRST_CHANGE_SCN | NUMBER(20) | NO | NULL | ログ内の最初の変更 SCN。 |
| NEXT_CHANGE_SCN | NUMBER(20) | NO | NULL | ログ内の最後の変更 SCN + 1。 |
| FIRST_TIME | TIMESTAMP | NO | NULL | ログ開始時刻。 |
| NEXT_TIME | TIMESTAMP | NO | NULL | ログ終了時刻。 |
| DICTIONARY_BEGIN_FLAG | CHAR(1) | YES | `'N'` | LogMiner Dictionary 開始マーカー有無: 'Y'/'N' |
| DICTIONARY_END_FLAG | CHAR(1) | YES | `'N'` | LogMiner Dictionary 終了マーカー有無: 'Y'/'N' |
| COLLECT_STATUS | VARCHAR2(20) | YES | `'EXPECTED'` | §5 状態値一覧参照 |
| REMARKS | VARCHAR2(4000) | NO | NULL | 備考。 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時。 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時。 |

#### DDL（設計ドラフト）

```sql
CREATE SEQUENCE SEQ_ARCHIVE_LOG
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE ARCHIVE_LOG (
    ARCHIVE_LOG_ID         NUMBER(10)     NOT NULL,
    MIG_RUN_ID             NUMBER(10)     NOT NULL,
    SOURCE_DBID            NUMBER(20),
    SOURCE_RESETLOGS_ID    NUMBER(20)     NOT NULL,
    THREAD_NO              NUMBER(5)      NOT NULL,
    SEQUENCE_NO            NUMBER(20)     NOT NULL,
    FIRST_CHANGE_SCN       NUMBER(20),
    NEXT_CHANGE_SCN        NUMBER(20),
    FIRST_TIME             TIMESTAMP,
    NEXT_TIME              TIMESTAMP,
    DICTIONARY_BEGIN_FLAG  CHAR(1)        DEFAULT 'N' NOT NULL,
    DICTIONARY_END_FLAG    CHAR(1)        DEFAULT 'N' NOT NULL,
    COLLECT_STATUS         VARCHAR2(20)   DEFAULT 'EXPECTED' NOT NULL,
    REMARKS                VARCHAR2(4000),
    CREATED_AT             TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT             TIMESTAMP,
    CONSTRAINT PK_ARCHIVE_LOG
        PRIMARY KEY (ARCHIVE_LOG_ID),
    CONSTRAINT FK_ARCHIVE_LOG_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT UQ_ARCHIVE_LOG_THREAD_SEQ
        UNIQUE (MIG_RUN_ID, SOURCE_RESETLOGS_ID,
                THREAD_NO, SEQUENCE_NO),
    CONSTRAINT CHK_ARCHIVE_LOG_COL_STS
        CHECK (COLLECT_STATUS IN
               ('EXPECTED','RECEIVED','VERIFIED',
                'CORRUPT','MISSING','IGNORED')),
    CONSTRAINT CHK_ARCHIVE_LOG_DICT_B
        CHECK (DICTIONARY_BEGIN_FLAG IN ('Y','N')),
    CONSTRAINT CHK_ARCHIVE_LOG_DICT_E
        CHECK (DICTIONARY_END_FLAG IN ('Y','N'))
);

CREATE OR REPLACE TRIGGER TRG_ARCHIVE_LOG_BI
BEFORE INSERT ON ARCHIVE_LOG
FOR EACH ROW
BEGIN
    IF :NEW.ARCHIVE_LOG_ID IS NULL THEN
        SELECT SEQ_ARCHIVE_LOG.NEXTVAL
        INTO :NEW.ARCHIVE_LOG_ID FROM DUAL;
    END IF;
END;
/
```

---

### 6.9 ARCHIVE_LOG_COPY（Archived Redo Log 物理コピー管理テーブル）

#### 設計意図

`ARCHIVE_LOG` の1レコードに対し、保存媒体（Migrationファイルサーバ・8TB SSD・DB2.0 ローカル等）ごとに物理コピーの状態を1行で管理する。再転送した場合は既存行を更新せず新行を INSERT する（設計メモ §5.2.2・§5.2.5）。

ファイル実体が存在しない状態で `COPY_STATUS='VERIFIED'` にしてはならない（不変条件 §7.2）。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| ARCHIVE_LOG_COPY_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| ARCHIVE_LOG_ID | NUMBER(10) | YES | — | FK: `ARCHIVE_LOG.ARCHIVE_LOG_ID` |
| MIG_RUN_ID | NUMBER(10) | YES | — | FK: `MIGRATION_RUN.MIG_RUN_ID`（集計・フィルタ用） |
| STORAGE_LOCATION | VARCHAR2(200) | YES | — | 保存場所識別子（例: `MIGRATION_FILE_SERVER`, `8TB_SSD`, `DB2_LOCAL`）。 |
| FILE_PATH | VARCHAR2(1000) | YES | — | コピー先のフルパス。 |
| FILE_SIZE_BYTES | NUMBER(20) | NO | NULL | ファイルサイズ（バイト）。 |
| CHECKSUM_ALGO | VARCHAR2(20) | NO | NULL | チェックサムアルゴリズム（例: `SHA256`）。 |
| CHECKSUM_VALUE | VARCHAR2(200) | NO | NULL | チェックサム値。 |
| COPY_STATUS | VARCHAR2(20) | YES | `'EXPECTED'` | §5 状態値一覧参照 |
| RECEIVED_AT | TIMESTAMP | NO | NULL | ファイル受信完了日時。 |
| VERIFIED_AT | TIMESTAMP | NO | NULL | ファイル検証完了日時。 |
| REMARKS | VARCHAR2(4000) | NO | NULL | 備考。 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時。 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時。 |

#### DDL（設計ドラフト）

```sql
CREATE SEQUENCE SEQ_ARCHIVE_LOG_COPY
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE ARCHIVE_LOG_COPY (
    ARCHIVE_LOG_COPY_ID  NUMBER(10)     NOT NULL,
    ARCHIVE_LOG_ID       NUMBER(10)     NOT NULL,
    MIG_RUN_ID           NUMBER(10)     NOT NULL,
    STORAGE_LOCATION     VARCHAR2(200)  NOT NULL,
    FILE_PATH            VARCHAR2(1000) NOT NULL,
    FILE_SIZE_BYTES      NUMBER(20),
    CHECKSUM_ALGO        VARCHAR2(20),
    CHECKSUM_VALUE       VARCHAR2(200),
    COPY_STATUS          VARCHAR2(20)   DEFAULT 'EXPECTED' NOT NULL,
    RECEIVED_AT          TIMESTAMP,
    VERIFIED_AT          TIMESTAMP,
    REMARKS              VARCHAR2(4000),
    CREATED_AT           TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT           TIMESTAMP,
    CONSTRAINT PK_ARCHIVE_LOG_COPY
        PRIMARY KEY (ARCHIVE_LOG_COPY_ID),
    CONSTRAINT FK_ARC_LOG_COPY_LOG
        FOREIGN KEY (ARCHIVE_LOG_ID)
        REFERENCES ARCHIVE_LOG (ARCHIVE_LOG_ID),
    CONSTRAINT FK_ARC_LOG_COPY_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT CHK_ARC_LOG_COPY_STS
        CHECK (COPY_STATUS IN
               ('EXPECTED','RECEIVED','VERIFIED',
                'REGISTERED','CORRUPT','LOST','DELETED'))
);

CREATE OR REPLACE TRIGGER TRG_ARCHIVE_LOG_COPY_BI
BEFORE INSERT ON ARCHIVE_LOG_COPY
FOR EACH ROW
BEGIN
    IF :NEW.ARCHIVE_LOG_COPY_ID IS NULL THEN
        SELECT SEQ_ARCHIVE_LOG_COPY.NEXTVAL
        INTO :NEW.ARCHIVE_LOG_COPY_ID FROM DUAL;
    END IF;
END;
/
```

---

### 6.10 MIG_STATUS_HISTORY（状態変更監査履歴テーブル）

#### 設計意図

`MIGRATION_RUN`・`PHASE_STATUS` 等の主要テーブルの状態変更を追記専用で記録する監査証跡テーブル。**UPDATE・DELETE は禁止**（不変条件 §7.2）。`PKG_MIG_ADMIN` の API 実行時に自動的に INSERT される。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| HISTORY_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | — | FK: `MIGRATION_RUN.MIG_RUN_ID`（どの実行に関するものか） |
| TABLE_NAME | VARCHAR2(100) | YES | — | 状態変更が発生したテーブル名（例: `MIGRATION_RUN`） |
| RECORD_ID | NUMBER(20) | YES | — | 対象レコードの主キー値 |
| OLD_STATUS | VARCHAR2(50) | NO | NULL | 変更前の状態値（初回 INSERT 時は NULL） |
| NEW_STATUS | VARCHAR2(50) | YES | — | 変更後の状態値 |
| CHANGED_BY | VARCHAR2(100) | YES | — | 変更を行った API 名またはユーザー名 |
| CHANGED_AT | TIMESTAMP | YES | SYSTIMESTAMP | 変更日時 |
| NOTE | VARCHAR2(4000) | NO | NULL | 補足情報（エラーメッセージ・SCN 等） |

#### DDL（設計ドラフト）

```sql
CREATE SEQUENCE SEQ_MIG_STATUS_HISTORY
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE MIG_STATUS_HISTORY (
    HISTORY_ID    NUMBER(10)     NOT NULL,
    MIG_RUN_ID    NUMBER(10)     NOT NULL,
    TABLE_NAME    VARCHAR2(100)  NOT NULL,
    RECORD_ID     NUMBER(20)     NOT NULL,
    OLD_STATUS    VARCHAR2(50),
    NEW_STATUS    VARCHAR2(50)   NOT NULL,
    CHANGED_BY    VARCHAR2(100)  NOT NULL,
    CHANGED_AT    TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    NOTE          VARCHAR2(4000),
    CONSTRAINT PK_MIG_STATUS_HISTORY
        PRIMARY KEY (HISTORY_ID),
    CONSTRAINT FK_MIG_STAT_HIST_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES MIGRATION_RUN (MIG_RUN_ID)
);

CREATE OR REPLACE TRIGGER TRG_MIG_STATUS_HIST_BI
BEFORE INSERT ON MIG_STATUS_HISTORY
FOR EACH ROW
BEGIN
    IF :NEW.HISTORY_ID IS NULL THEN
        SELECT SEQ_MIG_STATUS_HISTORY.NEXTVAL
        INTO :NEW.HISTORY_ID FROM DUAL;
    END IF;
END;
/
```

---

### 6.11 ERROR_EVENT（エラーイベント台帳）

#### 設計意図

全フェーズ横断のエラーイベントを1行1件で記録する。Export失敗・Import失敗・チェックサム不一致等あらゆる障害を統一フォーマットで蓄積し、`RESOLVE_STATUS` で解消状況を追跡する。`COMPLETE_PHASE` の完了判定では「`SEVERITY IN ('FATAL','ERROR')` かつ `RESOLVE_STATUS='OPEN'` のレコードが存在しないこと」を条件とする（§8.3 参照）。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| ERROR_EVENT_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | — | FK: `MIGRATION_RUN.MIG_RUN_ID` |
| PHASE_CODE | VARCHAR2(20) | NO | NULL | 発生フェーズ（`PHASE1` 等） |
| SEVERITY | VARCHAR2(20) | YES | — | `FATAL` / `ERROR` / `WARN` |
| COMPONENT_NAME | VARCHAR2(100) | NO | NULL | 発生コンポーネント名（例: `EXPDP_GRP01`） |
| DATAPUMP_JOB_ID | NUMBER(10) | NO | NULL | FK: `DATAPUMP_JOB.DATAPUMP_JOB_ID`（関連ジョブ） |
| ORA_ERROR_CODE | VARCHAR2(20) | NO | NULL | ORA-xxxxx 等のエラーコード |
| ERROR_MESSAGE | VARCHAR2(4000) | NO | NULL | エラー詳細メッセージ |
| RESOLVE_STATUS | VARCHAR2(20) | YES | `'OPEN'` | `OPEN` / `RESOLVED` / `IGNORED` |
| RESOLVED_AT | TIMESTAMP | NO | NULL | 解消日時 |
| RESOLVE_NOTE | VARCHAR2(4000) | NO | NULL | 解消メモ |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時 |

#### DDL（設計ドラフト）

```sql
CREATE SEQUENCE SEQ_ERROR_EVENT
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE ERROR_EVENT (
    ERROR_EVENT_ID   NUMBER(10)     NOT NULL,
    MIG_RUN_ID       NUMBER(10)     NOT NULL,
    PHASE_CODE       VARCHAR2(20),
    SEVERITY         VARCHAR2(20)   NOT NULL,
    COMPONENT_NAME   VARCHAR2(100),
    DATAPUMP_JOB_ID  NUMBER(10),
    ORA_ERROR_CODE   VARCHAR2(20),
    ERROR_MESSAGE    VARCHAR2(4000),
    RESOLVE_STATUS   VARCHAR2(20)   DEFAULT 'OPEN' NOT NULL,
    RESOLVED_AT      TIMESTAMP,
    RESOLVE_NOTE     VARCHAR2(4000),
    CREATED_AT       TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT       TIMESTAMP,
    CONSTRAINT PK_ERROR_EVENT
        PRIMARY KEY (ERROR_EVENT_ID),
    CONSTRAINT FK_ERROR_EVENT_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT FK_ERROR_EVENT_DP_JOB
        FOREIGN KEY (DATAPUMP_JOB_ID)
        REFERENCES DATAPUMP_JOB (DATAPUMP_JOB_ID),
    CONSTRAINT CHK_ERROR_EVENT_SEV
        CHECK (SEVERITY IN ('FATAL','ERROR','WARN')),
    CONSTRAINT CHK_ERROR_EVENT_RSTS
        CHECK (RESOLVE_STATUS IN ('OPEN','RESOLVED','IGNORED'))
);

CREATE OR REPLACE TRIGGER TRG_ERROR_EVENT_BI
BEFORE INSERT ON ERROR_EVENT
FOR EACH ROW
BEGIN
    IF :NEW.ERROR_EVENT_ID IS NULL THEN
        SELECT SEQ_ERROR_EVENT.NEXTVAL
        INTO :NEW.ERROR_EVENT_ID FROM DUAL;
    END IF;
END;
/
```

---

### 6.12 VALIDATION_RUN（検証実行管理テーブル）

#### 設計意図

フェーズ2完了後（およびフェーズ4・5での将来拡張）に実施する検証の実行単位を管理する。`COMPLETE_PHASE` の完了判定では「対象フェーズの必須 `VALIDATION_RUN` が `COMPLETED` かつ `OVERALL_RESULT='PASS'`」を条件とする。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| VALIDATION_RUN_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | — | FK: `MIGRATION_RUN.MIG_RUN_ID` |
| PHASE_CODE | VARCHAR2(20) | YES | — | 検証対象フェーズ（`PHASE2` 等） |
| VALIDATION_TYPE | VARCHAR2(50) | YES | — | `ROW_COUNT` / `KEY_SET` / `AGGREGATE` / `LOB_HASH` |
| STATUS | VARCHAR2(20) | YES | `'PLANNED'` | `PLANNED` / `RUNNING` / `COMPLETED` / `FAILED` |
| OVERALL_RESULT | VARCHAR2(10) | NO | NULL | `PASS` / `WARN` / `FAIL`（COMPLETED 時に設定） |
| STARTED_AT | TIMESTAMP | NO | NULL | 検証開始日時 |
| FINISHED_AT | TIMESTAMP | NO | NULL | 検証完了日時 |
| REMARKS | VARCHAR2(4000) | NO | NULL | 備考 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時 |

#### DDL（設計ドラフト）

```sql
CREATE SEQUENCE SEQ_VALIDATION_RUN
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE VALIDATION_RUN (
    VALIDATION_RUN_ID  NUMBER(10)     NOT NULL,
    MIG_RUN_ID         NUMBER(10)     NOT NULL,
    PHASE_CODE         VARCHAR2(20)   NOT NULL,
    VALIDATION_TYPE    VARCHAR2(50)   NOT NULL,
    STATUS             VARCHAR2(20)   DEFAULT 'PLANNED' NOT NULL,
    OVERALL_RESULT     VARCHAR2(10),
    STARTED_AT         TIMESTAMP,
    FINISHED_AT        TIMESTAMP,
    REMARKS            VARCHAR2(4000),
    CREATED_AT         TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT         TIMESTAMP,
    CONSTRAINT PK_VALIDATION_RUN
        PRIMARY KEY (VALIDATION_RUN_ID),
    CONSTRAINT FK_VALIDATION_RUN_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT CHK_VALID_RUN_TYPE
        CHECK (VALIDATION_TYPE IN
               ('ROW_COUNT','KEY_SET','AGGREGATE','LOB_HASH')),
    CONSTRAINT CHK_VALID_RUN_STATUS
        CHECK (STATUS IN
               ('PLANNED','RUNNING','COMPLETED','FAILED')),
    CONSTRAINT CHK_VALID_RUN_RESULT
        CHECK (OVERALL_RESULT IS NULL
               OR OVERALL_RESULT IN ('PASS','WARN','FAIL'))
);

CREATE OR REPLACE TRIGGER TRG_VALIDATION_RUN_BI
BEFORE INSERT ON VALIDATION_RUN
FOR EACH ROW
BEGIN
    IF :NEW.VALIDATION_RUN_ID IS NULL THEN
        SELECT SEQ_VALIDATION_RUN.NEXTVAL
        INTO :NEW.VALIDATION_RUN_ID FROM DUAL;
    END IF;
END;
/
```

---

### 6.13 VALIDATION_RESULT（検証結果明細テーブル）

#### 設計意図

`VALIDATION_RUN` 配下の検証項目1件につき1行で結果を記録する。`RESULT='FAIL'` かつ `APPROVED_FLAG='N'` のレコードが残っていると `COMPLETE_PHASE` の完了判定が通らない。FAIL を許容する場合は `APPROVED_FLAG='Y'` にセットし `APPROVE_NOTE` に承認根拠を記録する。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| VALIDATION_RESULT_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| VALIDATION_RUN_ID | NUMBER(10) | YES | — | FK: `VALIDATION_RUN.VALIDATION_RUN_ID` |
| MIG_OBJECT_ID | NUMBER(10) | NO | NULL | FK: `MIGRATION_OBJECT.MIG_OBJECT_ID`（対象テーブル） |
| CHECK_NAME | VARCHAR2(100) | YES | — | 検証項目名（例: `ROW_COUNT_REGIONS`） |
| EXPECTED_VALUE | VARCHAR2(4000) | NO | NULL | 期待値 |
| ACTUAL_VALUE | VARCHAR2(4000) | NO | NULL | 実測値 |
| RESULT | VARCHAR2(10) | YES | — | `PASS` / `WARN` / `FAIL` |
| APPROVED_FLAG | CHAR(1) | YES | `'N'` | `Y` / `N`（FAIL 承認フラグ。PASS/WARN 時は `N` のまま） |
| APPROVED_AT | TIMESTAMP | NO | NULL | 承認日時 |
| APPROVE_NOTE | VARCHAR2(4000) | NO | NULL | 承認メモ |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時 |

#### DDL（設計ドラフト）

```sql
CREATE SEQUENCE SEQ_VALIDATION_RESULT
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE VALIDATION_RESULT (
    VALIDATION_RESULT_ID  NUMBER(10)     NOT NULL,
    VALIDATION_RUN_ID     NUMBER(10)     NOT NULL,
    MIG_OBJECT_ID         NUMBER(10),
    CHECK_NAME            VARCHAR2(100)  NOT NULL,
    EXPECTED_VALUE        VARCHAR2(4000),
    ACTUAL_VALUE          VARCHAR2(4000),
    RESULT                VARCHAR2(10)   NOT NULL,
    APPROVED_FLAG         CHAR(1)        DEFAULT 'N' NOT NULL,
    APPROVED_AT           TIMESTAMP,
    APPROVE_NOTE          VARCHAR2(4000),
    CREATED_AT            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT            TIMESTAMP,
    CONSTRAINT PK_VALIDATION_RESULT
        PRIMARY KEY (VALIDATION_RESULT_ID),
    CONSTRAINT FK_VALID_RESULT_VRUN
        FOREIGN KEY (VALIDATION_RUN_ID)
        REFERENCES VALIDATION_RUN (VALIDATION_RUN_ID),
    CONSTRAINT FK_VALID_RESULT_OBJ
        FOREIGN KEY (MIG_OBJECT_ID)
        REFERENCES MIGRATION_OBJECT (MIG_OBJECT_ID),
    CONSTRAINT CHK_VALID_RESULT_RES
        CHECK (RESULT IN ('PASS','WARN','FAIL')),
    CONSTRAINT CHK_VALID_RESULT_APPR
        CHECK (APPROVED_FLAG IN ('Y','N'))
);

CREATE OR REPLACE TRIGGER TRG_VALIDATION_RESULT_BI
BEFORE INSERT ON VALIDATION_RESULT
FOR EACH ROW
BEGIN
    IF :NEW.VALIDATION_RESULT_ID IS NULL THEN
        SELECT SEQ_VALIDATION_RESULT.NEXTVAL
        INTO :NEW.VALIDATION_RESULT_ID FROM DUAL;
    END IF;
END;
/
```

---

### 6.14 既存テーブル改修（フェーズ1・2対応）

本節は v3.0 で既存4テーブルに追加する列と CHECK 制約変更をまとめる。実装は `sql/migration_ctl/04_phase1_2_additions.sql` に収録し、既存 DDL ファイルは変更しない（§2.5 参照）。

#### 6.14.1 DATAPUMP_FILE 列追加

| 追加列名 | 型 | NULL許容 | 説明 |
|---|---|---|---|
| `CONSUMED_BY_IMPORT_JOB_ID` | NUMBER(10) | YES | Import時にこのファイルを消費したジョブID（FK: DATAPUMP_JOB） |
| `CONSUMED_AT` | TIMESTAMP | YES | ダンプ消費日時（CONSUME_DATAPUMP_FILE 実行時） |
| `TARGET_VERIFIED_AT` | TIMESTAMP | YES | DB2.0側でチェックサムを再計算・確認した日時 |

`STATUS` の CHECK 制約変更: `'CONSUMED'` を追加。

```sql
-- 列追加
ALTER TABLE DATAPUMP_FILE ADD (
    CONSUMED_BY_IMPORT_JOB_ID NUMBER(10),
    CONSUMED_AT               TIMESTAMP,
    TARGET_VERIFIED_AT        TIMESTAMP
);

-- FK 追加（CONSUMED_BY_IMPORT_JOB_ID → DATAPUMP_JOB）
ALTER TABLE DATAPUMP_FILE ADD CONSTRAINT FK_DP_FILE_CONSM_JOB
    FOREIGN KEY (CONSUMED_BY_IMPORT_JOB_ID)
    REFERENCES DATAPUMP_JOB (DATAPUMP_JOB_ID);

-- STATUS の CHECK制約を再作成（CONSUMED 追加）
ALTER TABLE DATAPUMP_FILE DROP CONSTRAINT CHK_DATAPUMP_FILE_STS;
ALTER TABLE DATAPUMP_FILE ADD CONSTRAINT CHK_DATAPUMP_FILE_STS
    CHECK (STATUS IN
           ('EXPECTED','CREATED','VERIFIED','CORRUPT','LOST','CONSUMED'));
```

#### 6.14.2 DATAPUMP_JOB 列追加

| 追加列名 | 型 | NULL許容 | 説明 |
|---|---|---|---|
| `REMAP_SCHEMA_DEF` | VARCHAR2(500) | YES | REMAP_SCHEMA 定義（例: `SRC_SCHEMA:STAGING_SCHEMA`） |
| `REMAP_TABLESPACE_DEF` | VARCHAR2(500) | YES | REMAP_TABLESPACE 定義 |
| `TABLE_EXISTS_ACTION` | VARCHAR2(20) | YES | `SKIP` / `APPEND` / `TRUNCATE` / `REPLACE` |
| `PARAMETER_TEXT` | VARCHAR2(4000) | YES | 完全な impdp パラメータテキスト（確定値を保存） |
| `RESULT_MESSAGE` | VARCHAR2(4000) | YES | 実行結果サマリ・承認事項・再実行時の元ファイル方針 |

```sql
ALTER TABLE DATAPUMP_JOB ADD (
    REMAP_SCHEMA_DEF      VARCHAR2(500),
    REMAP_TABLESPACE_DEF  VARCHAR2(500),
    TABLE_EXISTS_ACTION   VARCHAR2(20),
    PARAMETER_TEXT        VARCHAR2(4000),
    RESULT_MESSAGE        VARCHAR2(4000)
);

ALTER TABLE DATAPUMP_JOB ADD CONSTRAINT CHK_DP_JOB_TEA
    CHECK (TABLE_EXISTS_ACTION IS NULL
           OR TABLE_EXISTS_ACTION IN ('SKIP','APPEND','TRUNCATE','REPLACE'));
```

#### 6.14.3 MIGRATION_OBJECT STATUS 拡張

`STATUS` の許容値に `IN_SCOPE`・`READY` を追加する。状態遷移の意味は §5 参照。

```sql
ALTER TABLE MIGRATION_OBJECT DROP CONSTRAINT CHK_MIG_OBJ_STATUS;
ALTER TABLE MIGRATION_OBJECT ADD CONSTRAINT CHK_MIG_OBJ_STATUS
    CHECK (STATUS IN
           ('PENDING','IN_SCOPE','READY',
            'IN_PROGRESS','COMPLETED','FAILED','SKIPPED'));
```

#### 6.14.4 PHASE_STATUS 列追加

フェーズ2の SQLFILE レビュー承認等、フェーズ単位の承認情報を記録する列を追加する。

| 追加列名 | 型 | NULL許容 | 説明 |
|---|---|---|---|
| `APPROVAL_STATUS` | VARCHAR2(20) | YES | `PENDING` / `APPROVED` / `REJECTED`（承認フロー管理） |
| `APPROVED_BY` | VARCHAR2(100) | YES | 承認者名またはシステム名 |
| `APPROVED_AT` | TIMESTAMP | YES | 承認日時 |

```sql
ALTER TABLE PHASE_STATUS ADD (
    APPROVAL_STATUS  VARCHAR2(20),
    APPROVED_BY      VARCHAR2(100),
    APPROVED_AT      TIMESTAMP
);

ALTER TABLE PHASE_STATUS ADD CONSTRAINT CHK_PHASE_APPR_STS
    CHECK (APPROVAL_STATUS IS NULL
           OR APPROVAL_STATUS IN ('PENDING','APPROVED','REJECTED'));
```

---

## 7. ER 図（テキスト表現）

v3.0 追加分（ERROR_EVENT / VALIDATION_RUN / VALIDATION_RESULT）と、既存テーブルへの列追加を反映した改訂版。

```
migration_ctl スキーマ（DB2.0 同一PDB内・DB Link 不使用）
─────────────────────────────────────────────────────────────────────
MIGRATION_RUN
  MIG_RUN_ID PK
  RUN_NAME UQ
  RUN_TYPE / STATUS / BASELINE_SCN / MINING_START_SCN
  TARGET_END_SCN / LAST_APPLIED_SCN
  SOURCE_DB_INFO / TARGET_DB_INFO
  ARCHIVE_READY_AT / BASELINE_FIXED_AT
  LOG_RUN_ID ─ ─ ─ ─► log_schema.MIGRATION_RUN_LOG（同一PDB・FK制約なし）
    │
    ├─1:N─ PHASE_STATUS
    │         PHASE_STATUS_ID PK
    │         MIG_RUN_ID FK
    │         PHASE_CODE（PREP_A/PREP_B/PHASE1-5）
    │         STATUS（NOT_STARTED/RUNNING/COMPLETED/FAILED/PAUSED）
    │         [v3.0] APPROVAL_STATUS / APPROVED_BY / APPROVED_AT
    │
    ├─1:N─ MIGRATION_OBJECT
    │         MIG_OBJECT_ID PK
    │         MIG_RUN_ID FK
    │         SOURCE_OWNER / SOURCE_TABLE_NAME UQ(RUN+SRC)
    │         STAGE_OWNER / STAGE_TABLE_NAME
    │         TARGET_OWNER / TARGET_TABLE_NAME
    │         FULL_LOAD_FLAG / CDC_FLAG / TRANSFORM_FLAG
    │         PRIMARY_KEY_COLUMNS / HAS_LOB_FLAG
    │         ESTIMATED_ROWS / ESTIMATED_DATA_BYTES / ESTIMATED_LOB_BYTES
    │         EXPORT_GROUP_CODE / APPLY_ORDER_NO / TRANSFORM_ORDER_NO
    │         STATUS（PENDING/IN_SCOPE/READY/IN_PROGRESS/COMPLETED/FAILED/SKIPPED）[v3.0拡張]
    │         ─ ─ ─► cdc_schema.CDC_TABLE_CATALOG（同一PDB・SOURCE_TABLE_NAMEで結合）
    │
    ├─1:N─ DATAPUMP_JOB
    │         DATAPUMP_JOB_ID PK
    │         MIG_RUN_ID FK
    │         JOB_NAME / OPERATION / STATUS / BASELINE_SCN
    │         [v3.0] REMAP_SCHEMA_DEF / REMAP_TABLESPACE_DEF
    │         [v3.0] TABLE_EXISTS_ACTION / PARAMETER_TEXT / RESULT_MESSAGE
    │         │
    │         ├─1:N─ DATAPUMP_JOB_OBJECT
    │         │         DP_JOB_OBJECT_ID PK
    │         │         DATAPUMP_JOB_ID FK
    │         │         MIG_OBJECT_ID FK → MIGRATION_OBJECT
    │         │         STATUS / PROCESSED_ROWS
    │         │
    │         └─1:N─ DATAPUMP_FILE（DATAPUMP_JOB_ID FK：nullable）
    │                   DATAPUMP_FILE_ID PK
    │                   MIG_RUN_ID FK
    │                   DATAPUMP_JOB_ID FK（nullable）
    │                   FILE_ROLE / STATUS / FILE_NAME / CHECKSUM_*
    │                   [v3.0] CONSUMED_BY_IMPORT_JOB_ID FK → DATAPUMP_JOB
    │                   [v3.0] CONSUMED_AT / TARGET_VERIFIED_AT
    │
    ├─1:N─ ARCHIVE_LOG
    │         ARCHIVE_LOG_ID PK
    │         MIG_RUN_ID FK
    │         UQ(MIG_RUN_ID, RESETLOGS_ID, THREAD_NO, SEQUENCE_NO)
    │         COLLECT_STATUS / DICTIONARY_*_FLAG
    │         │
    │         └─1:N─ ARCHIVE_LOG_COPY
    │                   ARCHIVE_LOG_COPY_ID PK
    │                   ARCHIVE_LOG_ID FK
    │                   MIG_RUN_ID FK
    │                   STORAGE_LOCATION / FILE_PATH / CHECKSUM_*
    │                   COPY_STATUS
    │
    ├─1:N─ MIG_STATUS_HISTORY
    │         HISTORY_ID PK
    │         MIG_RUN_ID FK
    │         TABLE_NAME / RECORD_ID
    │         OLD_STATUS / NEW_STATUS / CHANGED_BY / CHANGED_AT
    │         （追記専用・UPDATE・DELETE 禁止）
    │
    ├─1:N─ ERROR_EVENT [v3.0]
    │         ERROR_EVENT_ID PK
    │         MIG_RUN_ID FK
    │         PHASE_CODE / SEVERITY（FATAL/ERROR/WARN）
    │         COMPONENT_NAME / ORA_ERROR_CODE / ERROR_MESSAGE
    │         DATAPUMP_JOB_ID FK → DATAPUMP_JOB（nullable）
    │         RESOLVE_STATUS（OPEN/RESOLVED/IGNORED）
    │         RESOLVED_AT / RESOLVE_NOTE
    │
    └─1:N─ VALIDATION_RUN [v3.0]
              VALIDATION_RUN_ID PK
              MIG_RUN_ID FK
              PHASE_CODE / VALIDATION_TYPE / STATUS
              OVERALL_RESULT（PASS/WARN/FAIL）
              STARTED_AT / FINISHED_AT
              │
              └─1:N─ VALIDATION_RESULT [v3.0]
                        VALIDATION_RESULT_ID PK
                        VALIDATION_RUN_ID FK
                        MIG_OBJECT_ID FK → MIGRATION_OBJECT（nullable）
                        CHECK_NAME / EXPECTED_VALUE / ACTUAL_VALUE
                        RESULT（PASS/WARN/FAIL）
                        APPROVED_FLAG（Y/N） / APPROVED_AT / APPROVE_NOTE

凡例:
  1:N ─── : FK 制約あり（migration_ctl スキーマ内）
  ─ ─ ─►  : ソフト参照（FK 制約なし・同一 PDB 内クロススキーマ参照）
  [v3.0]  : v3.0 で追加した要素
```

---

## 8. PKG_MIG_ADMIN API 仕様

実装は implementation-engineer が行う。本節は設計仕様を確定したものであり、API の挙動・戻り値・例外仕様を規定する。

### 8.1 API 一覧

#### CREATE_RUN

```
PROCEDURE CREATE_RUN (
    p_run_name      IN VARCHAR2,
    p_run_type      IN VARCHAR2,
    p_source_db_info IN VARCHAR2 DEFAULT NULL,
    p_target_db_info IN VARCHAR2 DEFAULT NULL,
    p_run_id        OUT NUMBER
);
```

- `MIGRATION_RUN` を1行 INSERT（STATUS='CREATED'）する。
- 続けて `PHASE_STATUS` の7フェーズ（PREP_A, PREP_B, PHASE1〜PHASE5）を `NOT_STARTED` で一括 INSERT する。
- 両 INSERT は同一トランザクション内で実行し COMMIT する。
- `p_run_id` に採番された `MIG_RUN_ID` を返す。
- `RUN_NAME` 重複時は例外を発生させる。
- `MIG_STATUS_HISTORY` に `NEW_STATUS='CREATED'` で記録する。

---

#### FIX_BASELINE_SCN

```
PROCEDURE FIX_BASELINE_SCN (
    p_run_id       IN NUMBER,
    p_baseline_scn IN NUMBER
);
```

- `BASELINE_SCN` を不変値として確定する。
- `BASELINE_SCN` が既に設定済みの場合は例外を発生させる（上書き禁止）。
- `MIGRATION_RUN.STATUS` を `BASELINE_FIXED` に更新し、`BASELINE_FIXED_AT = SYSTIMESTAMP` を設定する。
- `MIG_STATUS_HISTORY` に変更前後の STATUS を記録する。
- `MINING_START_SCN IS NOT NULL AND p_baseline_scn < MINING_START_SCN` の場合は例外を発生させる。

---

#### MARK_ARCHIVE_READY

```
PROCEDURE MARK_ARCHIVE_READY (
    p_run_id IN NUMBER
);
```

- 必要なログカバレッジ確認 SQL を内部で実行し、`MINING_START_SCN` から現在 SCN までの連続する検証済みコピーが存在することを確認する。
- 確認 SQL が合格しない場合は例外を発生させ、STATUS は変更しない。
- 合格時: `MIGRATION_RUN.STATUS` を `ARCHIVE_READY`・`ARCHIVE_READY_AT = SYSTIMESTAMP` に更新する。
- `MIG_STATUS_HISTORY` に記録する。
- PoC段階では ARCHIVE_LOG 件数確認のみ（本番フェーズ前に連続性チェックへ強化する）。

---

#### SET_TARGET_END_SCN

```
PROCEDURE SET_TARGET_END_SCN (
    p_run_id          IN NUMBER,
    p_target_end_scn  IN NUMBER
);
```

- 最終同期点 SCN を不変値として確定する。
- `TARGET_END_SCN` が既に設定済みの場合は例外を発生させる（上書き禁止）。
- `MIGRATION_RUN.TARGET_END_SCN = p_target_end_scn` を更新する。
- `MIG_STATUS_HISTORY` に記録する。

---

#### UPDATE_LAST_APPLIED_SCN

```
PROCEDURE UPDATE_LAST_APPLIED_SCN (
    p_run_id IN NUMBER,
    p_scn    IN NUMBER
);
```

- チェックポイントとの整合確認後に `LAST_APPLIED_SCN` を更新する。
- `p_scn < LAST_APPLIED_SCN`（後退）の場合は例外を発生させる。
- `TARGET_END_SCN` が設定済みで `p_scn > TARGET_END_SCN` の場合は警告（DBMS_OUTPUT）を出力するが例外にはしない。

---

#### START_DATAPUMP_JOB

```
PROCEDURE START_DATAPUMP_JOB (
    p_job_id IN NUMBER
);
```

- `DATAPUMP_JOB.STATUS` を `RUNNING`・`STARTED_AT = SYSTIMESTAMP` に更新する。
- 事前条件: STATUS = 'PLANNED' または 'RETRY'。それ以外は例外。
- `MIG_STATUS_HISTORY` に記録する。

---

#### COMPLETE_DATAPUMP_JOB

```
PROCEDURE COMPLETE_DATAPUMP_JOB (
    p_job_id      IN NUMBER,
    p_rows        IN NUMBER,
    p_bytes       IN NUMBER,
    p_error_count IN NUMBER
);
```

- `DATAPUMP_JOB.STATUS` を `COMPLETED`・`FINISHED_AT = SYSTIMESTAMP` に更新する。
- `PROCESSED_ROWS`・`PROCESSED_BYTES`・`ERROR_COUNT` を記録する。
- `MIG_STATUS_HISTORY` に記録する。

---

#### FAIL_DATAPUMP_JOB

```
PROCEDURE FAIL_DATAPUMP_JOB (
    p_job_id        IN NUMBER,
    p_error_message IN VARCHAR2
);
```

- `DATAPUMP_JOB.STATUS` を `FAILED`・`FINISHED_AT = SYSTIMESTAMP` に更新する。
- `MIG_STATUS_HISTORY` に `NOTE = p_error_message` で記録する。

---

#### VERIFY_ARCHIVE_LOG_COPY

```
PROCEDURE VERIFY_ARCHIVE_LOG_COPY (
    p_copy_id  IN NUMBER,
    p_checksum IN VARCHAR2
);
```

- ファイル実体の確認（ファイル存在・サイズ・チェックサム照合）を行う。
- 確認合格時のみ `ARCHIVE_LOG_COPY.COPY_STATUS` を `VERIFIED`・`VERIFIED_AT = SYSTIMESTAMP` に更新する。
- 不合格時は `COPY_STATUS = 'CORRUPT'` に更新し、例外を発生させる。
- ファイル実体が存在しない状態で `VERIFIED` にしてはならない（不変条件）。
- `ARCHIVE_LOG.COLLECT_STATUS` の更新（全コピーが VERIFIED になった場合に VERIFIED へ）も行う。
- `MIG_STATUS_HISTORY` に記録する。

---

#### LOG_STATUS_CHANGE

```
PROCEDURE LOG_STATUS_CHANGE (
    p_run_id     IN NUMBER,
    p_table_name IN VARCHAR2,
    p_record_id  IN NUMBER,
    p_old_status IN VARCHAR2,
    p_new_status IN VARCHAR2,
    p_note       IN VARCHAR2 DEFAULT NULL
);
```

- `MIG_STATUS_HISTORY` へ1行 INSERT する。
- 他の API から内部的に呼ばれるが、外部からも直接呼び出し可能。
- `CHANGED_BY` には呼び出し元 API 名またはユーザー名を記録する（`DBMS_SESSION.CLIENT_IDENTIFIER` 優先）。

---

### 8.2 不変条件

以下の条件は PKG_MIG_ADMIN のすべての API 実装において遵守する。実装エンジニアはこれを破ってはならない。

1. **MIG_STATUS_HISTORY は追記専用**（UPDATE・DELETE 禁止）。
2. **ファイル実体が存在しない状態で VERIFIED にしない**（`DATAPUMP_FILE.STATUS`・`ARCHIVE_LOG_COPY.COPY_STATUS` 共通）。
3. **BASELINE_SCN・TARGET_END_SCN は一度設定後に上書き禁止**。既設定時は例外を発生させる。
4. **差分 DML と MIG_CHECKPOINT の更新は同一 DB トランザクションで COMMIT する**（フェーズ4以降。先行準備Aでは MIG_CHECKPOINT が未実装のため対象外）。
5. **CREATE_RUN は MIGRATION_RUN 1行 + PHASE_STATUS 7行を同一トランザクションで作成する**。途中失敗時はロールバックする。
6. **DATAPUMP_FILE.STATUS='CONSUMED' にできるのは VERIFY_DATAPUMP_FILE による 'VERIFIED' 確定後のみ**（CONSUME_DATAPUMP_FILE の事前条件）。[v3.0]
7. **VERIFY_DATAPUMP_FILE でチェックサムが NULL の場合は STATUS を VERIFIED にせず例外を発生させる**（不変条件継続）。[v3.0]

---

### 8.3 フェーズ1・2追加 API 仕様（v3.0）

本節は v3.0 で `PKG_MIG_ADMIN` に追加するプロシージャの設計仕様を定義する。実装は `sql/migration_ctl/05_pkg_mig_admin_phase1_2.sql` に収録し、PACKAGE BODY を `CREATE OR REPLACE` で全体再作成する方式とする。

エラー番号追加規約（v3.0）:

| 番号 | 意味 |
|---|---|
| -20005 | ファイル検証失敗（チェックサム NULL 等）- 既存と共通 |
| -20010 | COMPLETE_PHASE 完了条件未達 |

---

#### REGISTER_DATAPUMP_FILE

```
PROCEDURE REGISTER_DATAPUMP_FILE (
    p_run_id           IN  NUMBER,
    p_job_id           IN  NUMBER,
    p_file_role        IN  VARCHAR2,
    p_file_name        IN  VARCHAR2,
    p_file_path        IN  VARCHAR2 DEFAULT NULL,
    p_storage_location IN  VARCHAR2 DEFAULT NULL,
    p_file_id          OUT NUMBER
);
```

- `DATAPUMP_FILE` を1行 INSERT する（`STATUS='CREATED'`）。
- `DATAPUMP_JOB_ID = p_job_id`、`MIG_RUN_ID = p_run_id` を設定する。
- 採番された `DATAPUMP_FILE_ID` を `p_file_id` で返す。
- `FILE_SIZE_BYTES` / `CHECKSUM_ALGO` / `CHECKSUM_VALUE` は NULL のまま（後続の `VERIFY_DATAPUMP_FILE` で設定）。
- `MIG_STATUS_HISTORY` に `NEW_STATUS='CREATED'` で記録する。
- COMMIT して終了する。

---

#### VERIFY_DATAPUMP_FILE

```
PROCEDURE VERIFY_DATAPUMP_FILE (
    p_file_id          IN NUMBER,
    p_file_size_bytes  IN NUMBER,
    p_checksum_algo    IN VARCHAR2,
    p_checksum_value   IN VARCHAR2
);
```

- ガード条件: `p_checksum_value IS NULL` の場合は例外（-20005）を発生させ、`STATUS` を変更しない。
- 事前条件: `DATAPUMP_FILE.STATUS = 'CREATED'`。それ以外は -20002 例外。
- 合格時: `FILE_SIZE_BYTES` / `CHECKSUM_ALGO` / `CHECKSUM_VALUE` / `VERIFIED_AT = SYSTIMESTAMP` を設定し、`STATUS = 'VERIFIED'` に更新する。
- `MIG_STATUS_HISTORY` に `OLD_STATUS='CREATED'`, `NEW_STATUS='VERIFIED'` で記録する。
- COMMIT して終了する。

---

#### CONSUME_DATAPUMP_FILE

```
PROCEDURE CONSUME_DATAPUMP_FILE (
    p_file_id       IN NUMBER,
    p_import_job_id IN NUMBER
);
```

- 事前条件: `DATAPUMP_FILE.STATUS = 'VERIFIED'`。それ以外は -20002 例外を発生させる。
- `CONSUMED_BY_IMPORT_JOB_ID = p_import_job_id`、`CONSUMED_AT = SYSTIMESTAMP`、`STATUS = 'CONSUMED'`、`UPDATED_AT = SYSTIMESTAMP` を更新する。
- `MIG_STATUS_HISTORY` に `OLD_STATUS='VERIFIED'`, `NEW_STATUS='CONSUMED'` で記録する。
- COMMIT して終了する。

---

#### START_VALIDATION_RUN

```
PROCEDURE START_VALIDATION_RUN (
    p_run_id              IN  NUMBER,
    p_phase_code          IN  VARCHAR2,
    p_validation_type     IN  VARCHAR2,
    p_validation_run_id   OUT NUMBER
);
```

- `VALIDATION_RUN` を1行 INSERT する（`STATUS='RUNNING'`、`STARTED_AT = SYSTIMESTAMP`）。
- 採番された `VALIDATION_RUN_ID` を `p_validation_run_id` で返す。
- `MIG_STATUS_HISTORY` に `NEW_STATUS='RUNNING'` で記録する。
- COMMIT して終了する。

---

#### COMPLETE_VALIDATION_RUN

```
PROCEDURE COMPLETE_VALIDATION_RUN (
    p_validation_run_id IN NUMBER,
    p_overall_result    IN VARCHAR2
);
```

- 事前条件: `VALIDATION_RUN.STATUS = 'RUNNING'`。それ以外は -20002 例外。
- `p_overall_result` は `'PASS'` / `'WARN'` / `'FAIL'` のいずれか（それ以外は -20002 例外）。
- `STATUS = 'COMPLETED'`、`OVERALL_RESULT = p_overall_result`、`FINISHED_AT = SYSTIMESTAMP`、`UPDATED_AT = SYSTIMESTAMP` を更新する。
- `MIG_STATUS_HISTORY` に記録する。
- COMMIT して終了する。

---

#### RECORD_VALIDATION_RESULT

```
PROCEDURE RECORD_VALIDATION_RESULT (
    p_validation_run_id IN  NUMBER,
    p_mig_object_id     IN  NUMBER DEFAULT NULL,
    p_check_name        IN  VARCHAR2,
    p_expected_value    IN  VARCHAR2 DEFAULT NULL,
    p_actual_value      IN  VARCHAR2 DEFAULT NULL,
    p_result            IN  VARCHAR2,
    p_result_id         OUT NUMBER
);
```

- `VALIDATION_RESULT` を1行 INSERT する（`APPROVED_FLAG = 'N'` 固定）。
- 採番された `VALIDATION_RESULT_ID` を `p_result_id` で返す。
- 本 API は COMMIT しない。呼び出し元のトランザクション内で一括 COMMIT することを想定する。
- 大量の検証結果を記録する場合は、本 API を FORALL 等のバルク処理に置き換えてもよい。

---

#### RAISE_ERROR_EVENT

```
PROCEDURE RAISE_ERROR_EVENT (
    p_run_id          IN  NUMBER,
    p_phase_code      IN  VARCHAR2 DEFAULT NULL,
    p_severity        IN  VARCHAR2,
    p_component_name  IN  VARCHAR2 DEFAULT NULL,
    p_datapump_job_id IN  NUMBER   DEFAULT NULL,
    p_ora_error_code  IN  VARCHAR2 DEFAULT NULL,
    p_error_message   IN  VARCHAR2 DEFAULT NULL,
    p_event_id        OUT NUMBER
);
```

- `ERROR_EVENT` を1行 INSERT する（`RESOLVE_STATUS = 'OPEN'`、`CREATED_AT = SYSTIMESTAMP`）。
- 採番された `ERROR_EVENT_ID` を `p_event_id` で返す。
- `PHASE_STATUS` の更新（FAILED / PAUSED 遷移）は呼び出し元が別途行う。本 API はエラー記録のみを担当する。
- COMMIT して終了する。

---

#### COMPLETE_PHASE

```
PROCEDURE COMPLETE_PHASE (
    p_run_id     IN NUMBER,
    p_phase_code IN VARCHAR2
);
```

- `PHASE_STATUS.STATUS` を `COMPLETED` へ遷移させる前に、以下の完了条件を SQL で機械評価する。いずれか1つでも満たさない場合は `-20010` 例外を発生させ、失敗理由を SQLERRM メッセージに含める。
- 全条件を満たした場合のみ `PHASE_STATUS.STATUS = 'COMPLETED'`・`FINISHED_AT = SYSTIMESTAMP` を更新し、`MIG_STATUS_HISTORY` に記録して COMMIT する。

**PHASE1 完了判定条件**（以下を全て SQL で確認する）:

| # | 判定条件 | 対象テーブル/列 |
|---|---|---|
| 1 | そのRUNに属する `OPERATION='EXPORT'` の `DATAPUMP_JOB` が全て `STATUS='COMPLETED'` | `DATAPUMP_JOB` |
| 2 | そのRUNに属する `DATAPUMP_JOB_OBJECT`（EXPORTジョブ配下）が全て `COMPLETED` または `SKIPPED` | `DATAPUMP_JOB_OBJECT` |
| 3 | そのRUNに属する `FILE_ROLE='DUMP'` の `DATAPUMP_FILE` が全て `STATUS IN ('VERIFIED','CONSUMED')` | `DATAPUMP_FILE` |
| 4 | 全 EXPORTジョブの `DATAPUMP_JOB.BASELINE_SCN` が `MIGRATION_RUN.BASELINE_SCN` と一致（NULL でない） | `DATAPUMP_JOB`, `MIGRATION_RUN` |
| 5 | `SEVERITY IN ('FATAL','ERROR')` かつ `RESOLVE_STATUS='OPEN'` の `ERROR_EVENT` がそのRUNに存在しない | `ERROR_EVENT` |
| 6 | そのRUNの全 `MIGRATION_OBJECT` が少なくとも1つの EXPORTジョブに割り当て済み（`EXPORT_GROUP_CODE IS NOT NULL`） | `MIGRATION_OBJECT` |

**PHASE2 完了判定条件**（以下を全て SQL で確認する）:

| # | 判定条件 | 対象テーブル/列 |
|---|---|---|
| 1 | そのRUNに属する `OPERATION='IMPORT'` の `DATAPUMP_JOB` が全て `STATUS='COMPLETED'` | `DATAPUMP_JOB` |
| 2 | そのRUNに属する `DATAPUMP_JOB_OBJECT`（IMPORTジョブ配下）が全て `COMPLETED` または `SKIPPED` | `DATAPUMP_JOB_OBJECT` |
| 3 | Importで使用した `FILE_ROLE='DUMP'` の `DATAPUMP_FILE` に `TARGET_VERIFIED_AT IS NULL` のものが存在しない（DB2.0側でチェックサム再計算済み） | `DATAPUMP_FILE` |
| 4 | そのRUNの `PHASE_CODE='PHASE2'` に属する `VALIDATION_RUN` が `STATUS='COMPLETED'` かつ `OVERALL_RESULT='PASS'` | `VALIDATION_RUN` |
| 5 | そのRUNの `VALIDATION_RESULT` に `RESULT='FAIL'` かつ `APPROVED_FLAG='N'` のレコードが存在しない | `VALIDATION_RESULT` |
| 6 | `SEVERITY IN ('FATAL','ERROR')` かつ `RESOLVE_STATUS='OPEN'` の `ERROR_EVENT` がそのRUNに存在しない | `ERROR_EVENT` |

---

## 9. 既存テーブルとの関連性

### 9.1 log_schema.migration_run_log

`migration_ctl.MIGRATION_RUN` が全フェーズの統合親キーとなる。`log_schema.migration_run_log` はフェーズ5のバッチ処理ステップ詳細ログとして**そのまま存続**させる（廃止しない）。両テーブルの対応は `MIGRATION_RUN.LOG_RUN_ID` のソフト参照（FK 制約なし）で示す。`log_schema` への FK を設けない理由: `log_schema` 構造変更時の波及リスクを避けるため。

DB Link は不要。`log_schema` は DB2.0 の同一 PDB 内に存在する。

### 9.2 cdc_schema.cdc_table_catalog

`MIGRATION_OBJECT` は `cdc_table_catalog` を改変せず参照のみ行う。v1.0 の `CDC_CATALOG_TABLE_NAME` 列（DB Link 前提の誤り）を削除し、代わりに `SOURCE_TABLE_NAME` を使ったクロススキーマ JOIN で同一 PDB 内の `cdc_table_catalog` を参照できる（§6.4 参照クエリ例）。

---

## 10. 次段実装予定（先行準備A 範囲外）

以下のテーブルは先行準備A では作成しない。フェーズ4・5の実装前に追加する。

### フェーズ4・5 実装前に追加（必須）

| テーブル | 目的 | 追加タイミング |
|---|---|---|
| `LOGMINER_BATCH` | LogMiner 解析バッチ単位の管理（開始/終了 SCN・使用ログリスト） | フェーズ4実装前 |
| `MINED_TRANSACTION` | XID レベルのトランザクション表（COMMIT_SCN・状態） | フェーズ4実装前 |
| `MINED_CHANGE` | LogMiner から抽出した DML 明細 | フェーズ4実装前 |
| `APPLY_BATCH` | 差分適用のバッチ単位追跡 | フェーズ4実装前 |
| `APPLY_TASK` | DML 単位の適用・再処理キュー | フェーズ4実装前 |
| `MIG_CHECKPOINT` | コンポーネント・Thread 別の汎用チェックポイント | フェーズ4実装前（注記参照） |

**MIG_CHECKPOINT の注記**: 設計メモ §2.2.2 はフェーズ3にも `MIG_CHECKPOINT` が関わると定義している（`COMPONENT_NAME='ARCHIVE_COLLECTOR'`）。フェーズ3実装時にフェーズ3用途で先行追加するかどうかを**次段で判断すること**。遅くともフェーズ4実装前には追加する。

### 次段以降（本番設計フェーズ）

| テーブル | 目的 |
|---|---|
| `MIGRATION_OBJECT_PHASE_STATUS` | 表×フェーズ単位の詳細状態管理（§2.2 判断事項参照） |
| `TRANSFORM_BATCH` | 変換バッチ単位の管理 |
| `KEY_MAPPING` | 汎用キー対応表（旧キー↔新キー） |

**v3.0 での変更**: `VALIDATION_RUN` / `VALIDATION_RESULT` / `ERROR_EVENT` は、フェーズ2完了判定に直接必要と判明したため、「次段以降」から**フェーズ1・2対応（v3.0）として本設計書の対象に格上げ**した（§3.3「管理スキーマ側の不足」参照）。

---

## 11. Oracle 12c 互換性確認

| 設計要素 | 12c (12.1) 互換性 | 根拠・備考 |
|---|---|---|
| `SEQUENCE` | ○ | 全バージョン標準 |
| `BEFORE INSERT` トリガー | ○ | 全バージョン標準 |
| `IDENTITY` 列 | 使用しない | `oracle-compatibility-policy.md` により禁止。SEQUENCE + トリガー方式を採用。 |
| `TIMESTAMP` 型 | ○ | Oracle 9i 以降。デフォルト精度（6桁小数）を使用。 |
| `NUMBER(20)` 型（SCN 用） | ○ | NUMBER は全バージョン標準。 |
| `CHAR(1)` 型（フラグ用） | ○ | 全バージョン標準。 |
| `VARCHAR2(4000)` | ○ | STANDARD モード上限以内。 |
| `DEFAULT SYSTIMESTAMP` | ○ | Oracle 9i 以降。 |
| `CHECK` 制約（IN リスト） | ○ | 標準 SQL。全バージョン対応。 |
| `UNIQUE` 制約（複合列） | ○ | 標準 SQL。全バージョン対応。 |
| `FOREIGN KEY` 制約 | ○（`migration_ctl` 内のみ） | クロススキーマ FK は使用しない。 |
| `JSON_*` 関数 | 使用しない | 12c R2 以降限定のため禁止。 |
| `FETCH FIRST` / `OFFSET` | 使用しない | バージョン依存のため禁止。 |
| `WITH FUNCTION` | 使用しない | 禁止。通常パッケージ関数で代替。 |
| 識別子長（30文字上限） | ○ | 全制約名・トリガー名・シーケンス名を30文字以内に収めている（12.1 上限）。 |

---

## 12. 設計レビューチェックリスト

**v2.0 からの継続確認事項**:

- [x] 移行ロジックが PL/SQL 内に完結しているか（本設計は DDL/データモデルのみ。PL/SQL 実装は implementation-engineer の担当）
- [x] DB Link を使用しない設計か（§3.1：すべてのスキーマは DB2.0 同一 PDB 内）
- [x] ステージングテーブルを使用しない設計か
- [x] BASELINE_SCN と MINING_START_SCN が別カラムとして設計されているか
- [x] TARGET_END_SCN・LAST_APPLIED_SCN が追加されているか（§15.1 対応）
- [x] PoC / REHEARSAL / PRODUCTION の実行種別が区別できるか（`RUN_TYPE` 列）
- [x] 7フェーズ分の状態追跡テーブルが設計されているか（`PHASE_STATUS.PHASE_CODE`）
- [x] 状態値に DONE が使われておらず COMPLETED で統一されているか
- [x] MIG_STATUS_HISTORY が追記専用で設計されているか（§8.2 不変条件）
- [x] ファイル実体なしで VERIFIED にしない不変条件が記載されているか（§8.2）
- [x] IDENTITY 列を使用していないか（SEQUENCE + BEFORE INSERT トリガーで代替済み）
- [x] 全識別子が Oracle 12.1 の30文字上限以内か（§6 各 DDL ドラフト参照・§6.14 ALTER TABLE 制約名含む）
- [x] JSON 関数・FETCH FIRST 等の禁止構文を使用していないか
- [x] クロススキーマ FK を設けず、既存テーブルへの影響がゼロか
- [x] 途中失敗後の再実行方針が記載されているか（§6.3 利用パターン参照）
- [x] PKG_MIG_ADMIN の API 仕様が設計書に記載されているか（§8）
- [x] PHASE_STATUS 7行採用の根拠が記録されているか（§2.1）
- [x] MIGRATION_OBJECT_PHASE_STATUS が次段であることが明記されているか（§2.2・§10）
- [x] MIG_CHECKPOINT が先行準備A外であることと次段判断事項が明記されているか（§2.3・§10）
- [x] DDL 変更方式（全体再作成 v2.0 / 新規ファイル追加 v3.0）の根拠が記録されているか（§2.4・§2.5）

**v3.0 追加確認事項**:

- [x] フェーズ1・2の完了判定条件が SQL で機械評価される設計になっているか（`COMPLETE_PHASE` §8.3）
- [x] `ERROR_EVENT` にエラー原因を追える情報（PHASE_CODE / SEVERITY / ORA_ERROR_CODE / ERROR_MESSAGE）が含まれるか（§6.11）
- [x] `COMPLETE_PHASE` の PHASE1 判定に未解消 FATAL/ERROR イベントのチェックが含まれるか（§8.3）
- [x] `COMPLETE_PHASE` の PHASE2 判定に検証結果（VALIDATION_RUN / VALIDATION_RESULT）のチェックが含まれるか（§8.3）
- [x] `DATAPUMP_FILE.STATUS='CONSUMED'` への遷移に `VERIFIED` が事前条件として設計されているか（§8.2 不変条件6・§8.3 CONSUME_DATAPUMP_FILE）
- [x] `VERIFY_DATAPUMP_FILE` でチェックサム NULL 時に例外（-20005）を発生させる設計か（§8.3）
- [x] `VALIDATION_RESULT` の FAIL 承認（`APPROVED_FLAG`）が PHASE2 完了判定に組み込まれているか（§8.3）
- [x] 新規テーブル3本（ERROR_EVENT / VALIDATION_RUN / VALIDATION_RESULT）の制約名が全て30文字以内か（§6.11〜§6.13 DDL参照）
- [x] ALTER TABLE での列追加・CHECK制約再作成が既存ファイル非修正の形で設計されているか（§2.5・§6.14）
- [x] `PHASE_STATUS.APPROVAL_STATUS` の CHECK制約が NULL 許容になっているか（§6.14.4）
- [x] `DATAPUMP_JOB.TABLE_EXISTS_ACTION` の CHECK制約が NULL 許容になっているか（§6.14.2）
- [x] `VALIDATION_RUN.OVERALL_RESULT` の CHECK制約が NULL 許容になっているか（§6.12 DDL）
- [x] v3.0 で「次段以降」から格上げされたテーブル（ERROR_EVENT 等）が §10 で明記されているか（§10）
