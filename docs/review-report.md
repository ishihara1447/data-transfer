# レビューレポート

レビュー実施日: 2026-05-23
対象ブランチ: main
レビュー担当: quality-reviewer
対象ファイル: sql/00〜05, scripts/run-migration.ps1, docker-compose.yml, .env.example

---

## 総合評価

**要修正（軽微）**

HIGH 指摘事項はなし。Oracle 12c 非互換構文・SQL*Plus 非互換構文は一切使用されていない。PL/SQL 役割分離・AUTONOMOUS TRANSACTION・冪等性・ROLLBACK 順序・例外処理はすべて正しく実装されている。MEDIUM 1 件（run log の counts が障害時に 0 になる）と LOW 5 件を修正することで、本番適用に向けた品質がさらに高まる。

指摘件数: HIGH 0 / MEDIUM 1 / LOW 5

---

## 重大度別指摘事項

### HIGH（必須修正）

なし。

---

### MEDIUM（推奨修正）

**M-1 [sql/04_create_pkg_migration.sql:406] migrate_all EXCEPTION ブロックが total_tgt_count を常に 0 で記録する**

- 指摘内容: `migrate_all` の EXCEPTION ブロック（行 406）は `log_run_end(v_run_id, 'FAILED', 0, 0, v_error_msg)` とハードコードされた 0, 0 を渡している。`migrate_customer` が全バッチ正常完了した後に `migrate_order` が失敗した場合、顧客データはすべてコミット済みであるにもかかわらず、`migration_run_log.total_src_count` と `total_tgt_count` がいずれも 0 で記録される。障害調査時に「何件まで確定したか」を run_log だけでは判断できなくなる。なお step_log 側の `tgt_count`・`batch_no` は各バッチ COMMIT 後に更新されているため、step_log を参照すれば確定件数は追える。
- 修正方針: EXCEPTION ブロック内で `SELECT COUNT(*) FROM tgt_schema.customers/orders` を取得するか、`migrate_customer`・`migrate_order` 内で OUT パラメータとして確定済み件数を返すよう変更する。あるいは、EXCEPTION ブロック冒頭で `SELECT total_src_count, total_tgt_count INTO ... FROM migration_step_log WHERE run_id = v_run_id` で step_log の最新値を集計してから `log_run_end` に渡す方法も有効。

---

### LOW（参考）

**L-1 [sql/04_create_pkg_migration.sql:396] migrate_all 正常終了パスに冗長な COMMIT がある**

- 指摘内容: `log_run_end(v_run_id, 'SUCCESS', ...)` 呼び出し直後の行 396 に `COMMIT` がある。しかし `log_run_end` は `PRAGMA AUTONOMOUS_TRANSACTION` を持ち内部で独立してコミットする。データはすべてバッチ単位でコミット済みであるため、メイン・トランザクションには未コミットのデータが存在しない。この `COMMIT` は実害なく実行されるが、AUTONOMOUS_TRANSACTION の動作と混同している可能性を示す。
- 修正方針: 行 396 の `COMMIT` を削除するか、「すべてのデータは既にバッチ COMMIT 済みのため本 COMMIT はセッション保護のみ」とコメントを追加して意図を明示する。

**L-2 [sql/04_create_pkg_migration.sql:262] SUBSTR(address, 1, 4) が5文字の都道府県名を切り捨てる**

- 指摘内容: `prefecture` 列への格納に `SUBSTR(v_rows(i).address, 1, 4)` を使用している。「神奈川県」「和歌山県」「鹿児島県」は5文字であるため「神奈川」「和歌山」「鹿児島」と都道府県識別子の「県」が欠落する。`city` は `NULL` 固定で、`address_detail` には元の `address` 全体が格納される。設計書の注記（migration-design.md 94 行目）に「先頭4文字のみの簡略版」と明記されているため、サンプルスコープとして許容されているが、本番適用前には正規表現等による都道府県抽出ロジックへの強化が必要。
- 修正方針: `REGEXP_SUBSTR(address, '^.{2,4}[都道府県]')` 等のパターンマッチで正確な都道府県文字列を抽出することを推奨。本番適用前の対応とする。

**L-3 [sql/04_create_pkg_migration.sql:169] log_step UPDATE 時に finished_at を RUNNING 状態で NULL にセットし直している**

