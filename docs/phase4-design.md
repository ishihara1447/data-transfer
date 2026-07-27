# フェーズ4（Archived Redo 解析・差分反映）設計文書

- 作成日: 2026-07-27
- 設計根拠: `docs/private/design-memo-2-5phase.md`（§6 全体・§15.2）
- 前提文書: `docs/migration-control-schema-design.md` v4.0、`docs/oracle-compatibility-policy.md`
- 参照: `docs/phase3-design.md`（直前フェーズ設計パターン）、`docs/handoff-guide.md` §4 / §5

---

## 1. 設計の目的

### 1.1 フェーズ4の完了状態定義（設計メモ §6.1 準拠）

フェーズ4が完了した状態とは、以下のすべてを満たすことをいう。

1. DB1.0 の Archived Redo を DB2.0 の LogMiner で解析できる。
2. INSERT・UPDATE・DELETE、COMMIT、ROLLBACK、長時間トランザクションを正しく扱える。
3. ROWID に依存せず、主キーで DB2.0 側 1.0 スキーマへ反映できる。
4. 同じバッチを再実行してもデータを破壊しない（冪等性）。
5. 基準 SCN から最終 SCN まで、欠落なく DB1.0 と DB2.0 側 1.0 スキーマを一致させられる。
6. `MIG_CHECKPOINT`（`COMPONENT_NAME='APPLY_WRITER'`）の `CHECKPOINT_SCN` が `TARGET_END_SCN` 以上に到達していることが確認できる。

### 1.2 フェーズ4の4層構造（§6.2.1）

設計メモ §6.2.1 が定義する処理単位の4層構造。各層がログから差分適用までの追跡性を保証する。

```text
Archived Redo（物理ファイル）
  ↓ LogMiner で解析範囲を指定
LOGMINER_BATCH              解析範囲（SCN範囲）の管理単位
  ├─ LOGMINER_BATCH_LOG     解析に使用した Archived Redo の対応記録
  ├─ MINED_TRANSACTION      コミット済みトランザクション（XID単位）
  └─ MINED_CHANGE           DML明細（V$LOGMNR_CONTENTS の1行に対応）
          ↓ キュー化・適用対象フィルタリング
APPLY_BATCH                 1.0スキーマへの反映範囲（COMMIT_SCN範囲）の管理単位
  └─ APPLY_TASK             DML単位の反映・再処理キュー
          ↓ 同一DBトランザクションで COMMIT
MIG_CHECKPOINT              処理済み位置（解析済みSCN・適用済みCOMMIT_SCN）
```

---

## 2. アーキテクチャ

### 2.1 全体の処理フロー

```text
oracle-src（DB1.0相当）         /migfs（共有ボリューム）         oracle-tgt（DB2.0相当）
  CDB$ROOT                        Archived Redo                 MIGRATION_CTL スキーマ
    │                             収集済みファイル群                     │
    └─ Archived Redo ──────────────────────────────────────→ LogMiner
                                                            DBMS_LOGMNR.ADD_LOGFILE
                                                            DBMS_LOGMNR.START_LOGMNR
                                                            V$LOGMNR_CONTENTS
                                                                   │
                                                           LOGMINER_BATCH 登録
                                                           MINED_TRANSACTION 一括登録
                                                           MINED_CHANGE 一括登録
                                                                   │
                                                           APPLY_BATCH 登録
                                                           APPLY_TASK 生成・実行
                                                                   │
                                                        1.0スキーマへ DML 反映
                                                           MIG_CHECKPOINT 更新
                                                                   ↓ COMMIT
```

### 2.2 段別実装方針

| 段 | 範囲 | 対象ファイル |
|---|---|---|
| 段1（本文書の設計対象） | 管理テーブル DDL・PKG_MIG_ADMIN Phase4 API | `sql/migration_ctl/09_phase4_tables.sql` / `sql/migration_ctl/10_pkg_mig_admin_phase4.sql` |
| 段2 | LogMiner 解析・MINED_CHANGE 登録 | 次段設計（§10 参照） |
| 段3 | APPLY_TASK 実行・差分反映 | 次段設計（§10 参照） |

テストスクリプト: `scripts/72_test_phase4_tables_e2e.sh`

### 2.3 LogMiner 解析前後の管理テーブル更新（§6.2.2 準拠）

| タイミング | 操作 | テーブル | 登録・更新内容 |
|---|---|---|---|
| 解析範囲決定時 | INSERT | `LOGMINER_BATCH` | FROM_SCN、TO_SCN、DICT_METHOD、オプション、バッチ番号 |
| 使用ログ決定時 | INSERT | `LOGMINER_BATCH_LOG` | 使用する ARCHIVE_LOG_ID、追加順序 |
| 解析開始時 | UPDATE | `LOGMINER_BATCH` | STATUS='RUNNING'、STARTED_AT |
| 同上 | UPDATE | `ARCHIVE_LOG` | 対象ログの MINING_STATUS='MINING' |
| フェーズ4初回開始時 | UPDATE | `PHASE_STATUS` | PHASE4 を RUNNING |
| 同上 | UPDATE | `MIGRATION_RUN` | STATUS='RUNNING' |
| 解析完了後 | INSERT | `MINED_TRANSACTION` | バルク登録 |
| 同上 | INSERT | `MINED_CHANGE` | バルク登録（SQL_REDO/SQL_UNDO は後続処理で設定） |
| 解析終了時 | UPDATE | `LOGMINER_BATCH` | CHANGE_COUNT、TRANSACTION_COUNT、FINISHED_AT、STATUS |
| 同上 | UPDATE | `ARCHIVE_LOG` | MINING_STATUS='MINED' |
| 同上 | UPSERT | `MIG_CHECKPOINT` | LOGMINER_READER / 解析済み位置 |

---

## 3. テーブル設計仕様

Oracle 12c 互換制約（すべてのテーブルに適用）:
- IDENTITY 列禁止 → SEQUENCE + BEFORE INSERT トリガーで採番
- 識別子は Oracle 12.1 上限の 30 文字以内
- VARCHAR2(4000) が上限（`MAX_STRING_SIZE=EXTENDED` を前提にしない）
- `JSON_*` 関数は使用しない

---

### 3.1 LOGMINER_BATCH（解析範囲管理）

#### 設計意図

LogMiner の1回の実行単位（SCN範囲）を管理する。1バッチが使用した Archived Redo ファイルとの対応は `LOGMINER_BATCH_LOG` で保持する。バッチ境界の重複解析・再実行に備え `BATCH_NO` を `(MIG_RUN_ID, BATCH_NO)` の UNIQUE 制約で管理する。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| LOGMINER_BATCH_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | — | FK: `MIGRATION_RUN.MIG_RUN_ID` |
| BATCH_NO | NUMBER(10) | YES | — | バッチ通番（MIG_RUN_ID 内で一意） |
| FROM_SCN | NUMBER(20) | YES | — | 解析開始 SCN |
| TO_SCN | NUMBER(20) | YES | — | 解析終了 SCN |
| DICT_METHOD | VARCHAR2(50) | YES | — | CHECK: `'DICT_FROM_REDO_LOGS','DICT_FROM_ONLINE_CATALOG'` |
| LOGMNR_OPTIONS | VARCHAR2(500) | NO | NULL | DBMS_LOGMNR.START_LOGMNR オプション文字列 |
| STATUS | VARCHAR2(20) | YES | `'PLANNED'` | CHECK: `'PLANNED','RUNNING','COMPLETED','FAILED','RETRY'` |
| CHANGE_COUNT | NUMBER(20) | NO | NULL | 解析で取得した変更件数（完了後に設定） |
| TRANSACTION_COUNT | NUMBER(20) | NO | NULL | 解析で取得したトランザクション数 |
| STARTED_AT | TIMESTAMP | NO | NULL | 解析開始日時 |
| FINISHED_AT | TIMESTAMP | NO | NULL | 解析完了日時 |
| ERROR_MESSAGE | VARCHAR2(4000) | NO | NULL | 失敗時のエラーメッセージ |
| REMARKS | VARCHAR2(4000) | NO | NULL | 備考 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時 |

#### 制約

| 種別 | 制約名 | 定義 |
|---|---|---|
| PK | `PK_LOGMINER_BATCH` | `LOGMINER_BATCH_ID` |
| FK | `FK_LOGMINER_BATCH_RUN` | `MIG_RUN_ID` → `MIGRATION_RUN.MIG_RUN_ID` |
| UQ | `UQ_LOGMINER_BATCH_NO` | `(MIG_RUN_ID, BATCH_NO)` |
| CHECK | `CHK_LOGMINER_BATCH_STS` | `STATUS IN ('PLANNED','RUNNING','COMPLETED','FAILED','RETRY')` |
| CHECK | `CHK_LOGMINER_BATCH_DM` | `DICT_METHOD IN ('DICT_FROM_REDO_LOGS','DICT_FROM_ONLINE_CATALOG')` |

#### DDL スケッチ

