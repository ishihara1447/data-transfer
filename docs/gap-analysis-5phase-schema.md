# ギャップ分析: 「5フェーズ・移行管理テーブル連携反映版」設計 vs 現行検証環境

## 0. この文書の目的

2026-07-26付で共有された以下2文書（以下「新設計」）に対し、現行の `data-transfer`
検証環境実装がどこまで一致し、何が不足しているかを棚卸しする。

- 「Oracleデータ移行 概要説明文書」
- 「Oracleデータ移行 調査・検討・検証・設計事項一覧（5フェーズ・移行管理テーブル連携反映版）」

実装方針の決定はこの文書では行わない（ギャップの可視化のみ）。
既存の `docs/gap-analysis.md`（外部リスク分析報告書 vs 現行環境）とは比較対象が異なる別文書として扱う。

**改訂履歴（v2 - 2026-07-26）**:
- 移行管理スキーマの設計対象を3テーブルから先行準備A対象の9テーブルへ更新。
- DB 構成前提（同一 PDB 内・DB Link 不使用）を明記し、DB Link を前提とした記述を是正。
- §3.1 の「現行管理状態」を新設計の前提（DB2.0 同一 PDB 内に全スキーマを集約）に合わせて更新。
- §3.2 の有無マトリクスを先行準備A設計（9テーブル）の実装状況に更新。
- §7 優先度別ギャップを v2 設計反映後の状態に更新。

---

## 1. 最大の構造的相違点：LogMinerの実行場所

新設計と現行実装は、**LogMinerをどちら側で実行するか**という最も根本的な設計判断が逆になっている。

| 項目 | 新設計 | 現行実装 |
|------|--------|----------|
| LogMiner実行場所 | **DB2.0（移行先）側** | **移行元（oracle-src）側** |
| 辞書の持ち方 | Archived Redo自体にLogMiner Dictionaryを埋め込み、移行先で完結 | 移行元のonline catalog辞書で解析し、結果SQLだけを搬送 |
| 搬送対象 | Archived Redo Logそのもの（大） | 抽出済み差分SQL（小） |
| 採用理由 | （文書上は明記なし。PDBスキーマを辞書に含める前提） | **実証済みの制約回避**：flat-file辞書がPDBスキーマを含まないため、移行先でCDB$ROOTから解析すると変更0件になる（`docs/delta-extract-design.md` §1）。移行元でしか正しく解析できないことが検証で判明した |

**懸念点**：現行実装は「移行先でLogMinerを動かす」を当初想定していたが、`DBMS_LOGMNR_D.BUILD`
のflat-file辞書がPDBオブジェクトを含まない制約（README §8 学び#3、delta-extract-design.md §1）に
実際にぶつかり、移行元実行方式へ改訂した経緯がある。新設計はこの制約を
**「Archived Redo自体にDictionaryを格納する」方式**（`STORE_IN_REDO_LOGS`相当）で回避しようとしていると
読める。

### 1.1 PoC実施結果（2026-07-26）：新設計の前提は「条件付きで成立」

上記の懸念（P4-01相当）を実機検証した。**結論：新設計の「DB2.0側でLogMinerを実行し、
PDB内スキーマの変更を解決する」という前提は成立する。** ただしCDB$ROOTでの辞書ビルドが必須という条件が付く。

**検証環境**: oracle-src（Oracle 21c XE, ARCHIVELOGモード, Supplemental Logging MIN=YES）→
oracle-tgt（同）。対象は `SRC_SCHEMA.REGIONS`（PDB=XEPDB1 配下）。

**検証手順と結果**:

1. oracle-src の CDB$ROOT で `DBMS_LOGMNR_D.BUILD(OPTIONS => DBMS_LOGMNR_D.STORE_IN_REDO_LOGS)` を実行
2. `SRC_SCHEMA.REGIONS` にテスト用 UPDATE を実行しCOMMIT
3. `ALTER SYSTEM ARCHIVE LOG CURRENT` でログを確定
   → `V$ARCHIVED_LOG` に `DICTIONARY_BEGIN='YES'`（seq 210）/ `DICTIONARY_END='YES'`（seq 211）のマーカーを確認