- 指摘内容: `log_step` の UPDATE 分岐（行 169-179）で、`finished_at` を `CASE WHEN p_status IN ('SUCCESS','FAILED','SKIPPED') THEN SYSDATE ELSE NULL END` に更新している。バッチ進捗更新（`status = 'RUNNING'`）の場合、`finished_at = NULL` への更新が毎バッチ発生する。初回 INSERT では `finished_at` 列が `NULL`（DDL 上 NULL 許容）なのでもともと NULL であり、NULL で上書きされても実害はない。ただし意図が読みづらい。
- 修正方針: `RUNNING` のバッチ進捗更新時に `finished_at` を明示的に更新しないよう、`finished_at` を SET 句から条件分岐で除外するか、`WHEN p_status = 'RUNNING' THEN finished_at` のように現在値を保持する式にする（ただし UPDATE のパフォーマンスへの影響はない）。

**L-4 [docs/migration-design.md:135] 設計書のバッチコミット処理フローが FORALL と記載されているが実装は FOR ループ**

- 指摘内容: 設計書（migration-design.md 行 135）の「処理パターン」に `FORALL i IN コレクション.FIRST..コレクション.LAST INSERT INTO ...` と記述されているが、実装（04_create_pkg_migration.sql 行 253-267、行 325-341）では通常の `FOR i IN 1..v_rows.COUNT LOOP ... INSERT ... END LOOP` を使用している。実装での FOR ループは `safe_to_date_yyyymmdd` 呼び出しを行単位で実行するために必要であり、機能的には正しい（FORALL は DML のみのバルク実行であり、ループ内での関数呼び出しと組み合わせる場合は事前にコレクションを変換する必要がある）。タスク仕様書も "BULK COLLECT + FOR LOOP" と明記しており、実装の選択は正当。
- 修正方針: 設計書の「処理パターン」セクションを FOR LOOP 方式に更新し、FORALL を使用しない理由（`safe_to_date_yyyymmdd` 呼び出しが必要なため）をコメントとして追記する。

**L-5 [docker-compose.yml:14-19] ヘルスチェックが TCP 疎通のみでありリスナー・PDB の起動完了を保証しない**

- 指摘内容: ヘルスチェックは `/dev/tcp/localhost/1521` への TCP 接続確認のみである。TCP ポートが開いていても Oracle リスナーの起動や XEPDB1 PDB のオープン完了を保証しない。`start_period: 5m` と `retries: 10`（合計最長 10 分）で十分なマージンが設けられているが、ヘルスチェックが `healthy` になった直後に PowerShell スクリプトが実行された場合、PDB がまだ OPEN になっていない可能性がある。この場合 `ORA-12514: TNS:listener does not currently know of service requested` が発生するが、`WHENEVER SQLERROR EXIT SQL.SQLCODE` により非ゼロ終了コードが返り、PowerShell 側でエラーとして検出される。機能上の致命的問題はなく再実行で解決するが、初回実行時の接続失敗の原因として把握しておく必要がある。
- 修正方針: ヘルスチェックコマンドを `sqlplus -s sys/"$ORACLE_PASSWORD"@//localhost:1521/XEPDB1 AS SYSDBA <<< 'exit'` 形式に変更して PDB への実接続確認にするか、Oracle 21c XE コンテナ同梱の `/opt/oracle/checkDBStatus.sh` を使用する。ただしコマンドライン引数にパスワードが露出する点はコメントで注記すること。

---

## 観点別評価

