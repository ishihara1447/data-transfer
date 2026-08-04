# マスターチェックリスト — 決定・検証事項と成果物の全件一覧

<!-- このファイルは scripts/70_progress_report.sh による自動生成物です。直接編集しないでください。 -->
<!-- 進捗を変更するときは docs/progress.yml を編集し、上記スクリプトを再実行してください。 -->

最終更新: 2026-07-31
出典: 設計メモ「Oracleデータ移行 調査・検討・検証・設計事項一覧（5フェーズ・移行管理テーブル連携反映版）」§3.3/§4.3/§5.3/§6.3/§7.3 ＋ 2026-07-27「Oracle更新日時差分ダンプ方式 再検証・高度化検討書」
目的: **母数を把握する**。本番移行までに決めること・検証すること・作ることの総量と、現時点の消化状況を1か所に集約する。

> 各項目の中身は出典の設計メモを参照してください（原典はこのリポジトリに含まれません。[`handoff-guide.md`](handoff-guide.md) §7）。
> 信頼度の考え方（✅検証済み / 🟡仮決定 / 🔴本番未検証）は [`handoff-guide.md`](handoff-guide.md) を参照。

---

## 1. 母数サマリ

| 区分 | 件数 |
|---|---:|
| **決定・検証事項** | **75 件** |
| **成果物（延べ）** | **163 件** |
| 完了率 | **44.0%** |
| この環境で進められる母数 | 69 件（75 − 本環境では不可 6） |

### 1.1 フェーズ別の内訳

| フェーズ | 件数 | ✅完了 | 🟡着手・部分 | ❌未着手 | 🔴本環境では不可 |
|---|---:|---:|---:|---:|---:|
| フェーズ1：初回全量 Data Pump Export | 16 | 6 | 6 | 2 | 2 |
| フェーズ2：初回全量 Data Pump Import | 16 | 9 | 3 | 2 | 2 |
| フェーズ3：Archived Redo Log 出力・収集 | 7 | 5 | 1 | 1 | 0 |
| フェーズ4：Archived Redo 解析・1.0スキーマ差分反映 | 26 | 10 | 9 | 5 | 2 |
| フェーズ5：1.0スキーマ→2.0スキーマ 変換投入 | 10 | 3 | 3 | 4 | 0 |
| **合計** | **75** | **33** | **22** | **14** | **6** |

### 1.2 優先度別（設計メモの定義）

| 優先度 | 意味 | 件数 | うち完了 |
|---|---|---:|---:|
| A | 移行方式の成立、データ欠落防止、早期着手を左右する | 56 | 30 |
| B | 性能、停止期間、再実行性、運用品質へ大きく影響する | 18 | 3 |
| C | 詳細実装または長期運用として必要になる | 1 | 0 |

---

## 2. 推移（バーンダウン）

`scripts/70_progress_report.sh` を実行するたびに記録されます（同日は上書き）。

| 日付 | ✅完了 | 🟡着手 | ❌未着手 | 🔴不可 | 完了率 |
|---|---:|---:|---:|---:|---:|
| 2026-07-27 | 33 | 17 | 19 | 6 | 44.0% |
| 2026-07-31 | 33 | 22 | 14 | 6 | 44.0% |

> 記録開始（2026-07-27）からの完了件数の増加: **+0件**

---

## 3. 決定・検証事項 一覧（75件）

凡例: ✅完了 / 🟡着手・部分的 / ❌未着手 / 🔴本環境では検証不可


### 3.1 フェーズ1：初回全量 Data Pump Export

