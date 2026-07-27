# フェーズ3（Archived Redo Log 出力・収集）設計文書

- 作成日: 2026-07-27
- 設計根拠: `docs/private/design-memo-2-5phase.md`（§5 全体）
- 前提文書: `docs/migration-control-schema-design.md` v3.0、`docs/oracle-compatibility-policy.md`
- 参照: `docs/gap-analysis-5phase-schema.md` §1.1 / §1.2、`docs/handoff-guide.md` §4 / §5

---

## 1. 設計の目的

### 1.1 フェーズ3の完了状態定義（設計メモ §5.1 準拠）

フェーズ3が完了した状態とは、以下のすべてを満たすことをいう。

1. DB1.0 の RAC 全 Thread について、解析開始 SCN（`MINING_START_SCN`）を含む必要な Archived Redo が連続して生成・保管されている。
2. Thread・Sequence・SCN 範囲から欠落を検知できる（`V_ARCHIVE_LOG_GAP` ビューによる機械的確認）。
3. Supplemental Logging が有効になっており、フェーズ4 の LogMiner 解析に必要な主キー情報が Redo に出力されている。
4. LogMiner Dictionary を含むログを生成・識別・保管できる（`DICTIONARY_BEGIN_FLAG` / `DICTIONARY_END_FLAG` による機械的確認）。
5. 最終書込み停止時に、最終変更まで Archived Redo へ確実に出力・収集・検証できる。
6. `MIG_CHECKPOINT`（`COMPONENT_NAME='ARCHIVE_COLLECTOR'`）の `CHECKPOINT_SCN` が `TARGET_END_SCN` 以上に到達していることが確認できる。

### 1.2 フェーズ3の特殊性：他フェーズとの並走

フェーズ3 は番号上「フェーズ3」だが、実運用ではフェーズ1（全量 Export）より前から開始する（設計メモ §5.2.1）。

- Archived Redo の収集は `MINING_START_SCN` 確定前から継続的に実施する
- フェーズ1・2が並走している間も `PHASE_STATUS.PHASE3` は `RUNNING` を維持する
- `MARK_ARCHIVE_READY` 実行後も収集を継続し、最終ログ確定まで終了しない

---

## 2. アーキテクチャ

### 2.1 全体の流れ

```
oracle-src（DB1.0相当）         /migfs（共有ボリューム）         oracle-tgt（DB2.0相当）
  CDB$ROOT                          アーカイブ                     MIGRATION_CTL スキーマ
    │                               収集領域                              │
    ├─ DBMS_LOGMNR_D.BUILD ─────────────────────────────────────────────→│ SET_DICT_MARKERS
    │   (STORE_IN_REDO_LOGS)         │                                    │
    ├─ ALTER SYSTEM ARCHIVE LOG      │                                    │
    │   CURRENT                      │                                    │
    │                                │                                    │
    ├─ V$ARCHIVED_LOG 参照           │                                    │
    │                                │                                    │
    └─ Archived Redo ファイル ──→ /migfs/archivelogs/                     │
                               (docker cp 経由)      SHA-256算出          │
                                                           │              │
                                                           └──────────→ REGISTER_ARCHIVE_LOG
                                                                        REGISTER_ARCHIVE_LOG_COPY
                                                                        VERIFY_ARCHIVE_LOG_COPY
                                                                        UPSERT_CHECKPOINT
```

### 2.2 Archived Redo 収集方式

- 収集元: oracle-src コンテナの `V$ARCHIVED_LOG`（`CDB$ROOT` で参照、`COMPLETED='YES'` のもの）
- 収集先: `/migfs/archivelogs/`（docker 共有ボリューム。本番環境では Migration ファイルサーバに相当）
- 搬送: `docker cp` コマンド経由（本番では NFS/CIFS マウントによる直接出力に変わる）

> 🟡 **仮決定 TMP-07 参照** — 搬送層を docker の共有ボリューム（`/migfs`）で模擬。本番の Migration ファイルサーバとはマウント方式・帯域・障害時挙動が異なる。

### 2.3 LogMiner Dictionary の生成と埋め込み方式

- ビルド実行場所: oracle-src の **CDB$ROOT**（PDB 内で実行すると辞書がRedoに書き出されない。§7 ノウハウ #1 参照）
- API: `DBMS_LOGMNR_D.BUILD(OPTIONS => DBMS_LOGMNR_D.STORE_IN_REDO_LOGS)`
- 検証方法: `V$ARCHIVED_LOG` の `DICTIONARY_BEGIN='YES'` / `DICTIONARY_END='YES'` マーカーの存在確認
- 台帳への記録: `ARCHIVE_LOG.DICTIONARY_BEGIN_FLAG` / `DICTIONARY_END_FLAG` の更新（`SET_DICT_MARKERS` API 経由）

### 2.4 論理ログと物理コピーの2段階管理

設計メモ §5.2.2 に従い、同一ログを複数媒体へ置く場合は2段階で管理する。

```
ARCHIVE_LOG（論理台帳: 1行）
  └─ 論理一意キー: (MIG_RUN_ID, SOURCE_RESETLOGS_ID, THREAD_NO, SEQUENCE_NO)
       │
       ├─ ARCHIVE_LOG_COPY: /migfs（Migration ファイルサーバ相当）
       ├─ ARCHIVE_LOG_COPY: 8TB SSD（オプション）
       └─ ARCHIVE_LOG_COPY: oracle-tgt ローカル（オプション）
```