4. 辞書入りログ（210, 211）とDML分（212）を `docker cp` で oracle-tgt へ搬送
5. oracle-tgt で `DBMS_LOGMNR.ADD_LOGFILE` 3本 → `START_LOGMNR(OPTIONS => DICT_FROM_REDO_LOGS + COMMITTED_DATA_ONLY)`
6. `V$LOGMNR_CONTENTS` を `SEG_OWNER='SRC_SCHEMA'` で検索

**取得できた結果**（テーブル名・列名まで完全に解決されている）:

```sql
update "SRC_SCHEMA"."REGIONS" set "REGION_NAME" = 'LOGMINER_POC_TEST_UPD2'
 where "REGION_ID" = '999' and "REGION_CODE" = 'POC'
   and "REGION_NAME" = 'LOGMINER_POC_TEST_UPD' and ... and ROWID = 'AAASg8AAMAAAACEAAK';
```

つまり、現行実装が移行元実行方式へ転換する理由となった「flat-file辞書がPDBスキーマを含まない」制約は、
**redoログ埋め込み辞書（`STORE_IN_REDO_LOGS`）を使えば回避できる**。

### 1.2 PoCで踏んだ失敗と対処（ノウハウ）

| # | 現象 | 原因 | 効いた対処 |
|---|------|------|-----------|
| 1 | 移行先の `START_LOGMNR` が **ORA-01371: Complete LogMiner dictionary not found** で失敗 | `DBMS_LOGMNR_D.BUILD(STORE_IN_REDO_LOGS)` を **XEPDB1（PDB）内で実行していた**。PL/SQL自体は正常終了し、アラートログにも `XEPDB1(3):Logminer Bld: Done` と出力されるため成功したように見えるが、実際には辞書がredoストリームへ書き出されず、`V$ARCHIVED_LOG` の `DICTIONARY_BEGIN`/`DICTIONARY_END` は両方 `NO` のままだった | **CDB$ROOT で BUILD を実行する**（`ALTER SESSION SET CONTAINER` を行わずデフォルト接続のまま実行）。これにより `DICTIONARY_BEGIN='YES'` / `DICTIONARY_END='YES'` のマーカーが正しく付与された |
| 2 | `V$LOGMNR_CONTENTS` の SELECT が **ORA-01306: dbms_logmnr.start_logmnr() must be invoked before selecting from v$logmnr_contents** | LogMinerセッションは**セッションローカル**であり、`ADD_LOGFILE`/`START_LOGMNR` を実行した sqlplus セッションが終了すると解析結果も破棄される。別々の `docker exec ... sqlplus` で実行していたため、SELECT時には既にセッションが消えていた | **ADD_LOGFILE → START_LOGMNR → SELECT を同一 sqlplus セッション内で実行する**（1つのヒアドキュメントにまとめる） |
| 3 | `SEG_OWNER='SRC_SCHEMA'` の変更が `CON_ID=1`（CDB$ROOT）として報告される | 既知の挙動（README §8 学び#1 と同一）。PDBの変更でもCON_IDはCDB$ROOTとして報告されるケースがある | **CON_IDでフィルタせず `SEG_OWNER` で絞る**。現行実装の知見がそのまま有効 |

> **本番への示唆**: 辞書ビルドをPDB内で実行しても**エラーにならず成功したように見える**点が最も危険。
> 「BUILDが正常終了した」ことを成功判定にせず、必ず `V$ARCHIVED_LOG` の
> `DICTIONARY_BEGIN`/`DICTIONARY_END` マーカーの存在を確認する運用が必須。
> 新設計の `ARCHIVE_LOG` テーブルが `DICTIONARY_BEGIN_FLAG`/`DICTIONARY_END_FLAG` を
> 持つ設計になっているのは、まさにこの確認を機械化するために正しい。

