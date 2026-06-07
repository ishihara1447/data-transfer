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