ファイルのコピー・再転送では `ARCHIVE_LOG` を重複 INSERT せず、`ARCHIVE_LOG_COPY` に行を追加する。

### 2.5 状態遷移（設計メモ §5.2.3 準拠）

```
ARCHIVE_LOG.COLLECT_STATUS:
  EXPECTED → RECEIVED → VERIFIED
                     → CORRUPT
                     → MISSING
                     → IGNORED

ARCHIVE_LOG_COPY.COPY_STATUS:
  EXPECTED → RECEIVED → VERIFIED → REGISTERED
                 → CORRUPT
                 → LOST
  REGISTERED / VERIFIED → DELETED（保持期限終了等）
```

---

## 3. MIG_CHECKPOINT 設計（TMP-03 確定記録）

### 3.1 採否

**採用（確定）**

- 確定日: 2026-07-27
- 根拠: 設計メモ §5.2.4 がフェーズ3の `ARCHIVE_COLLECTOR` コンポーネントで必須と定義している。設計メモ §5.2.6「最終同期時: MIG_CHECKPOINT が終了ログまで到達したことを確認する」がフェーズ3完了条件になっている。
- この検証環境では Thread=1 固定で動かすが、RAC 対応の列構造（`THREAD_NO`・`CHECKPOINT_KEY='THREAD:N'`）を維持する。
- 実装ファイル: `sql/migration_ctl/06_mig_checkpoint.sql`

### 3.2 テーブル定義

| カラム名 | 型 | NOT NULL | デフォルト | 説明 |
|---|---|---|---|---|
| MIG_CHECKPOINT_ID | NUMBER(10) | YES | SEQ採番 | 主キー |
| MIG_RUN_ID | NUMBER(10) | YES | — | FK: `MIGRATION_RUN.MIG_RUN_ID` |
| COMPONENT_NAME | VARCHAR2(50) | YES | — | コンポーネント識別子。CHECK制約参照 |
| CHECKPOINT_KEY | VARCHAR2(100) | YES | — | チェックポイント識別キー（例: `'THREAD:1'`） |
| THREAD_NO | NUMBER(5) | NO | NULL | RAC Thread 番号（RAC環境でのみ有効） |
| SEQUENCE_NO | NUMBER(20) | NO | NULL | 最後に検証済みの Sequence 番号 |
| CHECKPOINT_SCN | NUMBER(20) | NO | NULL | そのログの NEXT_CHANGE_SCN |
| REMARKS | VARCHAR2(4000) | NO | NULL | 備考 |
| CREATED_AT | TIMESTAMP | YES | SYSTIMESTAMP | レコード作成日時 |
| UPDATED_AT | TIMESTAMP | NO | NULL | 最終更新日時（UPSERT 時に設定） |

**制約**

| 種別 | 制約名 | 定義 |
|---|---|---|
| PK | `PK_MIG_CHECKPOINT` | `MIG_CHECKPOINT_ID` |
| FK | `FK_MIG_CHECKPOINT_RUN` | `MIG_RUN_ID` → `MIGRATION_RUN.MIG_RUN_ID` |
| UQ | `UQ_MIG_CHECKPOINT_KEY` | `(MIG_RUN_ID, COMPONENT_NAME, CHECKPOINT_KEY)` |
| CHECK | `CHK_MIG_CHECKPOINT_COMP` | `COMPONENT_NAME IN ('ARCHIVE_COLLECTOR', 'LOGMINER_READER', 'APPLY_WRITER')` |

> Oracle 12c 互換: IDENTITY 列禁止 → SEQUENCE + BEFORE INSERT トリガーで採番。識別子はすべて 30 文字以内。

**DDL スケッチ**

```sql
CREATE SEQUENCE SEQ_MIG_CHECKPOINT
    START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE MIG_CHECKPOINT (
    MIG_CHECKPOINT_ID  NUMBER(10)     NOT NULL,
    MIG_RUN_ID         NUMBER(10)     NOT NULL,
    COMPONENT_NAME     VARCHAR2(50)   NOT NULL,
    CHECKPOINT_KEY     VARCHAR2(100)  NOT NULL,
    THREAD_NO          NUMBER(5),
    SEQUENCE_NO        NUMBER(20),
    CHECKPOINT_SCN     NUMBER(20),
    REMARKS            VARCHAR2(4000),
    CREATED_AT         TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    UPDATED_AT         TIMESTAMP,
    CONSTRAINT PK_MIG_CHECKPOINT
        PRIMARY KEY (MIG_CHECKPOINT_ID),
    CONSTRAINT FK_MIG_CHECKPOINT_RUN
        FOREIGN KEY (MIG_RUN_ID)
        REFERENCES MIGRATION_RUN (MIG_RUN_ID),
    CONSTRAINT UQ_MIG_CHECKPOINT_KEY
        UNIQUE (MIG_RUN_ID, COMPONENT_NAME, CHECKPOINT_KEY),
    CONSTRAINT CHK_MIG_CHECKPOINT_COMP
        CHECK (COMPONENT_NAME IN (
            'ARCHIVE_COLLECTOR', 'LOGMINER_READER', 'APPLY_WRITER'))
);

CREATE OR REPLACE TRIGGER TRG_MIG_CHECKPOINT_BI
BEFORE INSERT ON MIG_CHECKPOINT
FOR EACH ROW
BEGIN
    IF :NEW.MIG_CHECKPOINT_ID IS NULL THEN
        SELECT SEQ_MIG_CHECKPOINT.NEXTVAL
        INTO :NEW.MIG_CHECKPOINT_ID FROM DUAL;
    END IF;
END;
/
```

