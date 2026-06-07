# 運用パラメータ設定（ops_config）設計

作成日: 2026-06-07
目的: 本番相当（多PDB・500テーブル超・5TB級）の移行で実際に起こり得るリスク
—— **archive log / FRA（リドログ・アーカイブ領域）の枯渇、CDC遅延、UNDO 不足** ——
に対し、運用者が閾値・バッチ・DBパラメータ目標値を **コードを触らず安全に変更制御** できる
単一の仕組みを提供する。

---

## 1. 背景（なぜ作るか）

検証環境では小規模なので問題が表面化しないが、本番では:

- **archive log 枯渇**: 差分(LogMiner)が読めなくなると CDC 再開不能 → 全初期ロードやり直し。
  「10日で archive 消滅し CDC 再開不能」を検証で実体験済み（[archive-measurement-findings](archive-measurement-findings.md)）。
- **FRA(リドログ/アーカイブ保管領域)上限**: 領域が溢れるとアーカイブ停止 → DB ハング。
  上限値（`db_recovery_file_dest_size`）を環境規模に合わせて調整したい。
- **CDC 遅延**: 500テーブル級では1サイクルの負荷が増え、間隔・バッチの調整が要る。
- **UNDO 不足**: 5TB の初期ロード（FLASHBACK_SCN）中に ORA-01555 が出ると中断 → やり直し。

これらの「効きどころ」をハードコードから外し、**DB 上の設定表＋CLI** に集約する。

## 2. アーキテクチャ

```
            ┌──────────────────────────────┐
            │  oracle-src XEPDB1            │
            │  cdc_schema.ops_config        │ ← 単一の真実源(キー=値+範囲+分類+反映先)
            │  cdc_schema.ops_config_history│ ← 変更履歴(誰が・いつ・どの値)
            └──────────────────────────────┘
                 ▲ set/reset      │ 参照
                 │ (範囲検証+履歴)  ▼
   scripts/61_ops_config.sh   ┌─────────────────────────────┐
   (list/get/set/reset/        │ scripts/50 dashboard  → 閾値で警告色 │
    history/apply)             │ scripts/40 cdc_cycle  → batch 行数  │
        │ apply (ALTER SYSTEM)  │ scripts/41 cdc_daemon → interval 秒 │
        ▼                       └─────────────────────────────┘
   db_recovery_file_dest_size / undo_retention（実DBへ反映）
```

- 設定の実体は **oracle-src XEPDB1 の `cdc_schema.ops_config`** 一箇所。
- 外部依存ゼロ（SQL*Plus + bash のみ）。Web サーバ等の新規常駐プロセスを増やさない。

## 3. テーブル定義（`sql/cdc/35_ops_config_src.sql`）

### ops_config
| 列 | 説明 |
|----|------|
| param_key | キー（PK） |
| category | ARCHIVE / CDC / LAG / UNDO |
| param_value | 現在値（文字列。数値として検証） |
| default_value | 既定値（reset 先） |
| min_value / max_value | 数値範囲（NULL=無制限）。CLI が検証 |
| value_type | INT / SEC / PCT / MB |
| applies_to | DASHBOARD（可視化閾値）/ CDC（パイプライン制御）/ SRC_SYSTEM（DBパラメータ） |
| description | 説明（日本語） |
| updated_at / updated_by | 最終更新 |

### ops_config_history
変更のたびに old/new/changed_at/changed_by/note を追記（監査証跡）。

★**冪等性**: 再デプロイしても既存テーブルは DROP しない。不足キーのみ既定値で MERGE 補充
するため、運用者が変更した値は保護される。

## 4. パラメータ一覧（初期シード）

| キー | 分類 | 既定 | 範囲 | 反映先 | 意味 |
|------|------|------|------|--------|------|
| `fra_quota_mb` | ARCHIVE | 4096 | 1024..10485760 | SRC_SYSTEM | FRA上限MB（リドログ/アーカイブ領域）。`apply`で `db_recovery_file_dest_size` 反映 |
| `fra_warn_pct` | ARCHIVE | 80 | 1..100 | DASHBOARD | FRA使用率 警告(黄) |
| `fra_crit_pct` | ARCHIVE | 90 | 1..100 | DASHBOARD | FRA使用率 危険(赤) |
| `arch_retention_warn_days` | ARCHIVE | 7 | 1..365 | DASHBOARD | archive保持日数 警告下限 |
| `arch_retention_crit_days` | ARCHIVE | 3 | 1..365 | DASHBOARD | archive保持日数 危険下限 |
| `cdc_interval_sec` | CDC | 10 | 1..3600 | CDC | CDCデーモン サイクル間隔秒 |
| `transform_batch_rows` | CDC | 10000 | 100..1000000 | CDC | transform DELTA 1バッチ行数 |
| `transform_age_warn_sec` | LAG | 60 | 1..86400 | DASHBOARD | TARGET鮮度 警告 |
| `transform_age_crit_sec` | LAG | 300 | 1..86400 | DASHBOARD | TARGET鮮度 危険 |
| `pending_xfer_warn` | LAG | 1000 | 1..100000000 | DASHBOARD | 未搬送delta件数 警告 |
| `undo_retention_sec` | UNDO | 3600 | 300..172800 | SRC_SYSTEM | undo_retention目標。`apply`で反映 |
| `initial_load_hours` | UNDO | 6 | 1..168 | DASHBOARD | 5TB初期ロード想定時間（目安・参照値） |

