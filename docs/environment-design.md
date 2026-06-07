# 環境設計書

## 概要

Windows 11 + WSL2 + Docker Desktop 上に Oracle データ移行検証用ローカル環境を構築する。  
**本環境は本番性能検証には使用しない。構文・構造・ログ設計の試作・動作確認専用である。**

---

## 環境全体構成

```
Windows 11
├── Docker Desktop (WSL2 backend)
│   └── docker network: cdc-migration-net
│       ├── oracle-src (container)        ← 移行元 / CDC ソース
│       │   ├── Oracle Database 21c XE
│       │   ├── port 1521 (host→container)
│       │   ├── PDB: XEPDB1 (src_schema / cdc_schema / log_schema)
│       │   └── volume: oracle-src-data (persistent)
│       ├── oracle-tgt (container)        ← 移行先 / CDC ターゲット
│       │   ├── Oracle Database 21c XE
│       │   ├── port 1522 (host→container:1521)
│       │   ├── PDB: XEPDB1 (tgt_schema)
│       │   └── volume: oracle-tgt-data (persistent)
│       └── data-generator (container)   ← DML ワークロード生成
│           ├── Python 3.11 + python-oracledb
│           └── oracle-src へ継続的 DML を発行
└── WSL2 (Ubuntu)
    ├── /home/ishihara1447/projects/data-transfer/  ← プロジェクトルート
    │   ├── docker-compose.yml
    │   ├── .env.example / .env
    │   ├── sql/              ← DDL・PL/SQL・シードデータ
    │   ├── data-generator/   ← Python コンテナソース
    │   ├── scripts/          ← PowerShell 起動スクリプト
    │   ├── logs/             ← 外部ログファイル出力先
    │   └── docs/             ← 設計ドキュメント
    └── SQL*Plus (接続クライアント)

Windows PowerShell / PowerShell 7
└── scripts/run-migration.ps1 ← スキーマ移行フェーズ用スクリプト
```

---

## 使用 Docker イメージ

| 項目 | 内容 |
|------|------|
| イメージ | `container-registry.oracle.com/database/express:21.3.0-xe` |
| Oracle バージョン | Oracle Database 21c Express Edition (XE) |
| ライセンス | Oracle Free Use Terms and Conditions (FUTC) |
| アーキテクチャ | linux/amd64 |

### イメージ選択理由

- Oracle XE は無償で利用可能
- Oracle 21c XE は Oracle Cloud Container Registry から pull 可能
- 本番想定（Oracle 12c）との差異は `docs/oracle-compatibility-policy.md` で管理する
- Oracle 19c XE (`container-registry.oracle.com/database/express:19.3.0-xe`) も選択肢だが、21c の方が XE として安定している

> **注意:** `container-registry.oracle.com` へのアクセスには Oracle アカウントでの事前ログインが必要。  
> `docker login container-registry.oracle.com` を実行してから pull すること。

---

## docker-compose.yml 構成方針

| サービス | コンテナ名 | ポート（host:container）| ボリューム |
|----------|-----------|------------------------|-----------|
| oracle-src | oracle-src | 1521:1521 | oracle-src-data |
| oracle-tgt | oracle-tgt | 1522:1521 | oracle-tgt-data |
| data-generator | data-generator | なし | なし |

| 設定項目 | 値 / 方針 |
|----------|-----------|
| ヘルスチェック | `/opt/oracle/checkDBStatus.sh` でリスナー・PDB 起動完了を確認 |
| 初回起動待機 | 最大 5 分（Oracle 初期化に時間がかかる）|
| data-generator 起動条件 | oracle-src が `healthy` になってから起動 |
| ネットワーク | `cdc-migration-net`（bridge）|
| リスタートポリシー | `unless-stopped` |
| PDB サービス名 | 両コンテナとも `XEPDB1`（Oracle XE 21c デフォルト）|

### 環境変数（.env ファイルで管理）

```
# oracle-src / oracle-tgt の SYS/SYSTEM パスワード
ORACLE_SRC_PASSWORD=YourSecurePass1
ORACLE_TGT_PASSWORD=YourSecurePass1

# スキーマパスワード
SRC_SCHEMA_PASS=srcpass1
TGT_SCHEMA_PASS=tgtpass1
LOG_SCHEMA_PASS=logpass1
CDC_SCHEMA_PASS=cdcpass1

# データジェネレータ強度
GENERATOR_INTENSITY=MEDIUM

# スキーマ移行フェーズ用（sql/00-05 / scripts/run-migration.ps1）
ORACLE_PASSWORD=YourSecurePass1
ORACLE_HOST=localhost
ORACLE_PORT=1521
ORACLE_SERVICE=XEPDB1
```

---

## ディレクトリ構成