### 3.3 UPSERT パターン（Oracle 12c: MERGE INTO）

`UPSERT_CHECKPOINT` API の内部実装に使用する。

```sql
-- Oracle 12c では MERGE INTO で UPSERT を実現する（INSERT OR UPDATE 構文は非サポート）
MERGE INTO MIG_CHECKPOINT dst
USING (
    SELECT p_run_id       AS MIG_RUN_ID,
           p_component    AS COMPONENT_NAME,
           p_key          AS CHECKPOINT_KEY
    FROM DUAL
) src
ON (    dst.MIG_RUN_ID     = src.MIG_RUN_ID
    AND dst.COMPONENT_NAME = src.COMPONENT_NAME
    AND dst.CHECKPOINT_KEY = src.CHECKPOINT_KEY)
WHEN MATCHED THEN
    UPDATE SET
        dst.THREAD_NO      = p_thread_no,
        dst.SEQUENCE_NO    = p_seq_no,
        dst.CHECKPOINT_SCN = p_scn,
        dst.UPDATED_AT     = SYSTIMESTAMP
WHEN NOT MATCHED THEN
    INSERT (
        MIG_CHECKPOINT_ID, MIG_RUN_ID, COMPONENT_NAME,
        CHECKPOINT_KEY, THREAD_NO, SEQUENCE_NO,
        CHECKPOINT_SCN, CREATED_AT
    )
    VALUES (
        SEQ_MIG_CHECKPOINT.NEXTVAL, p_run_id, p_component,
        p_key, p_thread_no, p_seq_no, p_scn, SYSTIMESTAMP
    );
```

**使用方法**: 収集スクリプト（`67_collect_archivelogs.sh`）が Archived Redo を 1 本チェックサム検証するたびに `UPSERT_CHECKPOINT` を呼び出す。チェックポイントは「受信した位置」ではなく「チェックサム検証まで完了した連続位置」を示す（設計メモ §5.2.4）。

---

## 4. 成果物一覧

以下のファイルを実装する（2026-07-27 時点で全ファイル実装・E2Eテスト PASS 確認済み）。

| # | 分類 | ファイル | 役割 | ステータス |
|---|---|---|---|---|
| 管 | 管理 | `sql/migration_ctl/06_mig_checkpoint.sql` | MIG_CHECKPOINT テーブル DDL（SEQUENCE・トリガー込み） | 完了 |
| 管 | 管理 | `sql/migration_ctl/07_pkg_mig_admin_phase3.sql` | PKG_MIG_ADMIN へのフェーズ3追加 API（PACKAGE BODY 全体再作成） | 完了 |
| 管 | 管理 | `sql/migration_ctl/08_views_phase3.sql` | V_ARCHIVE_LOG_GAP ビュー（LAG 関数で連番欠落を検知） | 完了 |
| P3 | Phase3 | `sql/phase3/01_build_logminer_dict_src.sql` | oracle-src CDB$ROOT での LogMiner 辞書ビルド SQL | 完了 |
| P3 | Phase3 | `sql/phase3/02_verify_dict_markers_src.sql` | V$ARCHIVED_LOG で DICTIONARY_BEGIN/END マーカーを確認するSQL | 完了 |
| P3 | Phase3 | `sql/phase3/03_register_archive_log_tgt.sql` | ARCHIVE_LOG / ARCHIVE_LOG_COPY 台帳登録 SQL（使用例） | 完了 |
| P3 | Phase3 | `sql/phase3/04_finalize_archive_log_tgt.sql` | 最終ログ確定手順（SET_TARGET_END_SCN 使用） | 完了 |
| P3 | Phase3 | `sql/phase3/05_cleanup_for_retry.sql` | フェーズ3の再実行用初期化 | 完了 |
| SC | スクリプト | `scripts/67_collect_archivelogs.sh` | Archived Redo 収集・台帳登録・チェックサム検証 | 完了 |
| SC | スクリプト | `scripts/68_build_logminer_dict.sh` | 辞書ビルド・マーカー確認・ARCHIVE_LOG 更新 | 完了 |
| SC | スクリプト | `scripts/69_test_phase3_e2e.sh` | E2E テスト（T01〜T08） | 完了（PASS 確認済み） |

**前提: ディレクトリ `sql/phase3/` の新設が必要**（`sql/phase1/` / `sql/phase2/` と同じ構成）。

---

## 5. Phase3 追加 API 仕様

`sql/migration_ctl/07_pkg_mig_admin_phase3.sql` として実装する。既存の `PKG_MIG_ADMIN` パッケージを `CREATE OR REPLACE PACKAGE` で全体再定義し、既存 API（`03_pkg_mig_admin.sql` + `05_pkg_mig_admin_phase1_2.sql` で定義した 18 本）をすべて含めたうえで 6 本を追加する。

エラー番号規約（Phase3 追加分）:
- `-20011`: `COMPLETE_PHASE3` の完了条件未達（条件名を SQLERRM メッセージに含める）

### 5.1 REGISTER_ARCHIVE_LOG

ARCHIVE_LOG へ `COLLECT_STATUS='EXPECTED'` で INSERT する。

**シグネチャ**