### 1.3 PoC結果を受けた判断

新設計のアーキテクチャ（DB2.0側でLogMiner実行）は技術的に成立するため、
**新設計の方向で進めてよい**。ただし以下2点は現行実装の知見を引き継ぐ必要がある。

- `SEG_OWNER` によるフィルタ（CON_IDフィルタは使えない）
- 辞書ビルドはCDB$ROOTで実行し、マーカーで成否を検証する

なお、搬送量の観点では現行方式（差分SQLのみ搬送・小）が有利で、新設計（Archived Redo全量搬送・大）は
搬送コストが増える。ただし新設計は「移行元DBに解析負荷をかけない」「移行元での稼働制約が小さい」という
利点があるため、これはトレードオフとして本番要件（移行元の負荷許容度 vs 搬送帯域）で判断すべき事項である。

---

## 2. 全体アーキテクチャの対応表

| 新設計の構成品 | 現行実装での対応 | 状態 |
|---|---|---|
| DB1.0（Oracle 12c） | oracle-src（Oracle 21c XE、本番はOracle 12c想定） | ○ 概念一致（バージョンは検証簡略化のためXE） |
| DB2.0（Oracle 19c） | oracle-tgt（Oracle 21c XE） | △ バージョン不一致（19c vs 21c XE。検証環境の制約） |
| Migrationファイルサーバ（DB非搭載・マウント中継） | ホスト側 `docker cp`（コンテナ間で直接搬送、独立ファイルサーバ層なし） | ✕ 未実装。中継専用ノードの構成要素がない |
| DB2.0側1.0スキーマ | STAGING_SCHEMA | ○ 概念一致 |
| DB2.0側2.0スキーマ | TARGET_SCHEMA | ○ 概念一致 |
| 移行管理スキーマ（DB2.0 同一PDB内・DB Link 不使用） | LOG_SCHEMA（変換ログのみ）＋ CDC_SCHEMA（現行実装では移行元oracle-src側）＋ STAGING_CTL（tgt側）に分散 | △ 機能はあるが**統合された移行管理スキーマとして存在しない**（詳細は3章） |
| 8TB SSD搬送方式（代替案） | 未検討（`docker cp`のみ） | ✕ 未検討 |

**前提の明確化**: 新設計では `cdc_schema`・`staging_ctl`・`log_schema`・`migration_ctl` はすべて
DB2.0の同一PDB内に構築する。現行実装の `cdc_schema` が移行元（oracle-src）側に存在することは
現行実装固有の状態であり、新設計への移行時には DB2.0 側へ集約する。
**DB Link は使用しない**（設計メモ §12.1）。

---

## 3. 移行管理スキーマ：最大のギャップ領域

新設計の核心は「`MIGRATION_RUN_ID` を親キーとして全フェーズの状態・ファイル・SCN・エラーを
一元管理する」という点にある。ここが現行実装との差が最も大きい。

### 3.1 現行の管理状態（スキーマ横断で分散）

| スキーマ | 役割（現行実装） | 主なテーブル |
|---|---|---|
| `cdc_schema`（現行: oracle-src側） | 抽出制御 | `cdc_table_catalog`（replay_category分類）, `ops_config`/`ops_config_history`, `lob_resync_request` |
| `staging_ctl`（tgt側） | CDC適用制御 | `delta_queue`, `apply_ledger`, `delta_apply_state`, `delta_manual_review_queue`, `lob_resync_target` |
| `log_schema`（tgt側） | 全量移行・変換ログ | `migration_run_log`, `migration_step_log`, `migration_error_log`, `transform_catalog`, `transform_state`, `code_mapping` |

**問題点**：