| 観点 | 評価 | 備考 |
|------|------|------|
| WHENEVER OSERROR EXIT FAILURE（全6ファイル） | OK | 00〜05 すべてで確認済み |
| WHENEVER SQLERROR EXIT SQL.SQLCODE（全6ファイル） | OK | 00〜05 すべてで確認済み |
| migration_step_log.batch_no DDL | OK | `NUMBER DEFAULT 0` で定義済み（03: 60行目） |
| migration_error_log 新カラム DDL | OK | `target_table VARCHAR2(100)`・`batch_no NUMBER`・`error_context VARCHAR2(4000)` 定義済み（03: 92-94行目） |
| safe_to_date_yyyymmdd REGEXP_LIKE パターン | OK | `'^[0-9]{8}$'` でアンカー付き正規表現を使用（04: 76行目） |
| BULK COLLECT + FOR LOOP | OK | `FETCH c_src BULK COLLECT INTO v_rows LIMIT p_batch_size` + `FOR i IN 1..v_rows.COUNT LOOP` で実装（04: 249, 253行目） |
| log_step シグネチャ（SPEC と BODY の一致） | OK | 6パラメータ（p_run_id, p_step_name, p_status, p_src_count, p_tgt_count, p_batch_no）、SPEC と BODY で完全一致 |
| log_error シグネチャ（SPEC と BODY の一致） | OK | 9パラメータ（p_run_id, p_step_name, p_error_code, p_error_msg, p_backtrace, p_record_id, p_target_table, p_batch_no, p_error_context）、SPEC と BODY で完全一致 |
| FK 削除順序（migrate_customer） | OK | `DELETE FROM tgt_schema.orders` → `DELETE FROM tgt_schema.customers` の順（04: 243-244行目） |
| migrate_order が tgt_schema.customers を削除しないこと | OK | `DELETE FROM tgt_schema.orders` のみ実行（04: 316行目） |
| ROLLBACK 順序（migrate_all EXCEPTION） | OK | `ROLLBACK`（行403）→ `log_error`（行405）→ `log_run_end`（行406）の順で、AUTONOMOUS TRANSACTION なログ呼び出しが ROLLBACK 後に実行される |
| PowerShell BatchSize パラメータ | OK | `[int]$BatchSize = 10000`（ps1: 8行目）、`EXECUTE ... migrate_all('$RunName', $BatchSize)`（ps1: 90行目） |
| Oracle 12c 互換性 | OK | IDENTITY 列・FETCH FIRST・JSON 関数・LISTAGG ON OVERFLOW・MATCH_RECOGNIZE 等すべて不使用。SEQUENCE + TRIGGER で採番。VARCHAR2 最大 4000 バイト以内。REGEXP_LIKE は 10g 以降対応で問題なし |
| SQL*Plus 互換性 | OK | SET LINESIZE AUTO・SPOOL CSV・SCRIPT・LOAD 等の SQLcl 専用コマンドは不使用。SHOW ERRORS・SET ECHO・SET FEEDBACK・SET SERVEROUTPUT はすべて SQL*Plus 互換 |
| PL/SQL 移行ロジック配置 | OK | DELETE/INSERT/COMMIT/ROLLBACK・件数カウント・例外処理・DB ログ登録はすべて PL/SQL パッケージ内に実装されている |
| PowerShell 役割限定 | OK | コンテナ確認・SQL*Plus 呼び出し・外部ログ保存・終了コード判定のみ。移行ロジックなし |
| ログ設計（エラー原因追跡） | OK | SQLCODE・SQLERRM・BACKTRACE・target_table・batch_no・error_context をすべて記録。step_log の batch_no・tgt_count でバッチ単位の進捗確認が可能 |
| 再実行方針 | 明記あり | DELETE + INSERT の冪等設計、log_run_start での二重起動防止（RAISE_APPLICATION_ERROR -20001）が実装済み |
| DBログへの十分な情報記録 | OK | 3テーブル構成（run_log・step_log・error_log）で実行単位・ステップ単位・エラー詳細を分離して記録 |
| EXCEPTION ブロックの適切な実装 | OK | WHEN OTHERS + RAISE を全プロシージャに実装。CURSOR %ISOPEN ガード実装済み（04: 279, 354行目）。SQLCODE/SQLERRM は ROLLBACK 前に取得済み |
| .env.example の適切さ | OK（軽微な懸念あり） | パスワードの説明コメントあり。サンプル値は弱いが、ローカル検証専用環境であることが明記されている（L-4 参照） |
| docker-compose.yml の設定 | OK（軽微な懸念あり） | パスワード露出なし。TCP ヘルスチェックは PDB 起動完了を保証しない（L-5 参照） |

---

## 修正優先度サマリ

