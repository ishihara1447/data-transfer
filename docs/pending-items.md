# 未完了・不足事項一覧

棚卸し実施日: 2026-05-23  
対象: 全実装ファイル（sql/ scripts/ docs/）  
判定基準: ファイル内容を直接確認して判定（推測なし）

---

## 判定サマリ

| 区分 | HIGH | MEDIUM | LOW | 備考 |
|------|------|--------|-----|------|
| docs | 2 | 0 | 0 | バッチ設計・ログ列定義が未記載 |
| SQL DDL | 3 | 0 | 1 | OSERROR未対応・batch_no列なし |
| PL/SQL | 4 | 0 | 1 | バッチ処理・REGEXP_LIKE未実装 |
| PowerShell | 1 | 1 | 0 | BatchSize引数・経過秒数なし |
| Review | 0 | 1 | 0 | review-report が現状未反映 |

---

## 詳細一覧

| # | 区分 | 状態 | 内容 | 対応必要性 |
|---|------|------|------|-----------|
| 1 | docs | **未完了** | migration-design.md: 約1万件バッチコミット方針の記載なし | HIGH |
| 2 | docs | **未完了** | logging-and-error-handling.md: step_log の batch_no カラム、error_log の target_table/batch_no/error_context カラムの定義なし | HIGH |
| 3 | SQL DDL | **未完了** | 00〜05 全ファイル: `WHENEVER OSERROR EXIT FAILURE` が未追加（OSエラーで非ゼロ終了しない） | HIGH |
| 4 | SQL DDL | **未完了** | 03_create_log_tables.sql: migration_step_log に batch_no 列なし | HIGH |
| 5 | SQL DDL | **未完了** | 03_create_log_tables.sql: migration_error_log に target_table/batch_no/error_context 列なし | HIGH |
| 6 | SQL DDL | 完了 | `WHENEVER SQLERROR EXIT SQL.SQLCODE` は全ファイルに存在（EXIT SQL.SQLCODE は EXIT FAILURE より詳細で適切） | — |
| 7 | PL/SQL | **未完了** | migrate_all / migrate_customer / migrate_order: p_batch_size パラメータなし（全件一括INSERT） | HIGH |
| 8 | PL/SQL | **未完了** | migrate_customer / migrate_order: BULK COLLECT + FORALL によるバッチ処理なし。1万件を超えるデータでUNDO/REDOリスクあり | HIGH |
| 9 | PL/SQL | **未完了** | migrate_customer / migrate_order: REGEXP_LIKE による日付8桁検証なし（LENGTH=8 チェックのみ。非数字・無効月日を防げない） | HIGH |
| 10 | PL/SQL | **未完了** | log_step / log_error: batch_no / target_table / error_context パラメータなし。エラー発生バッチを特定できない | HIGH |
| 11 | PL/SQL | 完了 | FK順序: migrate_customer内でorders→customersの順DELETE済み | — |
| 12 | PL/SQL | 完了 | WHEN OTHERS後のRAISE: 全EXCEPTIONブロックで実装済み | — |
| 13 | PL/SQL | 完了 | AUTONOMOUS TRANSACTION: log_*/log_run_* 全4プロシージャで実装済み | — |
| 14 | PL/SQL | 完了 | SQLCODE/SQLERRM/BACKTRACE: 全EXCEPTIONブロックで記録済み | — |
| 15 | PL/SQL | 完了 | v_run_id IS NULL チェック: log_run_start失敗時の二重エラー防止済み | — |
| 16 | PL/SQL | 参考 | FORALL SAVE EXCEPTIONS: 行単位エラーの継続処理。今回スコープ外（バッチ失敗＝全体失敗方針） | LOW |
| 17 | PowerShell | **未完了** | -BatchSize パラメータなし。migrate_all に batch_size を渡せない | HIGH |
| 18 | PowerShell | **未完了** | 経過秒数の計算・ログ出力なし | MEDIUM |
| 19 | PowerShell | 完了 | 開始/終了時刻: Write-Logのタイムスタンプで記録済み | — |
| 20 | PowerShell | 完了 | SQL*Plus終了コード判定: $LASTEXITCODE で実装済み | — |
| 21 | PowerShell | 完了 | RunNameバリデーション: 英数字/_/- のみ許可 | — |
| 22 | PowerShell | 完了 | パスワード非出力: $ConnStr はログ出力していない | — |
| 23 | Review | 未完了 | docs/review-report.md: 前回レビュー内容のまま。上記変更後に再レビューが必要 | MEDIUM |

---

## 対応方針

### HIGH優先（全件対応）

1. `docs/` 更新（先行）
   - migration-design.md: バッチコミット設計追記
   - logging-and-error-handling.md: 列定義更新

2. `sql/03_create_log_tables.sql` 更新
   - migration_step_log に `batch_no NUMBER DEFAULT 0`
   - migration_error_log に `target_table VARCHAR2(100)`, `batch_no NUMBER`, `error_context VARCHAR2(4000)`

3. `sql/00〜05` 全ファイル更新
   - `WHENEVER OSERROR EXIT FAILURE` を全ファイルの先頭に追加

4. `sql/04_create_pkg_migration.sql` 更新（最大変更）
   - Package SPEC: p_batch_size 追加、log_step/log_error シグネチャ更新
   - migrate_customer: BULK COLLECT + FORALL + REGEXP_LIKE + バッチCOMMIT
   - migrate_order: 同上
   - migrate_all: p_batch_size を子プロシージャに伝搬

5. `scripts/run-migration.ps1` 更新
   - -BatchSize パラメータ追加（デフォルト10000）
   - 経過秒数計算・ログ出力追加
   - BatchSize を migrate_all 呼び出しに渡す

### MEDIUM（対応）
6. `docs/review-report.md` は最終レビュー後に更新

---

## バッチコミット設計方針（暫定）

- DELETE → COMMIT（削除確定）→ BULK COLLECT LIMIT p_batch_size → FORALL INSERT → COMMIT（バッチ確定）をループ
- 失敗時: 当該バッチ分はROLLBACK。確定済みバッチは残る
- 再実行: 冒頭のDELETE+COMMITで全件削除してから再挿入 → 冪等性維持
- batch_no はerror_logに記録し、失敗バッチを特定可能にする
- step_logは各バッチCOMMIT後に進捗更新（src_count/tgt_count/batch_no）