```sql
CREATE SEQUENCE SEQ_LOGMINER_BATCH
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE LOGMINER_BATCH (
    LOGMINER_BATCH_ID  NUMBER(10)     NOT NULL,
    MIG_RUN_ID         NUMBER(10)     NOT NULL,
    BATCH_NO           NUMBER(10)     NOT NULL,
    FROM_SCN           NUMBER(20)     NOT NULL,
    TO_SCN             NUMBER(20)     NOT NULL,
    DICT_METHOD        VARCHAR2(50)   NOT NULL,
    LOGMNR_OPTIONS     VARCHAR2(500),
    STATUS             VARCHAR2(20)   DEFAULT 'PLANNED' NOT NULL,
    CHANGE_COUNT       NUMBER(20),
    TRANSACTION_COUNT  NUMBER(20),
    STARTED_AT         TIMESTAMP,
    FINISHED_AT        TIMESTAMP,
    ERROR_MESSAGE      VARCHAR2(4000),
    REMARKS            VARCHAR2(4000),
    CREATED_AT         TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT         TIMESTAMP,
    CONSTRAINT PK_LOGMINER_BATCH
        PRIMARY KEY (LOGMINER_BATCH_ID),
    CONSTRAINT FK_LOGMINER_BATCH_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT UQ_LOGMINER_BATCH_NO
        UNIQUE (MIG_RUN_ID, BATCH_NO),
    CONSTRAINT CHK_LOGMINER_BATCH_STS
        CHECK (STATUS IN
               ('PLANNED','RUNNING','COMPLETED','FAILED','RETRY')),
    CONSTRAINT CHK_LOGMINER_BATCH_DM
        CHECK (DICT_METHOD IN
               ('DICT_FROM_REDO_LOGS','DICT_FROM_ONLINE_CATALOG'))
);

CREATE OR REPLACE TRIGGER TRG_LOGMINER_BATCH_BI
BEFORE INSERT ON LOGMINER_BATCH
FOR EACH ROW
BEGIN
    IF :NEW.LOGMINER_BATCH_ID IS NULL THEN
        SELECT SEQ_LOGMINER_BATCH.NEXTVAL
        INTO :NEW.LOGMINER_BATCH_ID FROM DUAL;
    END IF;
END;
/
```

---

### 3.2 LOGMINER_BATCH_LOG（バッチ × Archived Redo 対応）

#### 設計意図

`LOGMINER_BATCH` と `ARCHIVE_LOG` の N:M 中間テーブル。1バッチが複数の Archived Redo を `DBMS_LOGMNR.ADD_LOGFILE` で追加した順序を `ADD_ORDER` で記録する。この順序は CSF 分割行の再構成（§10.2）の前提情報になる。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| BATCH_LOG_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| LOGMINER_BATCH_ID | NUMBER(10) | YES | — | FK: `LOGMINER_BATCH.LOGMINER_BATCH_ID` |
| ARCHIVE_LOG_ID | NUMBER(10) | YES | — | FK: `ARCHIVE_LOG.ARCHIVE_LOG_ID` |
| ADD_ORDER | NUMBER(5) | YES | — | ADD_LOGFILE の追加順序（1から始まる連番） |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時 |

#### 制約

| 種別 | 制約名 | 定義 |
|---|---|---|
| PK | `PK_LOGMINER_BATCH_LOG` | `BATCH_LOG_ID` |
| FK | `FK_LOGMNR_BATCH_LOG_BATCH` | `LOGMINER_BATCH_ID` → `LOGMINER_BATCH.LOGMINER_BATCH_ID` |
| FK | `FK_LOGMNR_BATCH_LOG_ARC` | `ARCHIVE_LOG_ID` → `ARCHIVE_LOG.ARCHIVE_LOG_ID` |
| UQ | `UQ_LOGMINER_BATCH_LOG` | `(LOGMINER_BATCH_ID, ARCHIVE_LOG_ID)` |

#### DDL スケッチ

```sql
CREATE SEQUENCE SEQ_LOGMINER_BATCH_LOG
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE LOGMINER_BATCH_LOG (
    BATCH_LOG_ID        NUMBER(10)   NOT NULL,
    LOGMINER_BATCH_ID   NUMBER(10)   NOT NULL,
    ARCHIVE_LOG_ID      NUMBER(10)   NOT NULL,
    ADD_ORDER           NUMBER(5)    NOT NULL,
    CREATED_AT          TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT PK_LOGMINER_BATCH_LOG
        PRIMARY KEY (BATCH_LOG_ID),
    CONSTRAINT FK_LOGMNR_BATCH_LOG_BATCH
        FOREIGN KEY (LOGMINER_BATCH_ID)
        REFERENCES LOGMINER_BATCH (LOGMINER_BATCH_ID),
    CONSTRAINT FK_LOGMNR_BATCH_LOG_ARC
        FOREIGN KEY (ARCHIVE_LOG_ID)
        REFERENCES ARCHIVE_LOG (ARCHIVE_LOG_ID),
    CONSTRAINT UQ_LOGMINER_BATCH_LOG
        UNIQUE (LOGMINER_BATCH_ID, ARCHIVE_LOG_ID)
);

CREATE OR REPLACE TRIGGER TRG_LOGMINER_BATCH_LOG_BI
BEFORE INSERT ON LOGMINER_BATCH_LOG
FOR EACH ROW
BEGIN
    IF :NEW.BATCH_LOG_ID IS NULL THEN
        SELECT SEQ_LOGMINER_BATCH_LOG.NEXTVAL
        INTO :NEW.BATCH_LOG_ID FROM DUAL;
    END IF;
END;
/
```

---

### 3.3 MINED_TRANSACTION（コミット済みトランザクション）

#### 設計意図

LogMiner が解析した XID 単位のトランザクションを管理する。`COMMIT_SCN` は差分適用の順序制御に使用する。重複防止キー `(MIG_RUN_ID, XID, COMMIT_SCN)` により、同一バッチを再実行した場合のトランザクション重複 INSERT を防ぐ（§6.2.3）。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| MINED_TRANSACTION_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | — | FK: `MIGRATION_RUN.MIG_RUN_ID` |
| LOGMINER_BATCH_ID | NUMBER(10) | YES | — | FK: `LOGMINER_BATCH.LOGMINER_BATCH_ID` |
| XID | VARCHAR2(50) | YES | — | Oracle トランザクション識別子（例: `0001.00a2.0000c8f0`） |
| START_SCN | NUMBER(20) | NO | NULL | トランザクション開始 SCN |
| COMMIT_SCN | NUMBER(20) | YES | — | コミット SCN（差分適用順序の基準） |
| STATUS | VARCHAR2(20) | YES | `'MINED'` | CHECK: `'MINED','QUEUED','APPLIED','SKIPPED','ERROR'` |
| CHANGE_COUNT | NUMBER(20) | NO | NULL | このトランザクション内の変更件数 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時 |

#### 制約

| 種別 | 制約名 | 定義 |
|---|---|---|
| PK | `PK_MINED_TRANSACTION` | `MINED_TRANSACTION_ID` |
| FK | `FK_MINED_TX_RUN` | `MIG_RUN_ID` → `MIGRATION_RUN.MIG_RUN_ID` |
| FK | `FK_MINED_TX_BATCH` | `LOGMINER_BATCH_ID` → `LOGMINER_BATCH.LOGMINER_BATCH_ID` |
| UQ | `UQ_MINED_TX_KEY` | `(MIG_RUN_ID, XID, COMMIT_SCN)`（重複防止キー） |
| CHECK | `CHK_MINED_TX_STS` | `STATUS IN ('MINED','QUEUED','APPLIED','SKIPPED','ERROR')` |

#### DDL スケッチ

```sql
CREATE SEQUENCE SEQ_MINED_TRANSACTION
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE MINED_TRANSACTION (
    MINED_TRANSACTION_ID  NUMBER(10)    NOT NULL,
    MIG_RUN_ID            NUMBER(10)    NOT NULL,
    LOGMINER_BATCH_ID     NUMBER(10)    NOT NULL,
    XID                   VARCHAR2(50)  NOT NULL,
    START_SCN             NUMBER(20),
    COMMIT_SCN            NUMBER(20)    NOT NULL,
    STATUS                VARCHAR2(20)  DEFAULT 'MINED' NOT NULL,
    CHANGE_COUNT          NUMBER(20),
    CREATED_AT            TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT            TIMESTAMP,
    CONSTRAINT PK_MINED_TRANSACTION
        PRIMARY KEY (MINED_TRANSACTION_ID),
    CONSTRAINT FK_MINED_TX_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT FK_MINED_TX_BATCH
        FOREIGN KEY (LOGMINER_BATCH_ID)
        REFERENCES LOGMINER_BATCH (LOGMINER_BATCH_ID),
    CONSTRAINT UQ_MINED_TX_KEY
        UNIQUE (MIG_RUN_ID, XID, COMMIT_SCN),
    CONSTRAINT CHK_MINED_TX_STS
        CHECK (STATUS IN
               ('MINED','QUEUED','APPLIED','SKIPPED','ERROR'))
);

CREATE OR REPLACE TRIGGER TRG_MINED_TRANSACTION_BI
BEFORE INSERT ON MINED_TRANSACTION
FOR EACH ROW
BEGIN
    IF :NEW.MINED_TRANSACTION_ID IS NULL THEN
        SELECT SEQ_MINED_TRANSACTION.NEXTVAL
        INTO :NEW.MINED_TRANSACTION_ID FROM DUAL;
    END IF;
END;
/
```