## 5. CLI（`scripts/61_ops_config.sh`）

```bash
bash scripts/61_ops_config.sh list [category]          # 一覧（ARCHIVE/CDC/LAG/UNDO で絞込）
bash scripts/61_ops_config.sh get  <key>               # 1キーの詳細（範囲・説明含む）
bash scripts/61_ops_config.sh set  <key> <value> [note] # 変更（範囲検証 + 履歴記録）
bash scripts/61_ops_config.sh reset <key> [note]        # 既定値へ戻す
bash scripts/61_ops_config.sh history [key]            # 変更履歴
bash scripts/61_ops_config.sh apply [key]              # SRC_SYSTEM値を ALTER SYSTEM で実DB反映
```

- **範囲検証**: 整数でない / min..max 外は拒否（誤設定を入口で止める）。
- **履歴**: すべての変更を ops_config_history に記録（old→new, note）。
- **apply**: `fra_quota_mb`→`db_recovery_file_dest_size`、`undo_retention_sec`→`undo_retention`
  を `ALTER SYSTEM ... SCOPE=BOTH` で反映（CDB$ROOT）。DASHBOARD/CDC 系は反映不要（参照のみ）。

### 例（本番5TB向け調整）
```bash
bash scripts/61_ops_config.sh set fra_quota_mb 204800 "本番5TB: FRA 200GB"
bash scripts/61_ops_config.sh apply fra_quota_mb            # db_recovery_file_dest_size 反映
bash scripts/61_ops_config.sh set undo_retention_sec 43200 "初期ロード12h想定"
bash scripts/61_ops_config.sh apply undo_retention_sec
bash scripts/61_ops_config.sh set cdc_interval_sec 30 "500テーブル: 負荷平準化"
bash scripts/61_ops_config.sh set arch_retention_warn_days 14 "保持14日で警告"
```

## 6. 参照側の挙動

- **ダッシュボード（50）**: `transform_age_*` / `pending_xfer_warn` / `arch_retention_*` /
  `fra_*_pct` を読み、該当カードに 正常(緑)/警告(黄)/危険(赤) のバッジを表示。各カードに
  現在の閾値も併記。FRA未構成の環境は NA（—）表示。フッターに有効な閾値・間隔・バッチを表示。
- **cdc_cycle（40）**: `transform_batch_rows` を読み transform_all のバッチ行数に渡す。
- **cdc_daemon（41）**: 引数省略時 `cdc_interval_sec` をサイクル間隔に使用。

## 7. 設計上の注意・既知の制約

- `set` は値を**保存するだけ**。`SRC_SYSTEM` 系は別途 `apply` を実行して初めて実DBへ反映。
  （保存と反映を分離し、まとめて確認してから反映できるようにした。）
- 文字コード: 日本語(AL32UTF8)の化け防止に CLI 内で `NLS_LANG=American_America.AL32UTF8` を設定。
- SERVEROUTPUT は `ALTER SESSION SET CONTAINER` の**後**に置く（前だと PUT_LINE が消える既知挙動）。
- `db_recovery_file_dest` 未設定の環境では `db_recovery_file_dest_size` を 0 に戻せない
  （Oracle 仕様）。ただし dest が空なら当該サイズは不活性で実害なし。
- min/max は CLI で検証（DB側 CHECK 制約は型・分類のみ）。範囲はキー追加時に
  35_ops_config_src.sql の seed で調整する。

## 8. 拡張余地（将来）

- archive 連番欠落チェックの自動化（`v$archived_log.sequence#` 連続性）と閾値化。
- FRA 危険時のアラート連携（メール/Slack）。
- tgt 側パラメータ（apply バッチ等）の設定化（現状 transform バッチのみ）。
- 設定変更の承認フロー（2名承認）— 現状は履歴記録のみ。