```
PROCEDURE REGISTER_ARCHIVE_LOG (
    p_run_id         IN  NUMBER,
    p_dbid           IN  NUMBER,
    p_resetlogs_id   IN  NUMBER,
    p_thread_no      IN  NUMBER,
    p_seq_no         IN  NUMBER,
    p_first_scn      IN  NUMBER,
    p_next_scn       IN  NUMBER,
    p_first_time     IN  TIMESTAMP,
    p_next_time      IN  TIMESTAMP,
    p_archive_log_id OUT NUMBER
);
```

**仕様**

- `COLLECT_STATUS='EXPECTED'` で INSERT する。
- 論理一意キー `(MIG_RUN_ID, SOURCE_RESETLOGS_ID, THREAD_NO, SEQUENCE_NO)` が重複する場合は `-20002`（事前条件不満）で例外を発生させる（重複 INSERT 禁止。再コピーは `REGISTER_ARCHIVE_LOG_COPY` で行う）。
- 採番は `SEQ_ARCHIVE_LOG` を使用（既存のシーケンス）。

### 5.2 RECEIVE_ARCHIVE_LOG

ARCHIVE_LOG の `COLLECT_STATUS` を `EXPECTED → RECEIVED` に遷移させる。ファイルコピー受信完了時点で呼ぶ。

**シグネチャ**

```
PROCEDURE RECEIVE_ARCHIVE_LOG (
    p_archive_log_id IN NUMBER
);
```

**仕様**

- `COLLECT_STATUS = 'EXPECTED'` の行を `'RECEIVED'` へ UPDATE する。
- `'EXPECTED'` 以外の場合は `-20002` で例外（不正な状態遷移）。

### 5.3 REGISTER_ARCHIVE_LOG_COPY

ARCHIVE_LOG_COPY へ `COPY_STATUS='RECEIVED'` で INSERT する。

**シグネチャ**

```
PROCEDURE REGISTER_ARCHIVE_LOG_COPY (
    p_archive_log_id IN  NUMBER,
    p_storage_loc    IN  VARCHAR2,
    p_file_path      IN  VARCHAR2,
    p_file_size      IN  NUMBER,
    p_checksum_algo  IN  VARCHAR2,
    p_checksum_val   IN  VARCHAR2,
    p_copy_id        OUT NUMBER
);
```

**仕様**

- `COPY_STATUS='RECEIVED'` で INSERT する。
- 採番は `SEQ_ARCHIVE_LOG_COPY` を使用（既存のシーケンス）。
- チェックサム検証は呼び出し元で実施済みであることを前提とし、本 API では値を保存するだけとする（検証は既存の `VERIFY_ARCHIVE_LOG_COPY` で行う）。

### 5.4 SET_DICT_MARKERS

ARCHIVE_LOG の `DICTIONARY_BEGIN_FLAG` / `DICTIONARY_END_FLAG` を更新する。

**シグネチャ**

```
PROCEDURE SET_DICT_MARKERS (
    p_archive_log_id IN NUMBER,
    p_dict_begin     IN CHAR,
    p_dict_end       IN CHAR
);
```

**仕様**

- `p_dict_begin` / `p_dict_end` は `'Y'` または `'N'` のみ受け付ける。それ以外は `-20002` で例外。
- 対象行が存在しない場合は `-20002` で例外。
- `UPDATED_AT = SYSTIMESTAMP` も合わせて UPDATE する。

### 5.5 UPSERT_CHECKPOINT

MIG_CHECKPOINT を UPSERT（INSERT または UPDATE）する。

**シグネチャ**

```
PROCEDURE UPSERT_CHECKPOINT (
    p_run_id    IN NUMBER,
    p_component IN VARCHAR2,
    p_key       IN VARCHAR2,
    p_thread_no IN NUMBER,
    p_seq_no    IN NUMBER,
    p_scn       IN NUMBER
);
```

**仕様**

- `(MIG_RUN_ID, COMPONENT_NAME, CHECKPOINT_KEY)` が一致する行が存在すれば UPDATE、なければ INSERT する。
- 内部実装は §3.3 の `MERGE INTO` パターンを使用する。
- `p_component` が `CHK_MIG_CHECKPOINT_COMP` の許容値以外の場合は Oracle の CHECK 制約違反エラーが自然に発生する（追加のバリデーション不要）。

### 5.6 COMPLETE_PHASE3

フェーズ3の完了条件をすべてチェックし、充足時に `PHASE_STATUS.PHASE3` を `COMPLETED` へ遷移させる。

**シグネチャ**

```
PROCEDURE COMPLETE_PHASE3 (
    p_run_id IN NUMBER
);
```

**完了チェック条件**（すべて充足が必要）

| 条件 | チェック内容 | エラーメッセージ例 |
|---|---|---|
| a | `MIGRATION_RUN.MINING_START_SCN IS NOT NULL` | `MINING_START_SCN not set` |
| b | `MIGRATION_RUN.TARGET_END_SCN IS NOT NULL` | `TARGET_END_SCN not set` |
| c | `ERROR_EVENT` に `RESOLVE_STATUS='OPEN'` かつ `SEVERITY IN ('FATAL','ERROR')` がゼロ件 | `Unresolved FATAL/ERROR events exist` |
| d | `MIG_CHECKPOINT` で `COMPONENT_NAME='ARCHIVE_COLLECTOR'` の全行について `CHECKPOINT_SCN >= TARGET_END_SCN` | `ARCHIVE_COLLECTOR checkpoint not reached TARGET_END_SCN` |
| e | `ARCHIVE_LOG.COLLECT_STATUS='MISSING'` の件数がゼロ | `Missing archive logs exist` |