---

### 3.4 MINED_CHANGE（DML 明細）

#### 設計意図

`V$LOGMNR_CONTENTS` の1行に対応する DML 明細を保持する大量行テーブル。`SQL_REDO` / `SQL_UNDO` は CLOB 型とし、CSF 分割行の再構成後の完全な SQL を格納する（§10.2 参照）。重複防止キー `(MIG_RUN_ID, RS_ID, SSN)` により、同一バッチ再実行時の重複 INSERT を防ぐ（§6.2.3）。

CSF（Continuation Flag）= 1 は SQL が次の行に継続することを示す。再構成後は CSF=0 の行に完全な SQL を格納し、CSF=1 の行は SKIPPED として記録する。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| MINED_CHANGE_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | — | FK: `MIGRATION_RUN.MIG_RUN_ID` |
| MINED_TRANSACTION_ID | NUMBER(10) | YES | — | FK: `MINED_TRANSACTION.MINED_TRANSACTION_ID` |
| LOGMINER_BATCH_ID | NUMBER(10) | YES | — | FK: `LOGMINER_BATCH.LOGMINER_BATCH_ID` |
| RS_ID | VARCHAR2(100) | YES | — | LogMiner Row Set ID（CSF分割行の識別キー構成要素） |
| SSN | NUMBER(20) | YES | — | SQL Sequence Number（CSF分割行の順序） |
| SCN | NUMBER(20) | NO | NULL | 変更 SCN |
| COMMIT_SCN | NUMBER(20) | NO | NULL | 属するトランザクションのコミット SCN |
| OPERATION | VARCHAR2(20) | YES | — | CHECK: `'INSERT','UPDATE','DELETE','COMMIT','ROLLBACK'` |
| SEG_OWNER | VARCHAR2(100) | NO | NULL | 対象テーブルのスキーマ名 |
| TABLE_NAME | VARCHAR2(100) | NO | NULL | 対象テーブル名 |
| CSF | NUMBER(1) | YES | `0` | CSF フラグ: 0=最終行（完結）、1=継続行 |
| SQL_REDO | CLOB | NO | NULL | 再実行 SQL（CSF 分割行は再構成後の完全 SQL を格納） |
| SQL_UNDO | CLOB | NO | NULL | アンドゥ SQL（同上） |
| STATUS | VARCHAR2(20) | YES | `'MINED'` | CHECK: `'MINED','QUEUED','APPLIED','SKIPPED','ERROR'` |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時 |

> 🟡 **仮決定 TMP-12 参照** — `SQL_REDO` / `SQL_UNDO` を CLOB として保持する方針を採用したが、保持期間・圧縮・パーティション化は未決定。`docs/handoff-guide.md` §4 TMP-12 を参照。

#### 制約

| 種別 | 制約名 | 定義 |
|---|---|---|
| PK | `PK_MINED_CHANGE` | `MINED_CHANGE_ID` |
| FK | `FK_MINED_CHANGE_RUN` | `MIG_RUN_ID` → `MIGRATION_RUN.MIG_RUN_ID` |
| FK | `FK_MINED_CHANGE_TX` | `MINED_TRANSACTION_ID` → `MINED_TRANSACTION.MINED_TRANSACTION_ID` |
| FK | `FK_MINED_CHANGE_BATCH` | `LOGMINER_BATCH_ID` → `LOGMINER_BATCH.LOGMINER_BATCH_ID` |
| UQ | `UQ_MINED_CHANGE_KEY` | `(MIG_RUN_ID, RS_ID, SSN)`（重複防止キー） |
| CHECK | `CHK_MINED_CHANGE_OP` | `OPERATION IN ('INSERT','UPDATE','DELETE','COMMIT','ROLLBACK')` |
| CHECK | `CHK_MINED_CHANGE_CSF` | `CSF IN (0, 1)` |
| CHECK | `CHK_MINED_CHANGE_STS` | `STATUS IN ('MINED','QUEUED','APPLIED','SKIPPED','ERROR')` |

#### DDL スケッチ

```sql
CREATE SEQUENCE SEQ_MINED_CHANGE
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE MINED_CHANGE (
    MINED_CHANGE_ID       NUMBER(10)    NOT NULL,
    MIG_RUN_ID            NUMBER(10)    NOT NULL,
    MINED_TRANSACTION_ID  NUMBER(10)    NOT NULL,
    LOGMINER_BATCH_ID     NUMBER(10)    NOT NULL,
    RS_ID                 VARCHAR2(100) NOT NULL,
    SSN                   NUMBER(20)    NOT NULL,
    SCN                   NUMBER(20),
    COMMIT_SCN            NUMBER(20),
    OPERATION             VARCHAR2(20)  NOT NULL,
    SEG_OWNER             VARCHAR2(100),
    TABLE_NAME            VARCHAR2(100),
    CSF                   NUMBER(1)     DEFAULT 0 NOT NULL,
    SQL_REDO              CLOB,
    SQL_UNDO              CLOB,
    STATUS                VARCHAR2(20)  DEFAULT 'MINED' NOT NULL,
    CREATED_AT            TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT            TIMESTAMP,
    CONSTRAINT PK_MINED_CHANGE
        PRIMARY KEY (MINED_CHANGE_ID),
    CONSTRAINT FK_MINED_CHANGE_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT FK_MINED_CHANGE_TX
        FOREIGN KEY (MINED_TRANSACTION_ID)
        REFERENCES MINED_TRANSACTION (MINED_TRANSACTION_ID),
    CONSTRAINT FK_MINED_CHANGE_BATCH
        FOREIGN KEY (LOGMINER_BATCH_ID)
        REFERENCES LOGMINER_BATCH (LOGMINER_BATCH_ID),
    CONSTRAINT UQ_MINED_CHANGE_KEY
        UNIQUE (MIG_RUN_ID, RS_ID, SSN),
    CONSTRAINT CHK_MINED_CHANGE_OP
        CHECK (OPERATION IN
               ('INSERT','UPDATE','DELETE','COMMIT','ROLLBACK')),
    CONSTRAINT CHK_MINED_CHANGE_CSF
        CHECK (CSF IN (0, 1)),
    CONSTRAINT CHK_MINED_CHANGE_STS
        CHECK (STATUS IN
               ('MINED','QUEUED','APPLIED','SKIPPED','ERROR'))
);

CREATE OR REPLACE TRIGGER TRG_MINED_CHANGE_BI
BEFORE INSERT ON MINED_CHANGE
FOR EACH ROW
BEGIN
    IF :NEW.MINED_CHANGE_ID IS NULL THEN
        SELECT SEQ_MINED_CHANGE.NEXTVAL
        INTO :NEW.MINED_CHANGE_ID FROM DUAL;
    END IF;
END;
/
```

---

### 3.5 APPLY_BATCH（差分適用範囲管理）

#### 設計意図

1.0 スキーマへの差分適用の1実行単位を管理する。`FROM_COMMIT_SCN`・`TO_COMMIT_SCN` で MINED_CHANGE の適用対象範囲を指定する。完了後は `APPLIED_COUNT`・`SKIPPED_COUNT`・`ERROR_COUNT` で結果を記録する。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| APPLY_BATCH_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | — | FK: `MIGRATION_RUN.MIG_RUN_ID` |
| BATCH_NO | NUMBER(10) | YES | — | バッチ通番（MIG_RUN_ID 内で一意） |
| FROM_COMMIT_SCN | NUMBER(20) | YES | — | 適用対象 COMMIT_SCN の下限（含む） |
| TO_COMMIT_SCN | NUMBER(20) | YES | — | 適用対象 COMMIT_SCN の上限（含む） |
| STATUS | VARCHAR2(20) | YES | `'PLANNED'` | CHECK: `'PLANNED','RUNNING','COMPLETED','FAILED','RETRY'` |
| APPLIED_COUNT | NUMBER(20) | NO | NULL | 適用成功件数 |
| SKIPPED_COUNT | NUMBER(20) | NO | NULL | スキップ件数 |
| ERROR_COUNT | NUMBER(20) | NO | NULL | エラー件数 |
| STARTED_AT | TIMESTAMP | NO | NULL | 適用開始日時 |
| FINISHED_AT | TIMESTAMP | NO | NULL | 適用完了日時 |
| ERROR_MESSAGE | VARCHAR2(4000) | NO | NULL | 失敗時のエラーメッセージ |
| REMARKS | VARCHAR2(4000) | NO | NULL | 備考 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時 |

#### 制約

| 種別 | 制約名 | 定義 |
|---|---|---|
| PK | `PK_APPLY_BATCH` | `APPLY_BATCH_ID` |
| FK | `FK_APPLY_BATCH_RUN` | `MIG_RUN_ID` → `MIGRATION_RUN.MIG_RUN_ID` |
| UQ | `UQ_APPLY_BATCH_NO` | `(MIG_RUN_ID, BATCH_NO)` |
| CHECK | `CHK_APPLY_BATCH_STS` | `STATUS IN ('PLANNED','RUNNING','COMPLETED','FAILED','RETRY')` |