| ID | 優 | 種別 | 決めること・検証すること | 現状 | 根拠・補足 |
|---|:-:|---|---|:-:|---|
| P1-01 | A | 設計・確認 | 移行元PDB・スキーマの確定 | 🟡 | TMP-10 で仮決定（oracle-src/XEPDB1/SRC_SCHEMA） |
| P1-02 | A | 調査・設計 | 移行対象テーブル一覧の正式化 | 🟡 | TMP-10 で仮決定（3表）。本番500表の正式化と適応型差分方式の分類に必要な棚卸しは未 ／ **根拠**: docs/delta-method-decision-matrix.md / docs/delta-performance-poc-plan.md に必要項目と分類ゲートを定義 |
| P1-03 | A | 調査 | 特殊データ型の棚卸し | ❌ | 特殊型の棚卸し未実施。検証環境は基本型＋LOBのみ |
| P1-04 | A | 設計・先行準備 | 基準SCN・解析開始SCNの決定、取得、登録 | ✅ | **根拠**: sql/phase1/02_get_baseline_scn.sql ＋ PKG_MIG_ADMIN.FIX_BASELINE_SCN。SCN外部記録票 out/scn_record_*.txt を生成。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） T03/T15 |
| P1-05 | A | 設計 | Export内容の決定 | ✅ | **根拠**: sql/phase1/03_expdp_grp01.par / grp02.par。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） T04 |
| P1-06 | A | 検討・設計 | Data Pump取得単位・ジョブ分割 | 🟡 | TMP-06 で2ジョブに仮決定し部分再実行まで検証済み（E2E T05〜T08）。本番500表の分割設計は未 |
| P1-07 | A | 調査・PoC・設計 | UNDO容量・ORA-01555対策 | 🟡 | 変更キー方式で必要なUNDO保持時間の算定式とC1/C2比較条件を設計。容量試算・ORA-01555試験は未実施（UNV-02/10） ／ **根拠**: docs/dirty-key-snapshot-design.md §2/§9、docs/delta-performance-poc-plan.md P3/P4 |
| P1-08 | A | 設計・環境準備 | Migrationファイルサーバ上の保存先・DIRECTORY設計 | ✅ | **根拠**: docker-compose.yml の named volume migfs ＋ DIRECTORY MIG_FS_DIR。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） T04（/migfs へ直接出力を確認） |
| P1-09 | B | 設計 | ダンプファイル命名・分割・保持方針 | ❌ | 命名・分割・保持方針は未策定 |
| P1-10 | B | PoC・試算 | Data Pumpダンプ容量の試算 | 🔴 | 容量実測は本環境では取得不可（UNV-02） |
| P1-11 | B | PoC・設計 | 並列度・DB1.0業務影響・書込み性能 | 🔴 | 並列度・業務影響の実測は本環境では取得不可（UNV-02） |
| P1-12 | B | 設計・PoC | 圧縮・暗号化・ファイル完全性 | 🟡 | チェックサム（完全性）は整備中。圧縮・暗号化は未 |
| P1-13 | A | 設計・環境準備 | Export実行ユーザー・必要権限 | ✅ | **根拠**: sql/phase1/01_precheck_export.sql（DIRECTORY権限をGRANTEE列で確認）。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） |
| P1-14 | A | 設計・PoC | Export監視・異常終了・再開・再実行 | ✅ | **根拠**: sql/phase1/05_monitor_expdp.sql ＋ 異常時 RAISE_ERROR_EVENT。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） T05〜T08（意図的失敗→ERROR_EVENT記録→解消→GRP02部分再実行） |
| P1-15 | A | 設計 | Export完了判定 | ✅ | **根拠**: PKG_MIG_ADMIN.COMPLETE_PHASE による6条件のSQL機械判定。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） T06（条件未達で例外）/ T10（充足でCOMPLETED） |
| P1-16 | A | PoC・設計 | BLOB／CLOB全量Export検証 | 🟡 | 21c XEの代表LOB表で全行Exportを実測済み。5TB/500表のLOBジョブ分割と本番相当性能は未確定 ／ **根拠**: docs/datapump-performance-analysis.md B1、scripts/74_benchmark_datapump.sh |

### 3.2 フェーズ2：初回全量 Data Pump Import