| No. | 重大度 | 対象ファイル | 概要 | 本番影響 | 対応状況 |
|----|--------|------------|------|---------|---------|
| M-1 | MEDIUM | 04_create_pkg_migration.sql | FAILED 時の run_log total_tgt_count が常に 0 | 障害後の件数把握が困難 | **修正済み**（EXCEPTION ブロックで実件数を取得） |
| L-1 | LOW | 04_create_pkg_migration.sql | 正常終了後の冗長な COMMIT | 実害なし、コード意図の明確化のみ | **修正済み**（COMMIT 削除） |
| L-2 | LOW | 04_create_pkg_migration.sql | prefecture 抽出で5文字県名が切り捨て | サンプルスコープでは許容、本番前に要対応 | **修正済み**（REGEXP_SUBSTR に変更） |
| L-3 | LOW | 04_create_pkg_migration.sql | バッチ進捗更新で finished_at を NULL 上書き | 実害なし、可読性のみ | **修正済み**（ELSE finished_at で現在値保持） |
| L-4 | LOW | docs/migration-design.md | 設計書の FORALL 記述と実装（FOR LOOP）の不整合 | ドキュメント修正のみ | **修正済み**（FOR LOOP + 理由を追記） |
| L-5 | LOW | docker-compose.yml | TCP のみのヘルスチェックで PDB 起動完了を保証しない | 初回実行時に接続失敗の可能性、再実行で解決 | **修正済み**（checkDBStatus.sh に変更） |

---

## レビュー: migration_ctl スキーマ実装（2026-07-26）

### 対象コミット
`7633eeb` 統合移行管理スキーマ(migration_ctl)を実装: MIGRATION_RUN/PHASE_STATUS/MIGRATION_OBJECT, E2E全PASS

### 結果サマリ
**CONDITIONAL_PASS**

HIGH 指摘事項なし。Oracle 12c 互換性・設計の完全性・既存テーブルへの無干渉はすべて OK。MEDIUM 3件（.env.example への変数不足・E2E スクリプトの DDL インライン化・過剰権限付与）を修正することで PASS となる。LOW 2件は参考扱い。

指摘件数: HIGH 0 / MEDIUM 3 / LOW 2

---

### 指摘事項

| # | 種別 | ファイル | 内容 | 対処方針 |
|---|------|----------|------|---------|
| M-1 | MEDIUM | `.env.example` | `MIGRATION_CTL_PASS` が未定義。`62_test_migration_ctl_e2e.sh` は `set -u` を有効にして `.env` を source するため、この変数が未設定だと「unbound variable」で即死する。新規開発者は `.env.example` を参照してセットアップするため、コピーした時点でスクリプトが動かない状態になる。 | `.env.example` に `MIGRATION_CTL_PASS=migctlpass1` の行を追加する。コメントとして「統合移行管理スキーマ（migration_ctl）のパスワード」を付記する。 |
| M-2 | MEDIUM | `scripts/62_test_migration_ctl_e2e.sh` (lines 78–207) | コメント「02_migration_ctl_ddl.sql を実行します」と実際の動作（DDL をヒアドキュメントにインライン展開）が乖離している。`02_migration_ctl_ddl.sql` に列追加・制約変更が入った場合、E2E スクリプトは古い DDL でテストを継続するため変更が検証されない。メンテナンスコストが 2 倍になる。 | `docker exec oracle-tgt bash -c "..."` 内で `sqlplus ... @/path/to/sql` を呼び出す方式に変更し、DDL は SQL ファイル 1 か所に一元化する。あるいはヒアドキュメント冒頭に「NOTE: 02_migration_ctl_ddl.sql と同期を保つこと」と明示する（後者は応急処置）。 |
| M-3 | MEDIUM | `sql/migration_ctl/01_migration_ctl_user.sql` (line 19) | `GRANT SELECT ANY TABLE TO migration_ctl` は DB 全体への読み取り権限であり最小権限原則に違反する。migration_ctl が参照するのは `cdc_schema.cdc_table_catalog` と `log_schema.migration_run_log` 等に限定される。本番 12c 環境では DBA が `SELECT ANY TABLE` 付与を拒否するケースも多い。 | `GRANT SELECT ON cdc_schema.cdc_table_catalog TO migration_ctl;` 等、参照対象テーブルへの個別 GRANT に絞る。対象が確定していない段階であれば、コメントで「将来は個別 GRANT に置き換える」と明記する。 |
| L-1 | LOW | `scripts/62_test_migration_ctl_e2e.sh` (lines 23–33) | `tgt_sysdba()` は `docker exec -u oracle oracle-tgt` と `-u oracle` を指定しているが、`mctl_sql()` は `docker exec oracle-tgt`（`-u` 省略）。XE コンテナのデフォルト実行ユーザーが oracle であれば実害はないが、コンテナ設定によっては root として実行される可能性がある。 | `mctl_sql()` にも `-u oracle` を追加し、接続方式を統一する。 |
| L-2 | LOW | `docs/migration-control-schema-design.md` (末尾付録) | ノウハウ記録の表が「エラーなし（スムーズに完了）」1行のみで、実装で踏襲したパターン（SEQUENCE+TRG、`docker exec -u oracle`、`WHENEVER SQLERROR EXIT SQL.SQLCODE`、スキーマ未修飾 DDL 等）が記載されていない。設計フォーマットは満たすが将来の参照価値が低い。 | 「既存スクリプトから踏襲したパターン」として、SEQUENCE + BEFORE INSERT トリガー方式の採用根拠・SQL*Plus 互換ヘッダの定型・`docker exec -u oracle` の使用箇所等を表の「効いた対処」列に具体的に記載する。 |