#### DDL スケッチ

```sql
CREATE SEQUENCE SEQ_APPLY_BATCH
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE APPLY_BATCH (
    APPLY_BATCH_ID    NUMBER(10)     NOT NULL,
    MIG_RUN_ID        NUMBER(10)     NOT NULL,
    BATCH_NO          NUMBER(10)     NOT NULL,
    FROM_COMMIT_SCN   NUMBER(20)     NOT NULL,
    TO_COMMIT_SCN     NUMBER(20)     NOT NULL,
    STATUS            VARCHAR2(20)   DEFAULT 'PLANNED' NOT NULL,
    APPLIED_COUNT     NUMBER(20),
    SKIPPED_COUNT     NUMBER(20),
    ERROR_COUNT       NUMBER(20),
    STARTED_AT        TIMESTAMP,
    FINISHED_AT       TIMESTAMP,
    ERROR_MESSAGE     VARCHAR2(4000),
    REMARKS           VARCHAR2(4000),
    CREATED_AT        TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT        TIMESTAMP,
    CONSTRAINT PK_APPLY_BATCH
        PRIMARY KEY (APPLY_BATCH_ID),
    CONSTRAINT FK_APPLY_BATCH_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT UQ_APPLY_BATCH_NO
        UNIQUE (MIG_RUN_ID, BATCH_NO),
    CONSTRAINT CHK_APPLY_BATCH_STS
        CHECK (STATUS IN
               ('PLANNED','RUNNING','COMPLETED','FAILED','RETRY'))
);

CREATE OR REPLACE TRIGGER TRG_APPLY_BATCH_BI
BEFORE INSERT ON APPLY_BATCH
FOR EACH ROW
BEGIN
    IF :NEW.APPLY_BATCH_ID IS NULL THEN
        SELECT SEQ_APPLY_BATCH.NEXTVAL
        INTO :NEW.APPLY_BATCH_ID FROM DUAL;
    END IF;
END;
/
```

---

### 3.6 APPLY_TASK（DML 単位の適用・再処理キュー）

#### 設計意図

`MINED_CHANGE` の1件を1.0スキーマへ反映する最小単位。`KEY_PAYLOAD` に主キー情報を保持することで ROWID に依存しない適用を実現する（設計メモ §6.2.4）。再処理では新たな APPLY_TASK を重複作成せず、`STATUS='RETRY'` に戻す設計とする。

`DML_TEXT` は監査・再処理参照用であり、実行時はバインド変数方式を優先する。VARCHAR2(4000) を超える DML については参照用テキストは切り捨てられる可能性があることに留意する。`ERROR_EVENT_ID` は失敗時のみ設定され、正常完了時は NULL のまま残る。

#### カラム定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| APPLY_TASK_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| APPLY_BATCH_ID | NUMBER(10) | YES | — | FK: `APPLY_BATCH.APPLY_BATCH_ID` |
| MINED_CHANGE_ID | NUMBER(10) | YES | — | FK: `MINED_CHANGE.MINED_CHANGE_ID` |
| ERROR_EVENT_ID | NUMBER(10) | NO | NULL | FK: `ERROR_EVENT.ERROR_EVENT_ID`（失敗時のみ設定） |
| MIG_RUN_ID | NUMBER(10) | YES | — | 集計・フィルタ用（FK制約なし） |
| SEG_OWNER | VARCHAR2(100) | NO | NULL | 適用先スキーマ名 |
| TABLE_NAME | VARCHAR2(100) | NO | NULL | 適用先テーブル名 |
| DML_TYPE | VARCHAR2(10) | YES | — | CHECK: `'INSERT','UPDATE','DELETE'` |
| KEY_PAYLOAD | VARCHAR2(4000) | NO | NULL | 主キー値（キー名=値形式のテキスト。ROWID不使用） |
| DML_TEXT | VARCHAR2(4000) | NO | NULL | 実行 DML（監査・再処理参照用。4000文字を超える場合は切り捨て） |
| STATUS | VARCHAR2(20) | YES | `'PENDING'` | CHECK: `'PENDING','RUNNING','APPLIED','RETRY','ERROR','SKIPPED'` |
| RETRY_COUNT | NUMBER(5) | YES | `0` | 再試行回数 |
| EXECUTED_BY | VARCHAR2(100) | NO | NULL | 実行者（プロセス名・セッション識別子等） |
| STARTED_AT | TIMESTAMP | NO | NULL | タスク取得（RUNNING 遷移）日時 |
| APPLIED_AT | TIMESTAMP | NO | NULL | 適用成功日時 |
| ERROR_MESSAGE | VARCHAR2(4000) | NO | NULL | エラーメッセージ（直近の失敗内容） |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時 |

#### 制約

| 種別 | 制約名 | 定義 |
|---|---|---|
| PK | `PK_APPLY_TASK` | `APPLY_TASK_ID` |
| FK | `FK_APPLY_TASK_BATCH` | `APPLY_BATCH_ID` → `APPLY_BATCH.APPLY_BATCH_ID` |
| FK | `FK_APPLY_TASK_CHANGE` | `MINED_CHANGE_ID` → `MINED_CHANGE.MINED_CHANGE_ID` |
| FK | `FK_APPLY_TASK_ERR` | `ERROR_EVENT_ID` → `ERROR_EVENT.ERROR_EVENT_ID` |
| CHECK | `CHK_APPLY_TASK_STS` | `STATUS IN ('PENDING','RUNNING','APPLIED','RETRY','ERROR','SKIPPED')` |
| CHECK | `CHK_APPLY_TASK_DML` | `DML_TYPE IN ('INSERT','UPDATE','DELETE')` |

#### DDL スケッチ

```sql
CREATE SEQUENCE SEQ_APPLY_TASK
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE APPLY_TASK (
    APPLY_TASK_ID     NUMBER(10)     NOT NULL,
    APPLY_BATCH_ID    NUMBER(10)     NOT NULL,
    MINED_CHANGE_ID   NUMBER(10)     NOT NULL,
    ERROR_EVENT_ID    NUMBER(10),
    MIG_RUN_ID        NUMBER(10)     NOT NULL,
    SEG_OWNER         VARCHAR2(100),
    TABLE_NAME        VARCHAR2(100),
    DML_TYPE          VARCHAR2(10)   NOT NULL,
    KEY_PAYLOAD       VARCHAR2(4000),
    DML_TEXT          VARCHAR2(4000),
    STATUS            VARCHAR2(20)   DEFAULT 'PENDING' NOT NULL,
    RETRY_COUNT       NUMBER(5)      DEFAULT 0 NOT NULL,
    EXECUTED_BY       VARCHAR2(100),
    STARTED_AT        TIMESTAMP,
    APPLIED_AT        TIMESTAMP,
    ERROR_MESSAGE     VARCHAR2(4000),
    CREATED_AT        TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT        TIMESTAMP,
    CONSTRAINT PK_APPLY_TASK
        PRIMARY KEY (APPLY_TASK_ID),
    CONSTRAINT FK_APPLY_TASK_BATCH
        FOREIGN KEY (APPLY_BATCH_ID)
        REFERENCES APPLY_BATCH (APPLY_BATCH_ID),
    CONSTRAINT FK_APPLY_TASK_CHANGE
        FOREIGN KEY (MINED_CHANGE_ID)
        REFERENCES MINED_CHANGE (MINED_CHANGE_ID),
    CONSTRAINT FK_APPLY_TASK_ERR
        FOREIGN KEY (ERROR_EVENT_ID)
        REFERENCES ERROR_EVENT (ERROR_EVENT_ID),
    CONSTRAINT CHK_APPLY_TASK_STS
        CHECK (STATUS IN
               ('PENDING','RUNNING','APPLIED','RETRY','ERROR','SKIPPED')),
    CONSTRAINT CHK_APPLY_TASK_DML
        CHECK (DML_TYPE IN ('INSERT','UPDATE','DELETE'))
);

CREATE OR REPLACE TRIGGER TRG_APPLY_TASK_BI
BEFORE INSERT ON APPLY_TASK
FOR EACH ROW
BEGIN
    IF :NEW.APPLY_TASK_ID IS NULL THEN
        SELECT SEQ_APPLY_TASK.NEXTVAL
        INTO :NEW.APPLY_TASK_ID FROM DUAL;
    END IF;
END;
/
```

---

### 3.7 ALTER TABLE — ARCHIVE_LOG への列追加

`09_phase4_tables.sql` 内で `ARCHIVE_LOG` テーブルに以下2列を `ALTER TABLE ADD` で追加する。この列は LogMiner 解析状況および適用状況を `ARCHIVE_LOG` 単位で追跡するために必要（§6.2.2 / §6.2.6）。

追加理由: フェーズ3 DDL 作成時点ではフェーズ4 設計が確定していなかったため、`09_phase4_tables.sql` で後付け追加する方式をとる（§2.5 の「既存ファイル変更なし・新規ファイル追加」方針を踏襲）。