| ID | 優 | 種別 | 決めること・検証すること | 現状 | 根拠・補足 |
|---|:-:|---|---|:-:|---|
| P2-01 | A | 設計・環境準備 | 投入先PDB・1.0スキーマの確定 | 🟡 | TMP-10 で仮決定（oracle-tgt/XEPDB1/STAGING_SCHEMA） |
| P2-02 | A | 設計・環境準備 | 1.0スキーマユーザー・表領域・QUOTA | ✅ | **根拠**: sql/phase2/01_create_migration_10_schema.sql ＋ 02_grant_import_privileges.sql。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） |
| P2-03 | A | 設計 | スキーマ対応・REMAP_SCHEMA | ✅ | **根拠**: sql/phase2/05_impdp_grp01.par / grp02.par の REMAP_SCHEMA。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） T11 |
| P2-04 | A | 設計・PoC | 表領域対応・物理属性の扱い | 🟡 | 表領域は sql/phase2/01 で設定済み。物理属性の取込み方針は未策定（本番500表のDDL未確認） |
| P2-05 | A | 設計・PoC | DDLとデータの取込み方式 | ✅ | **根拠**: sql/phase2/03_preview_ddl.par ＋ 05_impdp_*.par。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） T11 |
| P2-06 | A | 設計・検証 | SQLFILEによるDDL事前レビュー | ✅ | **根拠**: sql/phase2/04_import_ddl_preview.sql ＋ PHASE_STATUS.APPROVAL_STATUS。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） T11-1（APPROVED を確認） |
| P2-07 | A | 設計 | オブジェクト種別ごとの取込み・除外 | ✅ | **根拠**: impdp の EXCLUDE=TRIGGER,GRANT,STATISTICS（業務トリガーは再現しない方針）。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） |
| P2-08 | A | 調査・設計 | 外部キー・親子関係・登録順序 | 🟡 | sql/phase2/08_rebuild_indexes_constraints.sql で取込み後に再構築。ただし検証は3表のみで、本番の依存関係図・制約適用順序一覧は未作成 |
| P2-09 | A | 設計・PoC | 既存テーブルの扱い・TABLE_EXISTS_ACTION | ✅ | **根拠**: sql/phase2/12_cleanup_for_retry.sql（VALIDATION_RESULT→RUN→DATAPUMP_FILE の順で初期化）。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） |
| P2-10 | B | PoC・設計 | Import並列度・処理時間 | 🔴 | Import並列度・処理時間の実測は本環境では取得不可（UNV-02） |
| P2-11 | A | PoC・設計 | BLOB／CLOB全量Import検証 | ❌ | LOB全量Import試験は未実施 |
| P2-12 | B | 調査・設計・PoC | その他特殊型のImport方式 | ❌ | 特殊型のImport方式は未検討 |
| P2-13 | A | 設計・PoC | Import監視・異常終了・再実行 | ✅ | **根拠**: sql/phase2/07_monitor_impdp.sql ＋ scripts/65_run_impdp.sh のエラー処理。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） |
| P2-14 | A | 設計・実施 | 全量移行後のデータ検証 | ✅ | **根拠**: sql/phase2/10_validate_source.sql / 11_validate_target.sql。AS OF SCN でExport時点と突合。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） T13（REGIONS 11 / CUSTOMERS 144,599 / ORDERS 182,762 が一致） |
| P2-15 | A | 設計 | フェーズ2の合格基準・承認 | ✅ | **根拠**: COMPLETE_PHASE(PHASE2) の機械判定 ＋ APPROVAL_STATUS。scripts/66_test_phase1_2_e2e.sh T01〜T16 PASS（2026-07-27 実行・実データ327,372行の移行を確認） T13-5 |
| P2-16 | B | 試算 | DB2.0必要容量の初期試算 | 🔴 | DB2.0 容量試算は本環境では取得不可（UNV-02） |

### 3.3 フェーズ3：Archived Redo Log 出力・収集

| ID | 優 | 種別 | 決めること・検証すること | 現状 | 根拠・補足 |
|---|:-:|---|---|:-:|---|
| P3-01 | A | 確認・設計・先行準備 | ARCHIVELOG設定・出力先・収集開始条件 | ✅ | ARCHIVELOG稼働確認済。scripts/67_collect_archivelogs.sh で収集・台帳登録・チェックサム検証を実装し ARCHIVE_LOG/ARCHIVE_LOG_COPY への登録を確認。保持設計は docker 共有ボリューム /migfs/archivelogs/ で代替（本番の NFS/CIFS 方式は UNV-05 として管理） ／ **根拠**: scripts/69_test_phase3_e2e.sh T02/T03 PASS（2026-07-27）、scripts/67_collect_archivelogs.sh でARCHIVE_LOG/ARCHIVE_LOG_COPY への台帳登録を実装 |
| P3-02 | A | 調査・設定・PoC・先行準備 | Supplemental Logging設定 | ✅ | **根拠**: sql/cdc/14_supplemental_logging.sql でデプロイ・設定確認（2026-07-26以前） |
| P3-03 | A | 設計・サンプル作成・先行準備 | LogMiner Dictionary生成・保管 | ✅ | **根拠**: 移行先LogMiner PoC（コミット 6aeb1ab / 2026-07-26）。CDB$ROOT で STORE_IN_REDO_LOGS を実行し V$ARCHIVED_LOG の DICTIONARY_BEGIN/END マーカーを確認 |
| P3-04 | A | 設計 | Archived Redo欠落検知・再取得 | ✅ | **根拠**: scripts/48_test_archive_gap.sh E2E PASS（コミット c24616d） |
| P3-05 | B | 設計 | ファイル破損・書込み途中・重複の防止 | ❌ | 破損・書込み途中・重複の受入判定仕様は未策定 |
| P3-06 | A | 調査 | 1日当たり・時間帯別Redo量 | 🟡 | docs/archive-measurement-findings.md に検証環境での測定あり。本番量は未（UNV-02） |
| P3-07 | A | 設計・リハーサル | 最終Archived Redoの確定 | ✅ | sql/phase3/04_finalize_archive_log_tgt.sql に SET_TARGET_END_SCN 使用の最終ログ確定手順を実装。COMPLETE_PHASE3 で MIG_CHECKPOINT.CHECKPOINT_SCN >= TARGET_END_SCN を機械確認。本番の書込み停止・全 Thread ログスイッチ手順は別途リハーサルが必要（UNV-01） ／ **根拠**: sql/phase3/04_finalize_archive_log_tgt.sql 実装。scripts/69_test_phase3_e2e.sh T08 PASS で COMPLETE_PHASE3 の最終到達確認を実証（2026-07-27） |