- **実行を横断する親キーがない**：`log_schema.migration_run_log.run_id` はあるが、これは
  フェーズ2（全量Import相当）〜フェーズ5（変換）のログ専用。フェーズ1のExportジョブ管理や
  フェーズ3のArchived Redo収集とは紐付いていない。CDC側には「実行ID」の概念自体がない。
- **PoC/リハーサル/本番の分離機構がない**：新設計の「同一DB間でもMIGRATION_RUN_IDを分けて過去実行を
  上書きしない」という運用原則に相当する仕組みが現行にはない。
- **Data Pumpジョブそのものを管理DBで追跡していない**：`DATAPUMP_JOB` / `DATAPUMP_JOB_OBJECT` /
  `DATAPUMP_FILE` に相当する管理テーブルは存在せず、Data Pumpの実行結果は `logs/*.log` にしか残らない。
- **Archived Redoの論理ログ・物理コピーの管理がない**：`ARCHIVE_LOG` / `ARCHIVE_LOG_COPY` に
  相当するテーブルはない。`scripts/47_archive_gap_check.sh` は実装済みだが、`V$ARCHIVED_LOG` を
  都度クエリする方式であり、永続化した独自台帳ではない。

### 3.2 先行準備A設計（9テーブル）の実装状況マトリクス

先行準備Aで設計確定した9コアテーブルの実装状況を示す。

| 先行準備Aテーブル | 現行での相当物 | 有無 | 先行準備A設計との差分 |
|---|---|:---:|---|
| `MIGRATION_RUN` | `log_schema.migration_run_log`（部分的。フェーズ2・5専用） | △ | BASELINE_SCN / MINING_START_SCN 分離・TARGET_END_SCN・LAST_APPLIED_SCN 等が不足。設計書 v2.0 で定義済み |
| `PHASE_STATUS` | なし | ✕ | フェーズ進捗を表す独立テーブルなし。設計書 v2.0 で7行構成を定義済み |
| `MIGRATION_OBJECT` | `cdc_schema.cdc_table_catalog`（replay_category中心） | △ | SOURCE/STAGE/TARGET 3層・独立フラグ・PRIMARY_KEY_COLUMNS 等が不足。設計書 v2.0 で定義済み |
| `DATAPUMP_JOB` | なし（シェルログのみ） | ✕ | 設計書 v2.0 で定義済み。実装未着手 |
| `DATAPUMP_JOB_OBJECT` | なし | ✕ | 設計書 v2.0 で定義済み。実装未着手 |
| `DATAPUMP_FILE` | なし（チェックサム記録もスクリプト任せ） | ✕ | 設計書 v2.0 で定義済み。実装未着手 |
| `ARCHIVE_LOG` | なし（`V$ARCHIVED_LOG` 直接クエリのみ） | ✕ | 設計書 v2.0 で定義済み。DICTIONARY_BEGIN/END_FLAG 列で辞書ビルド確認を機械化 |
| `ARCHIVE_LOG_COPY` | なし | ✕ | 設計書 v2.0 で定義済み。実装未着手 |
| `MIG_STATUS_HISTORY` | なし | ✕ | 設計書 v2.0 で定義済み。追記専用・更新削除禁止 |

凡例: ○=一致 / △=部分的に相当する仕組みあり / ✕=対応物なし

### 3.3 次段テーブル群（先行準備A範囲外）の現行対応

以下は先行準備Aの対象外（フェーズ4・5実装前または本番設計フェーズに追加）。