```sql
-- ARCHIVE_LOG への MINING_STATUS / APPLY_STATUS 列追加
ALTER TABLE ARCHIVE_LOG ADD (
    MINING_STATUS  VARCHAR2(20),
    APPLY_STATUS   VARCHAR2(20)
);

-- CHECK 制約追加（制約名は Oracle 12c 識別子長上限30文字以内）
-- CHK_ARCHIVE_LOG_MNSTS: 22文字
ALTER TABLE ARCHIVE_LOG ADD CONSTRAINT CHK_ARCHIVE_LOG_MNSTS
    CHECK (MINING_STATUS IS NULL
           OR MINING_STATUS IN ('PENDING','MINING','MINED','FAILED'));

-- CHK_ARCHIVE_LOG_APSTS: 21文字
ALTER TABLE ARCHIVE_LOG ADD CONSTRAINT CHK_ARCHIVE_LOG_APSTS
    CHECK (APPLY_STATUS IS NULL
           OR APPLY_STATUS IN ('PENDING','APPLIED','FAILED'));
```

既存行の `MINING_STATUS` / `APPLY_STATUS` は NULL として追加される。フェーズ4 処理対象となる行は API（`SET_MINING_STATUS` / `SET_APPLY_STATUS`）で状態を設定する。

---

### 3.8 索引設計（P4-08 対応）

大量行を格納する `MINED_CHANGE` の索引設計が性能上の核心（P4-08）。テーブル別に索引一覧を示す。

#### LOGMINER_BATCH（解析バッチ制御）

| 索引名 | 列構成 | 用途 |
|---|---|---|
| `IDX_LOGMINER_BATCH_RS` | `(MIG_RUN_ID, STATUS)` | 実行中・失敗バッチの絞り込み |
| `IDX_LOGMINER_BATCH_FSCN` | `(MIG_RUN_ID, FROM_SCN)` | SCN 範囲での重複確認 |

#### LOGMINER_BATCH_LOG（使用ログ対応）

| 索引名 | 列構成 | 用途 |
|---|---|---|
| `IDX_LMNR_BLOG_ORDER` | `(LOGMINER_BATCH_ID, ADD_ORDER)` | ADD_LOGFILE 順での処理 |
| `IDX_LMNR_BLOG_ARC` | `(ARCHIVE_LOG_ID)` | ARCHIVE_LOG からの逆引き |

#### MINED_TRANSACTION（トランザクション管理）

| 索引名 | 列構成 | 用途 |
|---|---|---|
| `IDX_MINED_TX_BST` | `(LOGMINER_BATCH_ID, STATUS)` | バッチ別トランザクション処理 |
| `IDX_MINED_TX_SCN` | `(MIG_RUN_ID, COMMIT_SCN, STATUS)` | COMMIT_SCN 順の適用対象抽出 |
| `IDX_MINED_TX_RUN_STS` | `(MIG_RUN_ID, STATUS)` | 全体進捗確認 |

#### MINED_CHANGE（DML 明細 — P4-08 対応、大量行のため特に重要）

| 索引名 | 列構成 | 用途 |
|---|---|---|
| `IDX_MINED_CHANGE_TX` | `(MINED_TRANSACTION_ID, SCN, RS_ID, SSN)` | XID 単位の適用順序（SCN → RS_ID → SSN の順で並べる） |
| `IDX_MINED_CHANGE_TBL` | `(MIG_RUN_ID, SEG_OWNER, TABLE_NAME, STATUS)` | 対象テーブル別の処理・フィルタリング |
| `IDX_MINED_CHANGE_SCN` | `(MIG_RUN_ID, COMMIT_SCN, STATUS)` | COMMIT_SCN 順の適用（APPLY_BATCH 境界に合わせた取得） |
| `IDX_MINED_CHANGE_BST` | `(LOGMINER_BATCH_ID, STATUS)` | バッチ内の処理進捗確認 |

> **設計判断（P4-08）**: `MINED_CHANGE` は数百万〜数千万行に達する可能性がある。UQ 制約 `(MIG_RUN_ID, RS_ID, SSN)` が PKより効率的なアクセスパスになるケースがある。`IDX_MINED_CHANGE_TX` の `(MINED_TRANSACTION_ID, SCN, RS_ID, SSN)` はトランザクション内の DML 適用順を正確に再現するために必要（P4-11 対応）。

#### APPLY_BATCH（適用バッチ制御）

| 索引名 | 列構成 | 用途 |
|---|---|---|
| `IDX_APPLY_BATCH_RS` | `(MIG_RUN_ID, STATUS, FROM_COMMIT_SCN)` | 未処理バッチの昇順取得 |

#### APPLY_TASK（DML 適用キュー）

| 索引名 | 列構成 | 用途 |
|---|---|---|
| `IDX_APPLY_TASK_BATCH` | `(APPLY_BATCH_ID, STATUS)` | バッチ内タスクのディスパッチ |
| `IDX_APPLY_TASK_CHANGE` | `(MINED_CHANGE_ID)` | MINED_CHANGE からの逆引き |
| `IDX_APPLY_TASK_TBL` | `(MIG_RUN_ID, SEG_OWNER, TABLE_NAME, STATUS)` | テーブル別の再処理対象抽出 |

---

## 4. 状態値一覧と遷移

フェーズ4 で追加する状態値の全体を示す。既存テーブルへの追加列（`ARCHIVE_LOG.MINING_STATUS` / `APPLY_STATUS`）も含む。

### 4.1 LOGMINER_BATCH.STATUS

```
PLANNED → RUNNING     （BEGIN_LOGMINER_BATCH: PLANNED/RETRY→RUNNING）
RUNNING → COMPLETED   （COMPLETE_LOGMINER_BATCH）
RUNNING → FAILED      （FAIL_LOGMINER_BATCH）
FAILED  → RETRY       （手動設定）
RETRY   → RUNNING     （BEGIN_LOGMINER_BATCH で再開）
```

### 4.2 ARCHIVE_LOG.MINING_STATUS（新列）

```
（NULL）  → PENDING  （フェーズ4 処理対象として登録時）
PENDING  → MINING   （SET_MINING_STATUS: 解析セッション開始時）
MINING   → MINED    （SET_MINING_STATUS: 解析完了時）
MINING   → FAILED   （SET_MINING_STATUS: 解析失敗時）
```

### 4.3 ARCHIVE_LOG.APPLY_STATUS（新列）

```
（NULL）  → PENDING  （フェーズ4 処理対象として登録時）
PENDING  → APPLIED  （SET_APPLY_STATUS: 全変更の適用完了時）
PENDING  → FAILED   （SET_APPLY_STATUS: 適用エラー発生時）
```

### 4.4 MINED_TRANSACTION.STATUS

```
MINED   → QUEUED    （UPDATE_MINED_TX_STATUS: 適用キュー化時）
QUEUED  → APPLIED   （UPDATE_MINED_TX_STATUS: 全変更の適用完了時）
QUEUED  → SKIPPED   （UPDATE_MINED_TX_STATUS: 対象外トランザクション）
QUEUED  → ERROR     （UPDATE_MINED_TX_STATUS: 適用エラー発生時）
```

### 4.5 MINED_CHANGE.STATUS（MINED_TRANSACTION と同様）

```
MINED   → QUEUED
QUEUED  → APPLIED / SKIPPED / ERROR
```

### 4.6 APPLY_BATCH.STATUS

```
PLANNED → RUNNING   （BEGIN_APPLY_BATCH: PLANNED/RETRY→RUNNING）
RUNNING → COMPLETED （COMPLETE_APPLY_BATCH）
RUNNING → FAILED    （FAIL_APPLY_BATCH）
FAILED  → RETRY     （手動設定）
RETRY   → RUNNING   （BEGIN_APPLY_BATCH で再開）
```

### 4.7 APPLY_TASK.STATUS

```
PENDING → RUNNING   （START_APPLY_TASK: PENDING/RETRY→RUNNING）
RUNNING → APPLIED   （COMPLETE_APPLY_TASK）
RUNNING → RETRY     （RETRY_APPLY_TASK: 再試行可能エラー発生時）
RUNNING → ERROR     （ERROR_APPLY_TASK: 再試行不可エラー発生時）
RETRY   → RUNNING   （START_APPLY_TASK で再開）
PENDING → SKIPPED   （手動設定: 対象外 DML）
```

---

## 5. Phase4 API 仕様（段1で追加するもの全て）

実装ファイル: `sql/migration_ctl/10_pkg_mig_admin_phase4.sql`

既存の `PKG_MIG_ADMIN`（v4.0 時点で24本の API を持つ）を `CREATE OR REPLACE PACKAGE` で全体再定義し、既存 API をすべて含めたうえで以下を追加する。

### 5.1 エラー番号規約

| エラー番号 | 意味 |
|---|---|
| `-20001` | 既存: 汎用の事前条件不満 |
| `-20002` | 既存: 事前条件不満（重複・状態不正） |
| `-20011` | 既存: COMPLETE_PHASE3 完了条件未達 |
| `-20012` | **フェーズ4追加**: 不正な状態遷移（フェーズ4テーブル） |