### 3.4 フェーズ4：Archived Redo 解析・1.0スキーマ差分反映

| ID | 優 | 種別 | 決めること・検証すること | 現状 | 根拠・補足 |
|---|:-:|---|---|:-:|---|
| P4-01 | A | PoC | DB1.0 Archived RedoをDB2.0で解析するPoC | 🟡 | PoC 実施済だが1表1UPDATE規模（UNV-06）。本格検証は未 |
| P4-02 | B | 設計 | LogMiner実行構成 | 🟡 | 実行構成はPoCで確認。権限設計は未整理 |
| P4-03 | A | 設計・実装 | 移行管理スキーマのテーブル構成 | ✅ | フェーズ4用6テーブル（LOGMINER_BATCH/LOGMINER_BATCH_LOG/MINED_TRANSACTION/MINED_CHANGE/APPLY_BATCH/APPLY_TASK）を実装。ARCHIVE_LOGにMINING_STATUS/APPLY_STATUS列を追加。PKG_MIG_ADMIN v5.0（フェーズ4 API追加）を実装。 ／ **根拠**: sql/migration_ctl/09_phase4_tables.sql + 10_pkg_mig_admin_phase4.sql。docs/phase4-design.md §3〜§5に設計仕様を記録。scripts/72_test_phase4_tables_e2e.sh T01〜T15 PASS（2026-07-27）。62/66/69 回帰テスト全PASS。 |
| P4-04 | A | 設計・PoC | LogMiner処理単位 | 🟡 | LOGMINER_BATCHは実装済み。SCN区間、工程別チェックポイント、C1/C2比較条件を設計したが、長時間Tx・性能PoCは未 ／ **根拠**: docs/phase4-design.md §10.5、docs/dirty-key-snapshot-design.md、docs/delta-performance-poc-plan.md |
| P4-05 | A | PoC・設計 | コミット済みトランザクションだけの抽出 | 🟡 | PoC では COMMITTED_DATA_ONLY 使用。旧方式は未使用（既存ギャップ G3） |
| P4-06 | A | 調査 | 最大トランザクションの調査 | ❌ | 最大トランザクション調査は未実施 |
| P4-07 | A | 設計 | 対象テーブル抽出方法 | ✅ | **根拠**: 移行先LogMiner PoC（6aeb1ab）で SEG_OWNER 抽出を確認。CON_ID フィルタが使えない知見を gap-analysis §1.2 に記録 |
| P4-08 | B | 設計 | LogMiner解析結果の保存項目 | ✅ | MINED_TRANSACTION（XID単位）・MINED_CHANGE（DML明細）のテーブル定義と索引設計を完了。MINED_CHANGEに4本の索引（TX・TBL・SCN・BST）を設計し、SQL_REDO/SQL_UNDOはCLOB型で定義（保持期間はTMP-12）。 ／ **根拠**: sql/migration_ctl/09_phase4_tables.sql（MINED_TRANSACTION/MINED_CHANGE DDL + 索引）。docs/phase4-design.md §3.3/§3.4/§3.8に設計仕様・索引設計を記録。scripts/72_test_phase4_tables_e2e.sh T03/T04 PASS（2026-07-27）。 |
| P4-09 | A | 設計・PoC | CSFによるSQL_REDO連結 | ❌ | CSF による SQL_REDO 連結は未実装 |
| P4-10 | A | PoC・設計 | ROWIDを使わず主キーで行特定 | 🟡 | MINE_VALUE/COLUMN_PRESENTで旧・新PKを列単位取得する候補設計を作成。複合PK・文字列PK・非対応型のPoCは未 ／ **根拠**: docs/dirty-key-snapshot-design.md §5、docs/delta-performance-poc-plan.md |
| P4-11 | A | 設計・検証 | トランザクション内の適用順序 | 🟡 | 旧方式は COMMIT_SCN 順で適用。新設計の適用順序仕様は未 |
| P4-12 | A | 調査・設計 | 外部キー・親子関係・DML順序 | ❌ | 外部キー考慮のDML順序は未整理 |
| P4-13 | A | 設計 | INSERT・UPDATE・DELETE反映方式 | ✅ | **根拠**: scripts/42_test_delete_e2e.sh / 31_test_integrated_e2e.sh E2E PASS |
| P4-14 | B | 設計・PoC | MERGEと直接DMLの使い分け | 🟡 | 適応型の方式判断表と比較PoC計画を作成。MERGE・直接DML・最終状態UPSERTの性能比較は未 ／ **根拠**: docs/delta-method-decision-matrix.md / docs/delta-performance-poc-plan.md |
| P4-15 | A | 設計 | 冪等性・再実行 | ✅ | **根拠**: scripts/12_test_fault_restart.sh E2E PASS（apply_ledger による冪等性） |
| P4-16 | B | 設計 | UPDATE／DELETE件数異常 | 🟡 | 件数異常は手動調査キューへ退避。異常判定仕様は未形式化 |
| P4-17 | A | 設計・PoC | BLOB差分方式 | ✅ | **根拠**: scripts/44_test_lob_resync_e2e.sh E2E PASS（コミット 5126c55） |
| P4-18 | A | 調査・設計・PoC | CLOB差分方式 | ✅ | **根拠**: 同上（scripts/44_test_lob_resync_e2e.sh、CLOB を含む） |
| P4-19 | B | 調査・設計 | その他特殊型の差分方式 | ❌ | その他特殊型の差分方式は未検討 |
| P4-20 | A | 設計 | チェックポイント設計 | ✅ | MIG_CHECKPOINTは既に実装済（06_mig_checkpoint.sql）。フェーズ4用途としてLOGMINER_READER（解析済み位置）・APPLY_WRITER（適用済みCOMMIT_SCN）の2コンポーネントを定義。不変条件（差分DML+チェックポイント同一COMMIT）を設計に明記。 ／ **根拠**: sql/migration_ctl/06_mig_checkpoint.sql（既存）。docs/phase4-design.md §7（チェックポイント設計）・§9（不変条件）。scripts/72_test_phase4_tables_e2e.sh T12/T13 PASS（2026-07-27）。 |
| P4-21 | A | 設計 | エラー管理・再処理 | ✅ | APPLY_TASKにRETRY_COUNT・ERROR_EVENT_ID・ERROR_MESSAGE列を設計。RETRY_APPLY_TASK（再試行可能）・ERROR_APPLY_TASK（再試行不可）のAPIで状態管理。再処理時は既存APPLY_TASKをRETRY状態に戻す設計（重複作成禁止）。ERROR_EVENTへの記録はERROR_EVENT_IDで関連付け。 ／ **根拠**: sql/migration_ctl/09_phase4_tables.sql（APPLY_TASK定義）+ 10_pkg_mig_admin_phase4.sql（RETRY_APPLY_TASK/ERROR_APPLY_TASK API）。docs/phase4-design.md §8（エラー・再処理設計）。scripts/72_test_phase4_tables_e2e.sh T10 PASS（2026-07-27）。 |
| P4-22 | C | 設計 | LogMiner解析結果の保持期間 | ❌ | 保持期間・削除方針は未策定（旧方式のパージ実装は別物） |
| P4-23 | A | PoC | 全体処理速度・追付き性能 | 🔴 | 計測指標と比較方式は計画済み。絶対性能・追付き性能は本番相当環境でのみ判定可能（UNV-02/10） ／ **根拠**: docs/delta-performance-poc-plan.md §6 |
| P4-24 | B | PoC・設計 | DB2.0リソース競合 | 🔴 | DB2.0 リソース競合は本環境では評価不可 |
| P4-25 | A | 設計・実施 | DB1.0とDB2.0側1.0スキーマの一致確認 | ✅ | **根拠**: scripts/53_test_two_stage_verify.sh E2E PASS（コミット 71d5f44） |
| P4-26 | A | 設計 | フェーズ4の合格基準 | 🟡 | 欠落0・最終重複0・同一SCN断面・再実行一致・未完了チェックポイント禁止を方式PoCの共通基準として形式化。Phase4全体承認条件は未完 ／ **根拠**: docs/dirty-key-snapshot-design.md §8、docs/delta-performance-poc-plan.md §5/§9 |