**仕様**

- いずれかの条件を未充足の場合は `-20011` で例外を発生させ、SQLERRM に未充足の条件名を含める。
- 全条件を充足した場合:
  1. `PHASE_STATUS` の `PHASE_CODE='PHASE3'` 行を `STATUS='COMPLETED'`, `FINISHED_AT=SYSTIMESTAMP` に UPDATE する。
  2. `LOG_STATUS_CHANGE` を呼び出し、遷移を `MIG_STATUS_HISTORY` に記録する。
- 条件 d について: この検証環境（Thread=1）では `ARCHIVE_COLLECTOR` の行は 1 行のみだが、RAC 環境では Thread 数分の行を全行チェックする設計にする。

---

## 6. スクリプト仕様

### 6.1 `scripts/67_collect_archivelogs.sh` — 収集・台帳登録・チェックサム検証

**目的**: oracle-src の Archived Redo を `/migfs/archivelogs/` へ収集し、oracle-tgt の `MIGRATION_CTL` 台帳へ登録・検証する。

**処理フロー（主要ステップ）**

| Step | 内容 |
|---|---|
| 1 | 引数（`--run-id`）から `MIG_RUN_ID` を受け取る |
| 2 | oracle-src の `V$ARCHIVED_LOG`（`CDB$ROOT` で参照。`COMPLETED='YES'`、既収集済みの Sequence を除外）から未収集の Archived Redo を一覧取得する |
| 3 | 各ログについて `REGISTER_ARCHIVE_LOG`（`EXPECTED`）を oracle-tgt で呼び出し、`ARCHIVE_LOG_ID` を取得する |
| 4 | oracle-src の Archived Redo ファイルを `docker cp` 経由で `/migfs/archivelogs/` へコピーする |
| 5 | コピー完了後に `RECEIVE_ARCHIVE_LOG`（`EXPECTED → RECEIVED`）を呼び出す |
| 6 | `/migfs/archivelogs/` 側で `sha256sum` を算出する |
| 7 | `REGISTER_ARCHIVE_LOG_COPY`（`RECEIVED`）でコピー情報・チェックサムを登録する |
| 8 | 既存 API `VERIFY_ARCHIVE_LOG_COPY` でチェックサム検証し `VERIFIED` へ遷移させる |
| 9 | `UPSERT_CHECKPOINT` で Thread 別の `MIG_CHECKPOINT` を更新する（連続した検証済み位置のみ前進。途中に未検証の Sequence があれば前進しない） |
| 10 | エラーが発生した場合は `RAISE_ERROR_EVENT`（既存 API）で `ERROR_EVENT` へ記録し、次の Sequence 処理を続行する（スクリプト全体は終了しない） |

**再実行の冪等性**: Step 3 で `REGISTER_ARCHIVE_LOG` が重複例外（`-20002`）を返した場合は既登録として扱い、`ARCHIVE_LOG_ID` を再取得して Step 4 以降を続行する。

### 6.2 `scripts/68_build_logminer_dict.sh` — 辞書ビルド・マーカー確認

**目的**: oracle-src の CDB$ROOT で LogMiner Dictionary を Redo に埋め込み、マーカー付きログを収集・台帳登録する。

**処理フロー（主要ステップ）**

| Step | 内容 |
|---|---|
| 1 | oracle-src の **CDB$ROOT**（`SYSDBA`、PDB 切り替えなし）で `DBMS_LOGMNR_D.BUILD(OPTIONS => DBMS_LOGMNR_D.STORE_IN_REDO_LOGS)` を実行する |
| 2 | `ALTER SYSTEM ARCHIVE LOG CURRENT` でログスイッチを実行し、辞書を含む Redo を確定させる |
| 3 | oracle-src の `V$ARCHIVED_LOG` で `DICTIONARY_BEGIN='YES'` / `DICTIONARY_END='YES'` のログの Sequence 番号を確認する（§7 ノウハウ #1: マーカーが付かない場合は PDB 内で BUILD した可能性がある） |
| 4 | マーカー付きログが確認できない場合はエラーを出力してスクリプトを終了する（`RAISE_ERROR_EVENT` で記録） |
| 5 | マーカー付きログ（辞書を含む連続した複数本）を `/migfs/archivelogs/` へコピーする（`docker cp` 経由） |
| 6 | `REGISTER_ARCHIVE_LOG` → `RECEIVE_ARCHIVE_LOG` → `REGISTER_ARCHIVE_LOG_COPY` → `VERIFY_ARCHIVE_LOG_COPY` の順で台帳登録する（`67_collect_archivelogs.sh` と同じ手順） |
| 7 | `SET_DICT_MARKERS` で該当 `ARCHIVE_LOG` 行の `DICTIONARY_BEGIN_FLAG` / `DICTIONARY_END_FLAG` を `'Y'` に更新する |

**PDB 内ビルドの失敗検知**:

```
【最も危険な罠】
oracle-src の XEPDB1（PDB）内で DBMS_LOGMNR_D.BUILD を実行した場合:
  - PL/SQL は正常終了する
  - アラートログに「XEPDB1(3):Logminer Bld: Done」と出力される（成功に見える）
  - しかし V$ARCHIVED_LOG の DICTIONARY_BEGIN / DICTIONARY_END は両方 'NO' のまま
  - oracle-tgt で START_LOGMNR を実行すると ORA-01371 が発生する

対処: Step 3 で V$ARCHIVED_LOG を確認し、マーカーが 'NO' のままであればエラーを出力して終了する。
     CDB$ROOT（sysdba 接続、ALTER SESSION SET CONTAINER を行わない）で再実行する。
```

### 6.3 `scripts/69_test_phase3_e2e.sh` — E2E テスト

**形式**: `66_test_phase1_2_e2e.sh` と同形式（`chk` 関数・`PASS` フラグ・`[OK]` / `[NG]` 出力）。

**テストケース一覧**

| ID | テスト内容 | 合格条件 |
|---|---|---|
| T01 | `UPSERT_CHECKPOINT` の UPSERT 確認（INSERT 後に UPDATE） | INSERT 後の行数=1。UPDATE 後も行数=1 かつ `SEQUENCE_NO` が変わること |
| T02 | `ARCHIVE_LOG` / `ARCHIVE_LOG_COPY` の登録 → チェックサム検証 → VERIFIED 確認 | `COLLECT_STATUS='VERIFIED'`、`COPY_STATUS='VERIFIED'` |
| T03 | 辞書ビルド（CDB$ROOT）→ `DICTIONARY_BEGIN='YES'` / `DICTIONARY_END='YES'` マーカーが `V$ARCHIVED_LOG` に付くことの確認 | `DICTIONARY_BEGIN_FLAG='Y'` の行が `ARCHIVE_LOG` に存在する |
| T04 | PDB 内ビルドでマーカーが付かないことの確認（最も危険な罠の回帰テスト） | XEPDB1 内でビルドした場合、`DICTIONARY_BEGIN='NO'` であること。`68_build_logminer_dict.sh` がエラー終了すること |
| T05 | Sequence の連番欠落を意図的に作り、`V_ARCHIVE_LOG_GAP`（既存ビュー）で検知されること | 欠落件数 > 0 が `V_ARCHIVE_LOG_GAP` で返ること |
| T06 | `MARK_ARCHIVE_READY`（既存 API）がカバレッジ不足を拒否し、充足時に通ること | 未充足時に `-20003` で例外。充足時に `ARCHIVE_READY_AT` が設定されること |
| T07 | oracle-tgt で LogMiner を起動し、`SRC_SCHEMA` の INSERT / UPDATE / DELETE（複数トランザクション）が `V$LOGMNR_CONTENTS` で解決できること | `SEG_OWNER='SRC_SCHEMA'` の行が取得でき、テーブル名・列名が正しく解決されること |
| T08 | `COMPLETE_PHASE3` の完了条件チェック（未充足 → 例外、充足 → COMPLETED） | 未充足時に `-20011` で例外。充足時に `PHASE_STATUS.STATUS='COMPLETED'` |

---

## 6.5 実装中に踏んだ失敗と対処（ノウハウ）