### 5.2 LOGMINER_BATCH API

**REGISTER_LOGMINER_BATCH** — LOGMINER_BATCH を `STATUS='PLANNED'` で登録する。

```
PROCEDURE REGISTER_LOGMINER_BATCH (
    p_run_id         IN  NUMBER,
    p_batch_no       IN  NUMBER,
    p_from_scn       IN  NUMBER,
    p_to_scn         IN  NUMBER,
    p_dict_method    IN  VARCHAR2,
    p_logmnr_options IN  VARCHAR2,
    p_batch_id       OUT NUMBER
);
```

仕様:
- `STATUS='PLANNED'`, `CREATED_AT=SYSTIMESTAMP` で INSERT する。
- `(MIG_RUN_ID, BATCH_NO)` が重複する場合は `-20002` で例外。
- 採番は `SEQ_LOGMINER_BATCH` を使用。

---

**BEGIN_LOGMINER_BATCH** — 解析開始。`PLANNED` または `RETRY` → `RUNNING` に遷移する。

```
PROCEDURE BEGIN_LOGMINER_BATCH (
    p_batch_id IN NUMBER
);
```

仕様:
- `STATUS IN ('PLANNED','RETRY')` の行を `STATUS='RUNNING'`, `STARTED_AT=SYSTIMESTAMP` に UPDATE する。
- 対象外の状態の場合は `-20012` で例外（不正な状態遷移）。

---

**COMPLETE_LOGMINER_BATCH** — 解析完了。`RUNNING` → `COMPLETED` に遷移する。

```
PROCEDURE COMPLETE_LOGMINER_BATCH (
    p_batch_id    IN NUMBER,
    p_change_count IN NUMBER,
    p_tx_count    IN NUMBER
);
```

仕様:
- `STATUS='RUNNING'` の行を `STATUS='COMPLETED'`, `CHANGE_COUNT`, `TRANSACTION_COUNT`, `FINISHED_AT=SYSTIMESTAMP` に UPDATE する。
- 対象外の状態の場合は `-20012` で例外。

---

**FAIL_LOGMINER_BATCH** — 解析失敗。`FAILED` へ遷移する。

```
PROCEDURE FAIL_LOGMINER_BATCH (
    p_batch_id  IN NUMBER,
    p_error_msg IN VARCHAR2
);
```

仕様:
- `STATUS='FAILED'`, `ERROR_MESSAGE=p_error_msg`, `FINISHED_AT=SYSTIMESTAMP`, `UPDATED_AT=SYSTIMESTAMP` に UPDATE する。
- 状態チェックは行わない（RUNNING・RETRY どちらからも FAILED に遷移できる）。

---

**ADD_BATCH_LOG** — LOGMINER_BATCH_LOG に1行追加する。

```
PROCEDURE ADD_BATCH_LOG (
    p_batch_id      IN NUMBER,
    p_archive_log_id IN NUMBER,
    p_add_order     IN NUMBER
);
```

仕様:
- `SEQ_LOGMINER_BATCH_LOG` で採番して INSERT する。
- `(LOGMINER_BATCH_ID, ARCHIVE_LOG_ID)` が重複する場合は `-20002` で例外。

---

### 5.3 MINING_STATUS / APPLY_STATUS 更新 API

**SET_MINING_STATUS** — `ARCHIVE_LOG.MINING_STATUS` を更新する。

```
PROCEDURE SET_MINING_STATUS (
    p_archive_log_id IN NUMBER,
    p_mining_status  IN VARCHAR2
);
```

仕様:
- `p_mining_status` が CHECK 制約値（`'PENDING','MINING','MINED','FAILED'`）以外の場合は Oracle CHECK 制約違反が自然に発生する（追加バリデーション不要）。
- `UPDATED_AT=SYSTIMESTAMP` も合わせて UPDATE する。
- 対象行が存在しない場合は `-20002` で例外。

---

**SET_APPLY_STATUS** — `ARCHIVE_LOG.APPLY_STATUS` を更新する。

```
PROCEDURE SET_APPLY_STATUS (
    p_archive_log_id IN NUMBER,
    p_apply_status   IN VARCHAR2
);
```

仕様: `SET_MINING_STATUS` と同様。許容値は `'PENDING','APPLIED','FAILED'`。

---

### 5.4 バルク登録 API（§15.2 対応）

Collection 型定義（PACKAGE SPEC 内で公開する）:

```sql
-- MINED_TRANSACTION バルク登録用
TYPE T_MINED_TX_REC IS RECORD (
    MIG_RUN_ID        NUMBER,
    LOGMINER_BATCH_ID NUMBER,
    XID               VARCHAR2(50),
    START_SCN         NUMBER,
    COMMIT_SCN        NUMBER,
    CHANGE_COUNT      NUMBER
);
TYPE T_MINED_TX_TBL IS TABLE OF T_MINED_TX_REC INDEX BY PLS_INTEGER;

-- MINED_CHANGE バルク登録用（SQL_REDO/SQL_UNDO は CLOB のため除外）
TYPE T_MINED_CHG_REC IS RECORD (
    MIG_RUN_ID            NUMBER,
    LOGMINER_BATCH_ID     NUMBER,
    MINED_TRANSACTION_ID  NUMBER,
    RS_ID                 VARCHAR2(100),
    SSN                   NUMBER,
    SCN                   NUMBER,
    COMMIT_SCN            NUMBER,
    OPERATION             VARCHAR2(20),
    SEG_OWNER             VARCHAR2(100),
    TABLE_NAME            VARCHAR2(100),
    CSF                   NUMBER
);
TYPE T_MINED_CHG_TBL IS TABLE OF T_MINED_CHG_REC INDEX BY PLS_INTEGER;

-- APPLY_TASK バルク登録用
TYPE T_APPLY_TASK_REC IS RECORD (
    MIG_RUN_ID       NUMBER,
    APPLY_BATCH_ID   NUMBER,
    MINED_CHANGE_ID  NUMBER,
    SEG_OWNER        VARCHAR2(100),
    TABLE_NAME       VARCHAR2(100),
    DML_TYPE         VARCHAR2(10),
    KEY_PAYLOAD      VARCHAR2(4000),
    DML_TEXT         VARCHAR2(4000)
);
TYPE T_APPLY_TASK_TBL IS TABLE OF T_APPLY_TASK_REC INDEX BY PLS_INTEGER;
```

---

**BULK_INS_MINED_TX** — `MINED_TRANSACTION` を FORALL バルク INSERT する。

```
PROCEDURE BULK_INS_MINED_TX (
    p_rows IN T_MINED_TX_TBL
);
```

仕様:
- `FORALL i IN 1..p_rows.COUNT INSERT INTO MINED_TRANSACTION (...) VALUES (...)` で一括 INSERT する。
- `SEQ_MINED_TRANSACTION.NEXTVAL` で採番（FORALL 内から利用可能）。
- `DEFAULT STATUS='MINED'`。
- UQ 制約 `(MIG_RUN_ID, XID, COMMIT_SCN)` 違反時は `SAVE EXCEPTIONS` 節でエラーを集積し、完了後にエラー件数を `RAISE` する。

---

**BULK_INS_MINED_CHG** — `MINED_CHANGE` を FORALL バルク INSERT する（SQL_REDO/SQL_UNDO を除く列のみ）。

```
PROCEDURE BULK_INS_MINED_CHG (
    p_rows IN T_MINED_CHG_TBL
);
```

仕様:
- `SQL_REDO` / `SQL_UNDO`（CLOB）は本プロシージャでは挿入しない。CLOB は FORALL の EXECUTE ... USING 形式での一括バインドが制約を受けるため、後続処理で `MINED_CHANGE_ID` を使って個別に `DBMS_LOB.WRITE` または UPDATE で設定する（段2 設計にて詳細化）。
- `DEFAULT STATUS='MINED'`, `DEFAULT CSF` は `p_rows` の値をそのまま使用する。
- UQ 制約 `(MIG_RUN_ID, RS_ID, SSN)` 違反は `SAVE EXCEPTIONS` で集積する。

---

**BULK_INS_APPLY_TASKS** — `APPLY_TASK` を FORALL バルク INSERT する。

```
PROCEDURE BULK_INS_APPLY_TASKS (
    p_rows IN T_APPLY_TASK_TBL
);
```

仕様:
- `DEFAULT STATUS='PENDING'`, `DEFAULT RETRY_COUNT=0`。
- バルク INSERT 失敗時は呼び出し元でハンドリングする。

---

### 5.5 APPLY_BATCH API

**REGISTER_APPLY_BATCH** — `APPLY_BATCH` を `STATUS='PLANNED'` で登録する。

```
PROCEDURE REGISTER_APPLY_BATCH (
    p_run_id         IN  NUMBER,
    p_batch_no       IN  NUMBER,
    p_from_commit_scn IN NUMBER,
    p_to_commit_scn  IN  NUMBER,
    p_batch_id       OUT NUMBER
);
```

---

**BEGIN_APPLY_BATCH** — 適用開始。`PLANNED`/`RETRY` → `RUNNING`。