### 3.5 フェーズ5：1.0スキーマ→2.0スキーマ 変換投入

| ID | 優 | 種別 | 決めること・検証すること | 現状 | 根拠・補足 |
|---|:-:|---|---|:-:|---|
| P5-01 | B | 設計確認 | 変換処理の実行・再処理単位 | ✅ | **根拠**: scripts/20_test_phase2_transform.sh E2E PASS（transform_catalog による変換単位管理） |
| P5-02 | B | 設計 | 旧キーと新キーの対応管理 | 🟡 | code_mapping はステータス変換のみ。汎用 KEY_MAPPING は未 |
| P5-03 | B | 設計・検証 | 変換処理の決定性・再現性 | ✅ | **根拠**: scripts/21_test_phase2_mechanism.sh E2E PASS（冪等な再変換） |
| P5-04 | B | 調査・設計・検証 | 特殊型の2.0変換方式 | 🟡 | LOBパススルーは実装済（54_test）。その他特殊型は未 |
| P5-05 | A | 設計 | チェックポイント・エラー・再処理 | 🟡 | transform_state による再開点管理あり。エラー・再処理仕様は部分的 |
| P5-06 | A | 設計・実施 | 1.0スキーマと2.0スキーマの整合確認 | ✅ | **根拠**: scripts/53_test_two_stage_verify.sh / 54_test_lob_passthrough_e2e.sh E2E PASS |
| P5-07 | A | 設計 | フェーズ5の合格基準 | ❌ | フェーズ5の合格基準は未形式化 |
| P5-08 | A | 設計 | 最終切替工程 | ❌ | 最終切替タイムチャートは未作成 |
| P5-09 | A | 検証 | 事前リハーサル | ❌ | 事前リハーサルは未実施 |
| P5-10 | A | 設計 | ロールバック方針 | ❌ | ロールバック方針・判断基準は未策定 |