```
data-transfer/
├── .claude/
│   └── agents/               ← サブエージェント定義
├── docs/
│   ├── environment-design.md           ← 本ファイル
│   ├── oracle-compatibility-policy.md
│   ├── migration-design.md
│   ├── logging-and-error-handling.md
│   ├── cdc-verification-design.md      ← CDC 検証フェーズ設計
│   └── review-report.md
├── sql/
│   ├── 00_create_users.sql             ← ユーザー作成（移行フェーズ）
│   ├── 01_create_source_schema.sql     ← 旧スキーマ DDL
│   ├── 02_create_target_schema.sql     ← 新スキーマ DDL
│   ├── 03_create_log_tables.sql        ← ログテーブル DDL
│   ├── 04_create_pkg_migration.sql     ← PL/SQL パッケージ
│   ├── 05_seed_source_data.sql         ← サンプルデータ投入
│   ├── cdc/                            ← CDC 検証フェーズ SQL
│   │   ├── 10_cdc_create_users.sql     ← oracle-src 用ユーザー作成
│   │   ├── 10b_cdc_create_users_tgt.sql← oracle-tgt 用ユーザー作成
│   │   ├── 11_cdc_src_schema.sql       ← SRC_SCHEMA DDL（10テーブル）
│   │   ├── 12_cdc_tgt_schema.sql       ← TGT_SCHEMA DDL + ヘルパー手順
│   │   ├── 13_cdc_schema.sql           ← CDC_SCHEMA + 制御テーブル
│   │   ├── 14_supplemental_logging.sql ← ARCHIVELOG + Supplemental Logging
│   │   ├── 15_dblink.sql               ← oracle-tgt への DB リンク作成
│   │   ├── 16_pkg_cdc_snapshot.sql     ← PKG_CDC_SNAPSHOT
│   │   ├── 17_pkg_cdc_logminer.sql     ← PKG_CDC_LOGMINER
│   │   └── 18_cdc_verify.sql           ← 整合性チェック・ラグ計測
├── data-generator/                     ← Python コンテナ
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── generator.py
│   ├── workload/
│   └── init/
├── scripts/
│   └── run-migration.ps1               ← スキーマ移行フェーズ用
├── logs/                               ← 外部ログ出力先（.gitignore対象）
├── docker-compose.yml
├── .env.example
├── .env                                ← .gitignore 対象
├── .gitignore
└── README.md
```

---

## 接続方法

### SQL*Plus（WSL2 内）

```bash
# oracle-src に SYS として接続（ホスト側ポート 1521）
sqlplus sys/YourSecurePass1@//localhost:1521/XEPDB1 as sysdba

# oracle-tgt に SYS として接続（ホスト側ポート 1522）
sqlplus sys/YourSecurePass1@//localhost:1522/XEPDB1 as sysdba

# oracle-src の src_schema として接続
sqlplus src_schema/srcpass1@//localhost:1521/XEPDB1
```

### SQL ファイル実行（SQL*Plus）

```bash
# スキーマ移行フェーズ（oracle-src 対象）
sqlplus sys/YourSecurePass1@//localhost:1521/XEPDB1 as sysdba @sql/00_create_users.sql

# CDC フェーズ（oracle-src 対象）
sqlplus sys/YourSecurePass1@//localhost:1521/XEPDB1 as sysdba @sql/cdc/10_cdc_create_users.sql
```

### Docker コンテナ内から接続

```bash
docker exec -it oracle-src sqlplus sys/YourSecurePass1@XEPDB1 as sysdba
docker exec -it oracle-tgt sqlplus sys/YourSecurePass1@XEPDB1 as sysdba
```

---

## WSL2 / Docker Desktop 固有の注意点

### ポート競合
- 1521 ポートが他プロセスに使われていないか事前確認: `netstat -tlnp | grep 1521`

### Oracle コンテナ初回起動
- Oracle の初期化には **3〜5 分**かかる。ヘルスチェックが HEALTHY になるまで待つ
- `docker compose logs -f oracle-src` または `docker compose logs -f oracle-tgt` でログを監視する
- oracle-src と oracle-tgt は独立して初期化されるため、それぞれ個別に HEALTHY になることを確認する

### ファイルシステム
- WSL2 内のパス（`/home/...`）と Windows パス（`C:\Users\...`）の変換に注意
- ボリュームは WSL2 内に置くことでパフォーマンスが向上する

### メモリ
- Oracle 21c XE の最小推奨メモリ: 2GB（Docker Desktop のメモリ割り当てを確認）
- WSL2 の `.wslconfig` でメモリ上限を設定している場合は 4GB 以上を推奨

### Docker ネットワーク
- PowerShell から接続する場合のホスト名は `localhost`（Docker Desktop が Windows からのポートをフォワード）
- WSL2 内から接続する場合は同じく `localhost`

---

## ヘルスチェック方針

Oracle XE コンテナに同梱の `/opt/oracle/checkDBStatus.sh` を使用する。  
TCP 疎通のみでは PDB がまだ OPEN でない状態を検出できないため、実スクリプトによる確認を採用。

```yaml
healthcheck:
  test: ["CMD-SHELL", "/opt/oracle/checkDBStatus.sh"]
  interval: 30s
  timeout: 10s
  retries: 10
  start_period: 5m
```

スクリプトからの起動時は `docker compose ps` でステータスが `healthy` になるまでポーリングする。

---

## 環境制限（重要）

- **本番性能検証には使用しない**
- **本番接続情報を .env に記載しない**
- Oracle 21c XE は接続数・CPU・メモリに制限がある（XE ライセンス制限）
- 本番データのコピーを投入しない
- この環境は SQL 構文・PL/SQL ロジック・ログ設計の試作専用である