```
PROCEDURE BEGIN_APPLY_BATCH (
    p_batch_id IN NUMBER
);
```

仕様: `BEGIN_LOGMINER_BATCH` と同様。状態外は `-20012`。

---

**COMPLETE_APPLY_BATCH** — 適用完了。`RUNNING` → `COMPLETED`。

```
PROCEDURE COMPLETE_APPLY_BATCH (
    p_batch_id  IN NUMBER,
    p_applied   IN NUMBER,
    p_skipped   IN NUMBER,
    p_errors    IN NUMBER
);
```

仕様: `APPLIED_COUNT`・`SKIPPED_COUNT`・`ERROR_COUNT`・`FINISHED_AT` を設定する。

---

**FAIL_APPLY_BATCH** — 適用失敗。`FAILED` へ遷移する。

```
PROCEDURE FAIL_APPLY_BATCH (
    p_batch_id  IN NUMBER,
    p_error_msg IN VARCHAR2
);
```

---

### 5.6 APPLY_TASK API

**QUEUE_APPLY_TASK** — `APPLY_TASK` を `STATUS='PENDING'` で1件登録する。

```
PROCEDURE QUEUE_APPLY_TASK (
    p_batch_id       IN  NUMBER,
    p_mined_change_id IN NUMBER,
    p_seg_owner      IN  VARCHAR2,
    p_table_name     IN  VARCHAR2,
    p_dml_type       IN  VARCHAR2,
    p_key_payload    IN  VARCHAR2,
    p_dml_text       IN  VARCHAR2,
    p_task_id        OUT NUMBER
);
```

仕様: 大量登録には `BULK_INS_APPLY_TASKS` を使用する。本 API は個別登録・手動キュー投入用。

---

**START_APPLY_TASK** — タスク取得。`PENDING`/`RETRY` → `RUNNING`。

```
PROCEDURE START_APPLY_TASK (
    p_task_id   IN NUMBER,
    p_executor  IN VARCHAR2
);
```

仕様: `STARTED_AT=SYSTIMESTAMP`, `EXECUTED_BY=p_executor` を設定する。状態外は `-20012`。

---

**COMPLETE_APPLY_TASK** — 適用成功。`RUNNING` → `APPLIED`。

```
PROCEDURE COMPLETE_APPLY_TASK (
    p_task_id IN NUMBER
);
```

仕様: `APPLIED_AT=SYSTIMESTAMP` を設定する。

---

**RETRY_APPLY_TASK** — 再試行可能エラー。`RUNNING` → `RETRY`。

```
PROCEDURE RETRY_APPLY_TASK (
    p_task_id   IN NUMBER,
    p_error_id  IN NUMBER,
    p_error_msg IN VARCHAR2
);
```

仕様: `ERROR_EVENT_ID=p_error_id`, `ERROR_MESSAGE=p_error_msg`, `RETRY_COUNT=RETRY_COUNT+1` を設定する。

---

**ERROR_APPLY_TASK** — 再試行不可エラー。`RUNNING` → `ERROR`。

```
PROCEDURE ERROR_APPLY_TASK (
    p_task_id   IN NUMBER,
    p_error_id  IN NUMBER,
    p_error_msg IN VARCHAR2
);
```

仕様: `RETRY_APPLY_TASK` と同様。`STATUS='ERROR'` に設定する。

---

### 5.7 MINED_TRANSACTION / MINED_CHANGE 状態更新 API

**UPDATE_MINED_TX_STATUS** — `MINED_TRANSACTION.STATUS` を更新する。

```
PROCEDURE UPDATE_MINED_TX_STATUS (
    p_mined_transaction_id IN NUMBER,
    p_new_status           IN VARCHAR2
);
```

仕様: `STATUS=p_new_status`, `UPDATED_AT=SYSTIMESTAMP` に UPDATE する。CHECK 制約外の値は Oracle の CHECK 制約違反が自然に発生する。

---

**UPDATE_MINED_CHG_STATUS** — `MINED_CHANGE.STATUS` を更新する。

```
PROCEDURE UPDATE_MINED_CHG_STATUS (
    p_mined_change_id IN NUMBER,
    p_new_status      IN VARCHAR2
);
```

仕様: `UPDATE_MINED_TX_STATUS` と同様。

---

## 6. バルク登録設計（§15.2 対応）

### 6.1 設計方針

設計メモ §15.2 は「MINED_CHANGE 等の大量明細は、1件ずつ管理 API を呼ばず、配列バインド・FORALL・ステージングテーブル等でバルク登録する」と定義する。

本設計では FORALL 方式を採用する。ステージングテーブルは使用しない（制約事項参照）。

### 6.2 FORALL による MINED_TRANSACTION / MINED_CHANGE 登録

```
呼び出し元（PL/SQL、段2 LogMiner 読み取り処理）
  ↓ V$LOGMNR_CONTENTS を BULK COLLECT
  ↓ XID 単位で T_MINED_TX_TBL に集約
  ↓ BULK_INS_MINED_TX(p_rows => v_tx_tbl)
  ↓ T_MINED_CHG_TBL にメタデータ行を詰める（SQL_REDO/SQL_UNDO を除く）
  ↓ BULK_INS_MINED_CHG(p_rows => v_chg_tbl)
  ↓ 採番後の MINED_CHANGE_ID を使い CLOB 列を個別更新（DBMS_LOB 経由）
```

### 6.3 CLOB 列の取り扱い

`MINED_CHANGE.SQL_REDO` / `SQL_UNDO` は CLOB 型であり、FORALL による一括バインドに制約がある。バルク INSERT はメタデータ列のみで行い、CLOB 列は後続処理で個別に設定する。CSF 分割行を再構成した場合（§10.2）は再構成後の完全テキストを格納する。

### 6.4 APPLY_TASK のバルク登録

`MINED_CHANGE` を適用キュー化する際も `BULK_INS_APPLY_TASKS` を使用する。個別の `QUEUE_APPLY_TASK` は手動投入・テスト用途に限定する。

### 6.5 バッチサイズ

1回の FORALL に詰める行数（バッチサイズ）は段2の実装設計で決定する（P4-04 / P4-06 の測定結果に依存）。大量行のメモリ消費（PGA）に注意する。

---

## 7. チェックポイント設計（P4-20 対応）

### 7.1 採用するコンポーネント名

`MIG_CHECKPOINT` テーブルの `COMPONENT_NAME` は既存の CHECK 制約（`CHK_MIG_CHECKPOINT_COMP`）の許容値を使用する:

| コンポーネント | 用途 |
|---|---|
| `LOGMINER_READER` | LogMiner 解析済みの SCN 位置（安全に解析完了した最後の SCN） |
| `APPLY_WRITER` | 差分適用済みの COMMIT_SCN 位置（完全適用した最後の COMMIT_SCN） |

> 設計メモ §6.2.5 は `'SCHEMA10_APPLY'` という名称を例示しているが、実装済みの CHECK 制約（`sql/migration_ctl/06_mig_checkpoint.sql`）の許容値に `'APPLY_WRITER'` が含まれており、`'SCHEMA10_APPLY'` は含まれていない。このため `'APPLY_WRITER'` を使用する。

### 7.2 チェックポイントの更新タイミング

| コンポーネント | CHECKPOINT_KEY | 更新タイミング | CHECKPOINT_SCN の意味 |
|---|---|---|---|
| `LOGMINER_READER` | `'GLOBAL'` | LOGMINER_BATCH 完了後 | そのバッチの `TO_SCN` |
| `APPLY_WRITER` | `'GLOBAL'` | APPLY_BATCH 完了後、差分 DML と同一トランザクション内 | 完全適用した最後の `COMMIT_SCN` |

表単位で独立して適用する場合は、`CHECKPOINT_KEY='TABLE:OWNER.TABLE_NAME'` も検討できるが、XID 単位の完了を優先する（設計メモ §6.2.5）。

### 7.3 原則

チェックポイントは「処理が正常に COMMIT された後で更新する」。§9 の不変条件と組み合わせること。

---

## 8. エラー・再処理設計（P4-21 対応）

### 8.1 ERROR_EVENT への記録内容（§6.2.7）

フェーズ4 でエラーが発生した場合、既存の `RAISE_ERROR_EVENT` API で `ERROR_EVENT` テーブルに以下を記録する:

| 列 | 設定値の例 |
|---|---|
| `PHASE_CODE` | `'PHASE4'` |
| `COMPONENT_NAME` | `'LOGMINER'` / `'SQL_RECONSTRUCTOR'` / `'APPLY_WRITER'` 等 |
| `ORA_ERROR_CODE` | `'ORA-XXXXX'` 等 |
| `ERROR_MESSAGE` | SQLERRM + 対象 XID / COMMIT_SCN / TABLE_NAME |
| `RESOLVE_STATUS` | `'OPEN'`（初期値）|

`APPLY_TASK.ERROR_EVENT_ID` に記録した `ERROR_EVENT_ID` を紐付けることで、タスク単位のエラー追跡が可能になる。

### 8.2 再処理方針