| 次段テーブル | 現行での相当物 | 有無 |
|---|---|:---:|
| `LOGMINER_BATCH` / `LOGMINER_BATCH_LOG` | なし（LogMiner起動は`17b_sys_cdc_runner.sql`内でその場実行、バッチ単位の永続記録なし） | ✕ |
| `MINED_TRANSACTION` / `MINED_CHANGE` | `cdc_schema.delta_queue`（近い。ただしXID単位のトランザクション表とDML明細表が分離されていない） | △ |
| `APPLY_BATCH` / `APPLY_TASK` | `staging_ctl.apply_ledger` + `staging_ctl.delta_apply_state`（近い。バッチ単位の概念はない） | △ |
| `MIG_CHECKPOINT` | `staging_ctl.delta_apply_state.last_applied_id` 等（近いが汎用チェックポイントではない） | △ |
| `MIGRATION_OBJECT_PHASE_STATUS` | なし | ✕ |
| `TRANSFORM_BATCH` | `log_schema.transform_state` | △ |
| `KEY_MAPPING` | `log_schema.code_mapping`（ステータスコード変換のみ） | △ |
| `VALIDATION_RUN` / `VALIDATION_RESULT` | `scripts/49_two_stage_verify.sh`（DBへの永続化はない） | △ |
| `ERROR_EVENT` | `log_schema.migration_error_log`（全量移行のみ対象。CDC側は分散） | △ |

---

## 4. 基準SCN・解析開始SCNの分離

新設計は `BASELINE_SCN`（全量断面用）と `MINING_START_SCN`（LogMiner解析開始位置）を
明確に分離し、「基準SCNを跨ぐ長時間トランザクション」を再構成できるよう
先行Redoを保全する設計になっている。

現行実装（`docs/gap-analysis.md` G2 参照）は **単純な `SCN > last_scn` フィルタ**であり、

- 基準SCN相当の値と解析開始位置の区別がない
- 長時間トランザクションが基準断面を跨ぐケースは未対応（既存ギャップ分析でも最優先ギャップ=G2として指摘済み）
- `COMMITTED_DATA_ONLY` オプションも未使用（G3）

新設計を導入すること自体が現行最大の弱点の解消策になっている。

---

## 5. フェーズ対応表（新設計 5フェーズ vs 現行実装ステップ）

| 新設計フェーズ | 現行実装での対応スクリプト/ドキュメント | 実装状況 |
|---|---|---|
| 先行準備A（管理スキーマ最小構築・9テーブル） | `sql/migration_ctl/02_migration_ctl_ddl.sql`（旧3テーブル版） | △ 3テーブル版のみ実装済み。9テーブル版 DDL は v2.0 設計書に基づき再作成が必要 |
| 先行準備B（Archived Redo出力・収集） | `14_supplemental_logging.sql`, `47_archive_gap_check.sh` | △ Supplemental Loggingは実装済み。収集・保全の永続台帳はなし |
| フェーズ1（初回全量Export） | `30_initial_load_flashback.sh` | △ AS OF SCN方式は実装済みだが、Data Pump Exportという形ではない |
| フェーズ2（初回全量Import） | 同上 ＋ `log_schema.migration_*_log`（同一DB内SRC→TGTスキーマ移行のサンプル実装） | △ 本番のDataPump Import相当の検証はされていない |
| フェーズ3（Archived Redo収集） | `47_archive_gap_check.sh`, `04_sync_archivelogs.sh` | △ 欠落チェックは実装済みだが、独立フェーズとしての管理はない |
| フェーズ4（LogMiner解析・差分反映） | `31_pkg_delta_extract_src.sql`, `33_pkg_delta_apply_tgt.sql`, `40_cdc_cycle.sh`, `41_cdc_daemon.sh` | ○ 最も作り込まれている領域。ただしLogMiner実行場所が新設計と逆（1章参照） |
| フェーズ5（1.0→2.0変換） | `41_pkg_transform_util.sql`, `42_pkg_transform.sql` | ○ 実装済み・E2E PASS（LOBパススルー含む） |

---

## 6. 現行実装が新設計と既に整合している点

- **三段構え（全量→差分→変換）の骨格**自体は新設計の5フェーズと矛盾しない。
- **差分適用の安全設計**（replay_category分類・ホワイトリスト・手動調査キュー、README §11）は、
  新設計のP4-17/P4-18（LOB差分方式）が今後決めるべき内容を、現行実装は既に
  「周期的ターゲット再同期方式」として実装・E2E検証済みであり、**現行の方がここは先行している**。