---

## 4. 成果物 一覧（延べ 163 件）

各決定・検証事項が要求する成果物です。**同名・類似のものは実務上まとめられる**ため、
実際に作るファイル数はこれより少なくなります（母数の把握用）。


### 4.1 フェーズ1：初回全量 Data Pump Export（45件）

| 出典ID | 現状 | 成果物 |
|---|:-:|---|
| P1-01 | 🟡 | 移行元接続定義 ／ 実行環境情報 |
| P1-02 | 🟡 | 移行対象テーブル一覧 ／ 対象外一覧 ／ 1.0スキーマ作成対象一覧 ／ 主キー・更新日時・DML・LOB・パーティション棚卸し ／ テーブル別差分方式分類カタログ |
| P1-03 | ❌ | 特殊データ型一覧 ／ 対象件数・容量一覧 ／ Export可否一覧 |
| P1-04 | ✅ | SCN境界設計 ／ 基準SCN・解析開始SCN取得手順 ／ 最小管理テーブル定義 ／ SCN登録SQL |
| P1-05 | ✅ | Export対象・内容方針 ／ Exportパラメータ定義 |
| P1-06 | 🟡 | Data Pumpジョブ分割一覧 ／ 対象テーブル・ジョブ対応表 ／ 実行順序表 |
| P1-07 | 🟡 | UNDO容量試算 ／ ORA-01555試験結果 ／ 対策方針 |
| P1-08 | ✅ | ファイル配置設計 ／ DIRECTORY作成SQL ／ 権限設定手順 |
| P1-09 | ❌ | ファイル命名規則 ／ ファイル分割方針 ／ 保管・削除方針 |
| P1-10 | 🔴 | ダンプ容量実測結果 ／ Migrationファイルサーバ容量試算 |
| P1-11 | 🔴 | 推奨並列度 ／ 性能測定結果 ／ 業務影響評価 |
| P1-12 | 🟡 | 圧縮・暗号化方針 ／ ファイル完全性確認手順 |
| P1-13 | ✅ | 権限一覧 ／ ユーザー作成・権限付与SQL ／ 認証運用手順 |
| P1-14 | ✅ | Export監視手順 ／ 異常終了時の復旧手順 ／ 再実行判断表 |
| P1-15 | ✅ | Export完了チェックリスト ／ 実行結果記録 |
| P1-16 | 🟡 | LOB全量Export試験結果 ／ LOBジョブ分割方針 |