- **APPLY_TASK の再処理**: 新たな APPLY_TASK を重複作成しない。既存 `APPLY_TASK.STATUS='RETRY'` に戻す（§6.2.7 設計方針）。`ERROR_EVENT.RESOLVE_STATUS` は `RETRY_READY → RETRYING → RESOLVED` の順で更新する。
- **LOGMINER_BATCH の再処理**: `STATUS='RETRY'` に設定後、`BEGIN_LOGMINER_BATCH` で再開する。再解析時に重複防止キー `(MIG_RUN_ID, XID, COMMIT_SCN)` / `(MIG_RUN_ID, RS_ID, SSN)` が UQ 違反を引き起こすことで重複登録を防ぐ。
- **APPLY_BATCH の再処理**: `STATUS='RETRY'` に設定後、`BEGIN_APPLY_BATCH` で再開する。既に `APPLIED` の APPLY_TASK はスキップ判定で再適用しない。

### 8.3 フェーズ4完了判定の条件（§6.2.8）

- `MIG_CHECKPOINT`（`APPLY_WRITER` / `GLOBAL`）の `CHECKPOINT_SCN >= TARGET_END_SCN`
- `MIGRATION_RUN.LAST_APPLIED_SCN >= TARGET_END_SCN`
- 対象 `ARCHIVE_LOG` の `MINING_STATUS='MINED'` かつ `APPLY_STATUS='APPLIED'`
- 未処理の `MINED_TRANSACTION` / `MINED_CHANGE` / `APPLY_TASK` がゼロ件
- 未解消の `ERROR_EVENT`（`SEVERITY IN ('FATAL','ERROR')` かつ `RESOLVE_STATUS='OPEN'`）がゼロ件
- 必須の `VALIDATION_RUN` が `OVERALL_RESULT='PASS'`
- `PHASE_STATUS`（PHASE4）が `COMPLETED`

---

## 9. 不変条件（§6.2.5 の同一トランザクション制約）

**最重要設計原則**:

```text
以下を1つの DB トランザクションで実行し、最後に COMMIT する。

  (1) DB2.0 側 1.0 スキーマへの差分 DML を実行する
  (2) APPLY_TASK.STATUS='APPLIED' に UPDATE する
  (3) MINED_CHANGE.STATUS='APPLIED' に UPDATE する
  (4) MINED_TRANSACTION.STATUS='APPLIED' に UPDATE する（全変更が完了した場合）
  (5) MIG_CHECKPOINT（APPLY_WRITER/GLOBAL）を UPSERT する
  (6) COMMIT
```

この順序・境界を守ることで、再実行時に「どこまで確実に適用済みか」が `MIG_CHECKPOINT` から機械的に判断できる。

`LAST_APPLIED_SCN` の更新は必ず `MIG_CHECKPOINT` と整合する値とし、単独で先行更新しない（設計メモ §6.2.6）。

---

## 10. 段2以降の設計見通し

### 10.1 LogMiner 起動手順と解析結果登録の流れ（段2）

```text
1. REGISTER_LOGMINER_BATCH で LOGMINER_BATCH を登録（PLANNED）
2. LOGMINER_BATCH_LOG に使用する Archived Redo を ADD_BATCH_LOG で追加
3. BEGIN_LOGMINER_BATCH（PLANNED → RUNNING）、SET_MINING_STATUS（PENDING → MINING）
4. DBMS_LOGMNR.ADD_LOGFILE で各 Archived Redo を追加（ADD_ORDER 順）
5. DBMS_LOGMNR.START_LOGMNR（DICT_FROM_REDO_LOGS + COMMITTED_DATA_ONLY 相当のオプション）
6. V$LOGMNR_CONTENTS を BULK COLLECT でフェッチ
7. BULK_INS_MINED_TX でトランザクション一括登録
8. BULK_INS_MINED_CHG で明細一括登録（SQL_REDO/SQL_UNDO 除く）
9. SQL_REDO/SQL_UNDO を MINED_CHANGE_ID で特定し CLOB 個別更新
10. COMPLETE_LOGMINER_BATCH / SET_MINING_STATUS（MINED）
11. UPSERT_CHECKPOINT（LOGMINER_READER / TO_SCN）
```

### 10.2 CSF 分割行の再構成方針

`V$LOGMNR_CONTENTS.CSF=1` の行は SQL が続行することを示す。再構成の方針:

- 識別キー: `(MIG_RUN_ID, RS_ID)` — 同一 RS_ID を持つ行が1つの論理 SQL を形成する。
- 連結順序: `SSN` 昇順に SQL_REDO テキストを連結する。
- 終端判定: `CSF=0` の行が論理 SQL の末尾。
- 再構成後: 先頭行（最小 SSN）の `MINED_CHANGE` レコードに完全 SQL を格納し、CSF=1 の後続行は `STATUS='SKIPPED'` とする。
- 複数ログ跨ぎ: LOGMINER_BATCH の SCN 範囲が跨ぐ場合は連続バッチで RS_ID を照合する（P4-09 で詳細検証）。

### 10.3 APPLY_TASK 実行とチェックポイントの同一トランザクション制約の実現（段3）

段3 実装時の設計方針（§9 の実現手段）:

- PL/SQL の `BEGIN ... EXCEPTION ... END` ブロック内で DML 実行と管理テーブル更新を行い、末尾の `COMMIT` を1回だけ発行する。
- DML 実行が失敗した場合は `ROLLBACK` 後に `RETRY_APPLY_TASK` / `ERROR_APPLY_TASK` を呼び出す（この呼び出し自体は別トランザクション）。
- チェックポイントの更新は DML の `COMMIT` と同一トランザクション内に置く。チェックポイントだけを先に `COMMIT` してはならない。

### 10.4 MINED_CHANGE.SQL_REDO / SQL_UNDO の保持方針

> 🟡 **仮決定 TMP-12** — CLOB として保持する方針を採用したが、以下は未決定。

- 適用後も無期限保持するか、一定期間で削除するか。
- 圧縮（SecureFiles COMPRESS）を使用するか。
- パーティション化（MINED_CHANGE を COMMIT_SCN または LOGMINER_BATCH_ID でパーティション化）するか。
- 設計メモ §15.2 は「MINED_CHANGE.SQL_REDO/SQL_UNDO の保持・削除方針」を「本番設計までに必要（優先度B）」と分類している。

詳細は `docs/handoff-guide.md` TMP-12 および設計メモ P4-22 を参照。

---

## 11. 制約事項（環境制約で検証不可なもの）

`docs/handoff-guide.md` §5 の本番未検証台帳より、フェーズ4に特に関連するものを引用する。

| ID | 未検証事項 | なぜ再現できないか | 本番で必要な確認 |
|---|---|---|---|
| **UNV-06** | フェーズ4新設計（移行先でLogMiner実行）の本格検証 | PoC は1表に1回 UPDATE の規模 | INSERT/DELETE、複合主キー、BLOB/CLOB、複数トランザクション、CSF分割行の再構成、追付き性能 |
| **UNV-04** | Oracle 12c / 19c の実バージョン差 | 両側とも Oracle 21c XE | `V$LOGMNR_CONTENTS` の列差、12.1/12.2 での LogMiner 動作差 |
| **P4-01** | DB1.0 Archived RedoをDB2.0で解析するPoC | PoC 実施中（2026-07-31 期限） | COMMIT_SCN / XID / SQL_REDO / CSF の正常取得、複合主キー、LOB対応 |
| **P4-04** | LogMiner 処理単位（SCN 範囲・バッチ境界） | 規模が検証データと本番で桁違い | 長時間トランザクション跨ぎ、バッチ境界の重複、再実行単位 |
| **P4-23** | 全体処理速度・追付き性能 | 測定可能な規模のデータがない | LogMiner 解析速度、1.0スキーマ反映速度、1日当たりのログ生成速度 |

---

## 12. 踏んだ失敗と対処（段1実装記録）

段1（管理テーブルDDL + PKG_MIG_ADMIN v5.0 + E2Eテスト）の実装において踏んだ失敗を記録する。

| # | 現象 | 原因 | 実際に効いた対処 |
|---|---|---|---|
| 1 | テストスクリプト Setup 部で ARCHIVE_LOG を登録しようとした最初のブロックに `FROM V$DATABASE@!` という構文エラーが混入していた。sqlplus は黙って失敗し ARC_ID が取れなかったが、直後に別ブロックで変数を上書きしたため実際のテストには影響しなかった | ドラフト中に削除し忘れた無効な SQL が残っていた | デッドコードブロックを削除し、直接 INSERT するブロック一本に整理した。E2E テスト全項目 PASS を確認 |

> **段1実装時の所見**: `09_phase4_tables.sql` / `10_pkg_mig_admin_phase4.sql` / `72_test_phase4_tables_e2e.sh` はいずれも一発で Oracle コンパイルに成功し、T01〜T15 の全テストケースが初回実行で PASS した。フェーズ3 §6.5 のノウハウ（`END;/` 独立行・パイプ方式・`ALTER SESSION SET CONTAINER` 後の `SET SERVEROUTPUT ON`）を事前に反映したことが有効だった。