- **冪等性の設計思想**（`apply_ledger`によるTx単位の適用結果記録、`delta_apply_state`による再開点管理）は、
  新設計のAPPLY_TASK/MIG_CHECKPOINTと設計思想が一致している。テーブル粒度が違うだけ。
- **DDL凍結の重要性の認識**は両者一致（README §9用語集「テーブル構成の凍結」、新設計12.1前提）。
- **二段階検証**（形式＋内容）は`scripts/49_two_stage_verify.sh`で実装済み（新設計VALIDATION_RUN/RESULTが目指す内容に近い）。

---

## 7. 優先度別ギャップまとめ（v2 設計反映後）

### 最優先（v2 設計で解決済み・実装が必要）

- **統合移行管理スキーマ（先行準備A 9テーブル）のDDL実装**：
  設計書 v2.0（`docs/migration-control-schema-design.md`）に定義済み。
  implementation-engineer が既存3テーブル版 DDL を全体再作成方式で v2.0 仕様に作り直す。
- **BASELINE_SCN / MINING_START_SCN の分離**：既存最優先ギャップ（G2/G3/G4）の解消と直結。
  MIGRATION_RUN に両列が定義済み（v2.0 設計書）。
- **PKG_MIG_ADMIN の実装**：設計書 v2.0 §8 に API 仕様を定義済み。implementation-engineer が実装する。

### 高（v2 設計適用後に着手）

- **DATAPUMP_JOB / DATAPUMP_FILE 相当の管理テーブル**：設計書 v2.0 に定義済み。実装未着手。
- **ARCHIVE_LOG / ARCHIVE_LOG_COPY の永続台帳**：設計書 v2.0 に定義済み。実装未着手。
  `DICTIONARY_BEGIN_FLAG`/`DICTIONARY_END_FLAG` による辞書ビルド成否の機械的確認が可能になる。

### 中（本番設計に向けて必要）

- `MIG_CHECKPOINT` テーブル（フェーズ3用途での先行追加可否を次段判断）
- Migrationファイルサーバという独立中継層の検証（現行は`docker cp`直接搬送）
- 8TB SSD搬送方式の比較PoC（未着手）
- `KEY_MAPPING`の汎用化（現行`code_mapping`はステータスコード変換専用）

### 低（既存実装が新設計より先行しており、追従の必要性が低い領域）

- LOBテーブルの差分反映方式（現行の周期的再同期方式は新設計のP4-17/18が今後検討する内容を先取り済み）
- 差分適用の安全分類（replay_category）は現行の方が具体化されている

---

## 8. 結論

新設計は、現行実装が抱える**最優先の未解決ギャップ（COMMIT_SCN境界・基準SCN分離・統合管理スキーマ）**
を正面から設計しようとしている点で価値が高い。

LogMiner実行場所の問題（§1）は §1.1 の PoC により解決済み（新設計の DB2.0 側実行は条件付きで成立）。

**移行管理スキーマについては以下の状態に至った**：

1. 先行準備A対象の9テーブル設計が `docs/migration-control-schema-design.md` v2.0 に確定した。
2. 実装は implementation-engineer が既存 DDL（3テーブル版）を v2.0 仕様で全体再作成することで実施する。
3. LogMiner解析・差分適用・変換管理の詳細テーブル（LOGMINER_BATCH 等）は次段（フェーズ4実装前）に追加する。

**推奨する次の着手順**：

1. implementation-engineer による先行準備A DDL（9テーブル）の再作成実装
2. PKG_MIG_ADMIN の PL/SQL 実装（設計書 v2.0 §8 仕様に基づく）
3. フェーズ1・2（Data Pump Export/Import）の実機試験
4. フェーズ3（Archived Redo 収集）の永続台帳連携実装