### 4.2 フェーズ2：初回全量 Data Pump Import（35件）

| 出典ID | 現状 | 成果物 |
|---|:-:|---|
| P2-01 | 🟡 | 投入先接続定義 ／ Import実行環境情報 |
| P2-02 | ✅ | 1.0スキーマ構築手順 ／ ユーザー・権限設定SQL |
| P2-03 | ✅ | スキーマ対応表 ／ Importパラメータ |
| P2-04 | 🟡 | 表領域対応表 ／ 物理属性取込み方針 |
| P2-05 | ✅ | Import方式設計 ／ DDL適用方針 |
| P2-06 | ✅ | DDLプレビューSQL ／ DDLレビュー結果 ／ 修正・除外一覧 |
| P2-07 | ✅ | オブジェクト種別別取込み・除外一覧 ／ INCLUDE／EXCLUDE設計 |
| P2-08 | 🟡 | テーブル依存関係図 ／ 制約適用順序一覧 |
| P2-09 | ✅ | 既存テーブル処理方針 ／ 再Import初期化手順 |
| P2-10 | 🔴 | 推奨Import並列度 ／ 性能測定結果 |
| P2-11 | ❌ | LOB全量Import試験結果 ／ LOB検証SQL |
| P2-12 | ❌ | 特殊型別Import方針 ／ 試験結果 |
| P2-13 | ✅ | Import監視手順 ／ エラー復旧手順 ／ 再実行手順 ／ 初期化SQL |
| P2-14 | ✅ | 全量移行検証仕様書 ／ 検証SQL ／ 検証結果 |
| P2-15 | ✅ | フェーズ2完了判定基準 ／ 承認記録 |
| P2-16 | 🔴 | DB2.0容量計画 |

### 4.3 フェーズ3：Archived Redo Log 出力・収集（16件）

| 出典ID | 現状 | 成果物 |
|---|:-:|---|
| P3-01 | ✅ | Archived Redo出力設定確認結果 ／ 収集開始記録 ／ 保持・再取得設計 |
| P3-02 | ✅ | 現行設定確認結果 ／ 設定変更手順 ／ 検証結果 |
| P3-03 | ✅ | Dictionary生成・読込み手順 ／ サンプルSQL ／ 対象ログ一覧 |
| P3-04 | ✅ | 欠落検知仕様 ／ 復旧手順 |
| P3-05 | ❌ | Archived Redo受入判定仕様 |
| P3-06 | 🟡 | 日次・時間帯別Redo量 ／ ファイルサーバ容量見積り |
| P3-07 | ✅ | 最終ログ確定手順 ／ 最終到達確認方法 |

### 4.4 フェーズ4：Archived Redo 解析・1.0スキーマ差分反映（52件）

| 出典ID | 現状 | 成果物 |
|---|:-:|---|
| P4-01 | 🟡 | PoC結果報告 ／ 実行SQL ／ 制約・課題一覧 |
| P4-02 | 🟡 | LogMiner実行構成図 ／ 権限設計 |
| P4-03 | ✅ | 管理スキーマDDL ／ ER図 ／ 状態遷移表 ／ 管理API ／ フェーズ別登録・更新SQL |
| P4-04 | 🟡 | LogMinerバッチ分割設計 ／ 移行先／移行元LogMiner構成比較 ／ 性能測定結果 |
| P4-05 | 🟡 | オプション採用結果 ／ 制約事項 |
| P4-06 | ❌ | 最大トランザクション調査結果 |
| P4-07 | ✅ | 対象抽出SQL ／ 対象テーブル管理仕様 |
| P4-08 | ✅ | 解析結果テーブル定義 ／ 索引設計 |
| P4-09 | ❌ | SQL_REDO連結ロジック ／ テスト結果 |
| P4-10 | 🟡 | 行特定方式 ／ PoC結果 |
| P4-11 | 🟡 | 適用順序仕様 ／ テストケース |
| P4-12 | ❌ | 登録・更新・削除順序一覧 |
| P4-13 | ✅ | DML適用共通仕様 |
| P4-14 | 🟡 | DML使い分け基準 ／ テーブル別差分方式選択基準 ／ 性能比較結果 |
| P4-15 | ✅ | 再実行制御仕様 |
| P4-16 | 🟡 | 異常判定・エラー処理仕様 |
| P4-17 | ✅ | BLOB差分移行設計 ／ LOB再取得手順 ／ 整合性方針 ／ PoC結果 |
| P4-18 | ✅ | CLOB差分対応方針 ／ PoC結果 |
| P4-19 | ❌ | 特殊型別差分反映方針 |
| P4-20 | ✅ | チェックポイントテーブル・更新仕様 |
| P4-21 | ✅ | エラー管理仕様 ／ 再処理手順 |
| P4-22 | ❌ | データ保持・削除方針 |
| P4-23 | 🔴 | 処理能力比較 ／ 追付き可否判定 |
| P4-24 | 🔴 | 同時実行方針 ／ 推奨並列度 |
| P4-25 | ✅ | 比較SQL ／ 検証結果 |
| P4-26 | 🟡 | フェーズ4完了判定基準 ／ 方式別正確性合格基準 |