| # | 現象 | 原因 | 実際に効いた対処 |
|---|------|------|-----------------|
| 1 | `07_pkg_mig_admin_phase3.sql` の PACKAGE BODY が `ORA-00904: "CONSUMED_AT": invalid identifier` と `ORA-00942: table or view does not exist` でコンパイルエラーになった。追加した6本ではなく、**既存のフェーズ1・2 API 側**で落ちていた | フェーズ3の作業前に**回帰確認のつもりで実行した `scripts/62_test_migration_ctl_e2e.sh` が破壊的だった**。同スクリプトは冒頭で `DROP USER migration_ctl CASCADE` を行い、その後 `02`（v2.0の9テーブル）と `03`（v2.0のAPI）**だけ**を再適用する。そのためフェーズ1・2で追加した `04`（`ERROR_EVENT`/`VALIDATION_RUN`/`VALIDATION_RESULT`・`CONSUMED_AT` 等の列追加）と `05`（API 8本追加）が**消えていた**。テスト自体は PASS するため、壊れたことに気づけない | `62` の Setup を「`02`・`03` だけ適用」から**「`sql/migration_ctl/` 配下の番号付きSQLを昇順で全部適用」**に変更した。新しいSQLを追加しても番号さえ振れば自動で含まれる。適用時に `ORA-`/`PLS-` を検出したら即 `exit 1` するようにし、**黙って壊れないよう**にした |
| 2 | `COMPLETE_PHASE3` が `ORA-01400: cannot insert NULL into (MIG_STATUS_HISTORY.RECORD_ID)` で失敗した | `LOG_STATUS_CHANGE` 呼び出し時に `RECORD_ID` として `NULL` を渡していた。`PHASE_STATUS` テーブルから STATUS だけ SELECT していたため、`PHASE_STATUS_ID` が未取得だった | `SELECT PHASE_STATUS_ID, STATUS INTO v_phase_status_id, v_old_status FROM PHASE_STATUS ...` に変更し、`LOG_STATUS_CHANGE` に `v_phase_status_id` を渡すよう修正した |
| 3 | `/migfs/archivelogs/` が WSL2 ホスト（bash スクリプト実行環境）から参照できない（`ls /migfs/` が "No such file or directory"）。`docker cp oracle-src:/path /migfs/file` もホスト側の `/migfs` に書こうとして失敗した | `/migfs` は docker の共有ボリューム（named volume）であり、コンテナ内でのみ参照可能。WSL2 ホストから直接マウントされていない | すべてのファイル操作を `docker exec oracle-src bash -c "cp '${SRC}' '${DEST}'"` でコンテナ内で実行するよう変更した。`sha256sum` や `stat` も同様 |
| 4 | `bash scripts/69_test_phase3_e2e.sh` でテスト実行したところ `RECEIVE_ARCHIVE_LOG`・`VERIFY_ARCHIVE_LOG_COPY` などの手続き呼び出しが全て黙って失敗し、COLLECT_STATUS が変わらなかった | sqlplus では **PL/SQL ブロックを実行する `/` は独立した行に置く必要がある**。`"BEGIN ...; END;/"` のように `END;/` が同一行にあると sqlplus がスラッシュを実行コマンドと認識せず、ブロックが実行されない。エラーメッセージも出ないため気づけない | テストスクリプトの全 PL/SQL ブロック呼び出しを複数行形式（`END;\n/`）に変更し、`mctl_sql_raw` 関数を `printf | docker exec -i ... sqlplus` パイプ方式に変更した |
| 5 | `docker exec -u oracle oracle-tgt bash -c "sqlplus ... <<'SQLEOF'\nSET SERVEROUTPUT ON\nALTER SESSION SET CONTAINER = XEPDB1;\n..."` で `DBMS_OUTPUT.PUT_LINE` の出力が完全に消えた | `SET SERVEROUTPUT ON` を `ALTER SESSION SET CONTAINER` より**前**に設定すると、コンテナ切り替えで SERVEROUTPUT 設定がリセットされ OFF になる | `ALTER SESSION SET CONTAINER = XEPDB1;` を先に実行し、**その後** `SET SERVEROUTPUT ON SIZE UNLIMITED` を設定するよう順序を変更した |
| 6 | LogMiner（`DBMS_LOGMNR.ADD_LOGFILE`）が `ORA-65040: operation not allowed from within a pluggable database` で失敗した | テストスクリプトで `ALTER SESSION SET CONTAINER = XEPDB1` してから LogMiner を呼び出していた。LogMiner の `ADD_LOGFILE` は PDB 内からは呼び出せず、CDB$ROOT で実行する必要がある | T07 の LogMiner ブロックから `ALTER SESSION SET CONTAINER = XEPDB1;` を削除し、`/ as sysdba` 接続のまま（CDB$ROOT のまま）実行するよう変更した |
| 7 | LogMiner で `ORA-01284: file /migfs/archivelogs/arch1_210_...dbf cannot be opened` が発生した | `ARCHIVE_LOG` テーブルには過去の複数回の辞書ビルド分が蓄積されており、`MIN(SEQUENCE_NO) WHERE DICTIONARY_BEGIN_FLAG='Y'` がセッション外の古い辞書 Seq（210）を返していた。Seq=210 のファイルは `/migfs` にコピーされておらず存在しない | `MAX(SEQUENCE_NO) WHERE DICTIONARY_BEGIN_FLAG='Y'` に変更して最新の辞書ビルド Seq を取得するよう修正した。また cp 失敗時はファイルリストに追加しない（`|| true` を排除してif分岐で制御）ようにした |
| 8 | LogMiner で `SRC_SCHEMA.REGIONS` の INSERT/UPDATE/DELETE が検出されず（0件） | `INSERT INTO SRC_SCHEMA.REGIONS (REGION_ID, REGION_NAME) VALUES (9999, ...)` が `ORA-01400: cannot insert NULL into (REGION_CODE)` で失敗していた。`REGION_CODE` が NOT NULL 列だが INSERT に含めていなかった。エラーが `src_pdb_exec` の `/dev/null` リダイレクトで隠れていた | INSERT に `REGION_CODE => 'T07'` を追加した。また冪等性のため先頭で `DELETE FROM SRC_SCHEMA.REGIONS WHERE REGION_ID=9999` を追加した |

| 9 | フレッシュ構築時のみ `08_views_phase3.sql` が `ORA-01031: insufficient privileges` で失敗。開発中の環境では成功していたため気づけなかった | `migration_ctl` に **`CREATE VIEW` 権限がなかった**。Oracle 12c 以降の `RESOURCE` ロールには `CREATE VIEW` が含まれない。開発時は手動で権限を足していたため通っており、`DROP USER` → 再作成の経路で初めて露見した | `01_migration_ctl_user.sql` に `GRANT CREATE VIEW TO migration_ctl;` を追加。**修正した 62 の「全DDL昇順適用＋エラーで即停止」がこれを検出した**（従来の 02・03 だけ適用する方式では 08 を流さないため永久に気づけなかった） |

> **本番への示唆（権限）**: 「開発環境では動くが、作り直すと動かない」は権限付与を手作業で補ったときに必ず起きる。
> 付与した権限は**必ずユーザー作成SQLに書き戻す**こと。`RESOURCE` ロールに何が含まれるかはバージョンで変わるため、
> 必要な権限は個別 GRANT で明示するほうが安全。

> **本番への示唆**: 「古いテストを回したら新しいスキーマが壊れる」構造は、環境を共有していると必ず事故になる。
> しかも**テストは PASS するため気づけない**のが最も危険。DDL を積み増していく方式を採る場合、
> 各テストの初期化処理は**常に最新の全DDLを適用する**か、そもそも破壊的初期化をしない設計にすること。
>
> **sqlplus での PL/SQL 実行**: `bash -c "sqlplus ... <<'HEREDOC'\n...\nEND;/\nHEREDOC"` のパターンは
> `END;/` が同一行のとき PL/SQL を実行しない罠がある。bash スクリプトから sqlplus を呼ぶ際は
> パイプ経由（`printf '...\n/\n' | docker exec -i ... sqlplus`）で明示的に改行を入れること。