---

### 確認済み事項（問題なし）

**Oracle 12c 互換性**
- IDENTITY 列は使用されていない。3テーブルすべて SEQUENCE + BEFORE INSERT トリガー方式で採番（`oracle-compatibility-policy.md` 準拠）。
- JSON 関数（JSON_TABLE / JSON_OBJECT 等）、FETCH FIRST / OFFSET、WITH FUNCTION、ACCESSIBLE BY、LISTAGG ON OVERFLOW TRUNCATE はいずれも使用されていない。
- 全識別子（制約名・シーケンス名・トリガー名）が Oracle 12.1 の 30 文字上限以内であることを確認。最長は `TRG_MIGRATION_OBJECT_BI`（23文字）。
- VARCHAR2 はすべて 4000 バイト以内（REMARKS / ERROR_MESSAGE が上限値 4000 で定義。`MAX_STRING_SIZE=EXTENDED` 前提なし）。
- SQL*Plus 互換性：`WHENEVER SQLERROR EXIT SQL.SQLCODE` / `WHENEVER OSERROR EXIT FAILURE` / `SET ECHO ON` / `SET FEEDBACK ON` / `/` デリミタ / `EXIT;` の定型が全ファイルに正しく実装されている。SQLcl 専用コマンド（`SET LINESIZE AUTO` 等）は使用なし。

**設計の完全性（migration-control-schema-design.md §3 との照合）**
- `BASELINE_SCN` と `MINING_START_SCN` が別カラムとして `MIGRATION_RUN` テーブルに存在する。
- `CHK_MIG_RUN_SCN` 制約（`MINING_START_SCN IS NULL OR BASELINE_SCN IS NULL OR MINING_START_SCN <= BASELINE_SCN`）が実装されている。NULL 許容ロジックも設計通り。
- `PHASE_STATUS.CHK_PHASE_STATUS_CODE` に 7 フェーズ分（PREP_A, PREP_B, PHASE1〜PHASE5）の CHECK 制約が実装されている。
- `MIGRATION_OBJECT.CDC_CATALOG_TABLE_NAME` は FK 制約なし（ソフト参照）で実装されている。

**既存テーブルへの無干渉**
- `cdc_schema` / `staging_ctl` / `log_schema` の既存テーブルに対する DDL 変更（ALTER TABLE 等）は一切ない。
- クロススキーマ FK 制約は設けられていない。migration_ctl スキーマ内の FK（MIGRATION_RUN → PHASE_STATUS, MIGRATION_RUN → MIGRATION_OBJECT）のみ。

**E2E テストスクリプトの制約検証**
- T01: UNIQUE 制約（ORA-00001）・CHECK 制約（ORA-02290）を正しく検証している。
- T02: FK 制約（ORA-02291）・UNIQUE 制約（ORA-00001）・状態遷移（NOT_STARTED → RUNNING → DONE）を正しく検証している。
- T03: UNIQUE 制約（ORA-00001）を正しく検証している。
- T04: `CHK_MIG_RUN_SCN` の正常ケース（500 <= 1000）と違反ケース（2000 > 1000 → ORA-02290）を正しく検証している。
- T05: `cdc_schema.cdc_table_catalog` の有無を動的に判定し、LEFT JOIN の動作を適切に検証している。
- クリーンアップ処理（DELETE 3テーブル + COMMIT）が最後に実行されている。`LIKE 'TEST-RUN-%'` による絞り込みで対象を限定している。
- PASS/FAIL 判定変数（`PASS=1/0`）が正確に機能し、最終的な終了コード（`exit 1`）に連動している。