### 4.5 フェーズ5：1.0スキーマ→2.0スキーマ 変換投入（15件）

| 出典ID | 現状 | 成果物 |
|---|:-:|---|
| P5-01 | ✅ | 変換処理単位一覧 |
| P5-02 | 🟡 | キーマッピングテーブル設計 |
| P5-03 | ✅ | 再現性確認結果 |
| P5-04 | 🟡 | 特殊型別2.0変換方針 |
| P5-05 | 🟡 | 2.0変換チェックポイント仕様 ／ 再処理手順 |
| P5-06 | ✅ | 変換検証仕様 ／ 検証結果 |
| P5-07 | ❌ | フェーズ5完了・移行判定基準 |
| P5-08 | ❌ | 最終切替タイムチャート |
| P5-09 | ❌ | リハーサル結果 ／ 所要時間 ／ 改善事項 |
| P5-10 | ❌ | ロールバック手順 ／ 判断基準 |

---

## 5. 成果物の性質別まとめ

作るものの「種類」で見ると、大きく4つに分かれます。着手順を考える際の目安にしてください。

| 性質 | 例 | この環境で作れるか |
|---|---|---|
| **① 一覧・台帳** | 移行対象テーブル一覧、特殊データ型一覧、ジョブ分割一覧、テーブル依存関係図 | 🟡 形式は作れるが、**中身は本番の実データを見ないと埋まらない** |
| **② 設計文書・仕様** | SCN境界設計、DML適用共通仕様、チェックポイント仕様、エラー管理仕様 | ✅ 作れる。この環境の主戦場 |
| **③ SQL・スクリプト** | DIRECTORY作成SQL、権限付与SQL、検証SQL、監視手順、初期化SQL | ✅ 作れる。動作確認まで可能 |
| **④ 試験結果・実測値** | 容量実測、性能測定、並列度、追付き可否、UNDO試算、リハーサル結果 | 🔴 **作れない。** 規模・構成が違うため数値に意味がない |

> **④は本番相当環境が必要**です。この環境で出した数値を本番設計に使わないでください。
> ①は「様式（フォーマット）」だけ先に作っておき、本番データで埋める運用が現実的です。

---

## 6. 運用ルール

- **`docs/progress.yml` が唯一の正**。このMarkdownは自動生成物なので直接編集しない
- 進捗を変えるときは `progress.yml` の `status` / `evidence` / `note` を更新し、
  `bash scripts/70_progress_report.sh` を実行してからコミットする
- **`status: done` にするには `evidence` が必須**（空だとスクリプトがエラーで止まる）。
  「どのスクリプトで・いつ確認したか」を書くこと
- 🟡の項目は [`handoff-guide.md`](handoff-guide.md) §4 の仮決定台帳と対応する。社内で決め直す対象
- 🔴の項目は本番相当環境での実施計画に載せる
- 設計メモ §9.1「直ちに合意する事項」17項目、§14「直近の判断ポイント」5項目もこの一覧に含まれている。
  個別管理せず、この表を正とする

---

## 7. 関連文書

- [`handoff-guide.md`](handoff-guide.md) — 信頼度の区別・仮決定台帳・本番未検証台帳
- [`phase1-2-deliverables-and-flow.md`](phase1-2-deliverables-and-flow.md) — フェーズ1・2の実行資材とプロセスフロー
- [`gap-analysis-5phase-schema.md`](gap-analysis-5phase-schema.md) — 新設計と現行実装のギャップ
- [`migration-control-schema-design.md`](migration-control-schema-design.md) — 移行管理スキーマ設計書