---

## 7. PoC 既知ノウハウ（実装時の注意）

`docs/gap-analysis-5phase-schema.md` §1.2 の失敗表より引用・要約する。

| # | 現象 | 原因 | 効いた対処 |
|---|------|------|-----------|
| 1 | 移行先の `START_LOGMNR` が **ORA-01371: Complete LogMiner dictionary not found** で失敗 | `DBMS_LOGMNR_D.BUILD(STORE_IN_REDO_LOGS)` を **XEPDB1（PDB）内で実行していた**。PL/SQL は正常終了し、アラートログにも成功と出るが、辞書が Redo ストリームへ書き出されない。`V$ARCHIVED_LOG` の `DICTIONARY_BEGIN`/`DICTIONARY_END` は両方 `'NO'` のまま。 | **CDB$ROOT で BUILD を実行する**（`ALTER SESSION SET CONTAINER` を行わずデフォルト接続のまま）。これにより `DICTIONARY_BEGIN='YES'` / `DICTIONARY_END='YES'` が正しく付与された |
| 2 | `V$LOGMNR_CONTENTS` の SELECT が **ORA-01306: dbms_logmnr.start_logmnr() must be invoked before selecting** | LogMiner セッションは**セッションローカル**であり、`ADD_LOGFILE`/`START_LOGMNR` を実行したセッションが終了すると解析結果が破棄される。別々の `docker exec ... sqlplus` で実行していたため、SELECT 時にはセッションが消えていた。 | **ADD_LOGFILE → START_LOGMNR → SELECT を同一 sqlplus セッション内で実行する**（1 つのヒアドキュメントにまとめる） |
| 3 | `SEG_OWNER='SRC_SCHEMA'` の変更が `CON_ID=1`（CDB$ROOT）として報告される | PDB 内の変更でも CON_ID が CDB$ROOT として報告されるケースがある（既知挙動）。 | **CON_ID でフィルタせず `SEG_OWNER` で絞る**。現行実装の知見がそのまま有効 |

> **本番への示唆**: 失敗ケース #1 が最も危険。辞書ビルドの「正常終了」を成功判定にせず、必ず `V$ARCHIVED_LOG` の `DICTIONARY_BEGIN`/`DICTIONARY_END` マーカーを機械的に確認すること。`ARCHIVE_LOG` テーブルが `DICTIONARY_BEGIN_FLAG`/`DICTIONARY_END_FLAG` を持つ設計は、まさにこの確認を強制するためのものである。

---

## 8. 制約事項（この検証環境で確認できないもの）

`docs/handoff-guide.md` §5.1 の未検証台帳より、フェーズ3に特に関連するものを引用する。

| ID | 未検証事項 | なぜ再現できないか | 本番で必要な確認 |
|---|---|---|---|
| **UNV-01** | RAC の Thread 別挙動 | `oracle-src` はシングルインスタンス（Thread=1 のみ） | 全 Thread の Archived Redo が漏れなく収集されること。Thread 別 Sequence 管理（`MIG_CHECKPOINT` の Thread 別保持）。`COMPLETE_PHASE3` の条件 d が全 Thread をカバーすること |
| **UNV-04** | Oracle 12c / 19c の実バージョン差 | 両側とも 21c XE | `DBMS_LOGMNR_D.BUILD` の動作差、`V$ARCHIVED_LOG` の列差、12.1/12.2 による挙動差 |
| **UNV-05** | 独立した物理ファイルサーバ | 単一ホスト上の共有ボリューム（`/migfs`）で代替 | NFS/CIFS マウント方式、帯域制約、障害時の Archived Redo 再取得手順、容量設計 |

> **UNV-01 について**: `MIG_CHECKPOINT` の `CHECKPOINT_KEY` を `'THREAD:N'`、`THREAD_NO` を N として設計するのは、本番 RAC 環境への対応を前提にしているためである。この検証環境では Thread=1 のみで `'THREAD:1'` を使うが、API シグネチャと列構造は RAC 環境で拡張できる形を維持する。

---

## 9. 未決事項・次段判断が必要なもの

| ID | 事項 | 現在の方針 | 本番時の判断ポイント |
|---|---|---|---|
| P3-01 | ARCHIVELOGモード設定・出力先・保持期間 | docker 環境ではデフォルト設定 | 既存 Archive Destination と保持期間、MANDATORY/OPTIONAL、出力先障害時の DB1.0 への影響 |
| P3-02 | Supplemental Logging の設定レベル | Minimal のみ（`sql/cdc/14_supplemental_logging.sql` 実装済み） | Primary Key Supplemental Logging の範囲、テーブル単位 Log Group の要否 |
| P3-06 | 1日当たり Redo 量 | 未調査（検証データは数十 MB / 3 表） | 平均・最大日次 Redo 量、ピーク時間帯、RAC Thread 別生成量、ファイルサーバ容量見積り |
| P3-07 | 最終 Archived Redo の確定手順 | 未設計（`04_finalize_archive_log_tgt.sql` として実装予定） | 書込み停止 → 全 Thread ログスイッチ → 最終 Sequence 確認 → `SET_TARGET_END_SCN` |
