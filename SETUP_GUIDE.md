# 移植手順書 — 社内 WSL2 への環境構築ガイド

このガイドは、GitHub にあるこの環境を **社内の Windows パソコン（WSL2）** に移して
動かすための手順書です。**IT にくわしくない方でも進められる**よう、専門用語には説明を付け、
作業を上から順に並べています。

> ひとことで言うと：**「3つの準備」をしたあと、`git clone` して `./setup.sh` を1回実行するだけ**
> で、移行検証環境が立ち上がります。

---

## 目次

1. [この環境は何か（30秒で理解）](#1-この環境は何か30秒で理解)
2. [全体の流れ（地図）](#2-全体の流れ地図)
3. [必要なもの・前提](#3-必要なもの前提)
4. [準備①：WSL2 と Ubuntu を入れる](#4-準備wsl2-と-ubuntu-を入れる)
5. [準備②：Docker Desktop を入れる](#5-準備docker-desktop-を入れる)
6. [準備③：Oracle のイメージ取得ログイン（重要・自動化できない）](#6-準備oracle-のイメージ取得ログイン重要自動化できない)
7. [本番：git clone して setup.sh を実行](#7-本番git-clone-して-setupsh-を実行)
8. [うまくいったか確認する](#8-うまくいったか確認する)
9. [日々の操作（起動・停止・監視・設定変更）](#9-日々の操作起動停止監視設定変更)
10. [困ったとき（トラブルシューティング）](#10-困ったときトラブルシューティング)
11. [用語集（はじめての方へ）](#11-用語集はじめての方へ)

---

## 1. この環境は何か（30秒で理解）

Oracle データベースの **「無停止データ移行」** を試すための練習環境です。
パソコン1台の中に、Docker（下記用語集参照）を使って次の3つを作ります。

| 名前 | 役割（たとえ） |
|------|----------------|
| `oracle-src` | **移行元**のデータベース（引っ越し前の家） |
| `oracle-tgt` | **移行先**のデータベース（引っ越し先の家） |
| `data-generator` | 動いているアプリの代わりに、移行元へ**データを足し続ける**道具 |

これらを使って「動いているデータベースを止めずに、移行先へデータを移していく」様子を
ブラウザ（HTML 画面）で監視できます。

---

## 2. 全体の流れ（地図）

```
   ┌─ 一度だけの準備（人の手が必要）──────────────────────────┐
   │  ① WSL2 + Ubuntu を入れる                                   │
   │  ② Docker Desktop を入れる                                  │
   │  ③ Oracle のサイトでログイン（イメージ取得の許可）          │
   └───────────────────────────────────────────────┘
                          │
                          ▼
   ┌─ ここからはほぼ自動 ──────────────────────────────────┐
   │  ④ git clone（プログラム一式をダウンロード）               │
   │  ⑤ ./setup.sh を実行 → コンテナ起動・DB構築まで全自動       │
   └───────────────────────────────────────────────┘
                          │
                          ▼
   ⑥ ブラウザで監視画面を開いて確認 🎉
```

**人が操作するのは ①〜④ と「`./setup.sh` と打つ」だけ**です。
データベースの中身づくり（テーブル作成など難しい部分）はすべて `setup.sh` が代行します。

---

## 3. 必要なもの・前提

| 項目 | 必要な条件 |
|------|-----------|
| パソコン | Windows 10/11（64bit） |
| メモリ | 8GB 以上（できれば 16GB。DBを2つ動かすため） |
| ディスク空き | 20GB 以上 |
| ネットワーク | インターネットに接続できること（ライブラリ取得のため） |
| 権限 | ソフトをインストールできる管理者権限 |
| アカウント | Oracle の無料アカウント（[6章](#6-準備oracle-のイメージ取得ログイン重要自動化できない)で作成） |

---

## 4. 準備①：WSL2 と Ubuntu を入れる

> **WSL2 とは**：Windows の中で Linux（Ubuntu）を動かす仕組みです。この環境は Linux 上で動きます。

1. 画面左下の検索窓に「**PowerShell**」と入力し、右クリック →「**管理者として実行**」。
2. 黒い画面で、次の1行を入力して Enter：
   ```powershell
   wsl --install
   ```
3. インストールが終わったら、**パソコンを再起動**します。
4. 再起動後、自動で Ubuntu の初期設定画面が出ます。**ユーザー名とパスワード**を決めて入力します
   （このパスワードは後で Ubuntu 内で使うのでメモしてください）。

✅ うまくいくと、スタートメニューに「**Ubuntu**」が増えます。

---

## 5. 準備②：Docker Desktop を入れる

> **Docker とは**：アプリを「箱（コンテナ）」に入れて、どのパソコンでも同じように動かす道具です。
> Oracle データベースもこの箱で動かします。

1. ブラウザで [https://www.docker.com/products/docker-desktop/](https://www.docker.com/products/docker-desktop/)
   を開き、**Docker Desktop for Windows** をダウンロードしてインストール。
2. インストール後、Docker Desktop を起動します。
3. 右上の⚙（設定）→ **Resources → WSL Integration** を開き、
   **「Ubuntu」のスイッチを ON** にして「Apply & restart」。

   > これを ON にしないと、Ubuntu の中から Docker が使えません。**忘れずに。**

4. （推奨）設定 → **Resources → Memory** を **6GB 以上**に設定すると安定します。

✅ 確認：Ubuntu を開いて `docker --version` と打ち、バージョンが表示されれば OK。

---

## 6. 準備③：Oracle のイメージ取得ログイン（重要・自動化できない）

> **なぜ手作業が必要？**：Oracle データベースの「箱（イメージ）」は Oracle 社のサイトから
> 取得します。**利用規約への同意とログインが必須**で、ここだけは自動化できません。
> （この1回さえ済めば、あとは自動です。）

1. ブラウザで [https://container-registry.oracle.com](https://container-registry.oracle.com) を開く。
2. 右上から **無料アカウントを作成 / サインイン**。
3. 「Database」→「**Express**」を選び、**利用規約（Agree）に同意**します。
4. Ubuntu を開いて、次を実行（メールアドレスとパスワードを聞かれます）：
   ```bash
   docker login container-registry.oracle.com
   ```
   `Login Succeeded` と出れば成功です。

> 💡 社内にイメージのコピー置き場（社内レジストリ）がある場合は、情報システム部門に
> 「Oracle 21c XE イメージの入手方法」を確認してください。その場合この章は不要になることがあります。

---

## 7. 本番：git clone して setup.sh を実行

ここからが本番ですが、**実質2コマンド**です。Ubuntu を開いて操作します。

### 7-1. プログラム一式をダウンロード（git clone）

```bash
# 作業用フォルダへ移動（例：ホーム直下）
cd ~

# GitHub から一式を取得（URL は配布された実際のものに置き換え）
git clone https://github.com/ishihara1447/data-transfer.git

# 取得したフォルダに入る
cd data-transfer
```

> `git` が無い、と言われたら：`sudo apt update && sudo apt install -y git` を実行してください。

### 7-2. セットアップを実行（ここがメイン）

```bash
./setup.sh
```

これだけで、スクリプトが順番に次を**全自動**で行います（初回は **10〜15分**ほど）：

1. docker が使えるか確認
2. 設定ファイル `.env` を自動作成（検証用の初期パスワード入り）
3. `oracle-src` と `oracle-tgt` を起動し、準備完了まで待機
4. 両方のデータベースに、必要なテーブル・プログラム・設定を**正しい順番で**投入
5. `data-generator`（データを足し続ける道具）を起動

途中で `✓`（緑）が並び、最後に「**基本セットアップ完了 🎉**」が出れば成功です。

> **もっと自動化したい場合**：
> ```bash
> ./setup.sh --full
> ```
> こちらは上記に加えて「初期データ移送（初期ロード）」と「継続監視（CDC・ダッシュボードの常駐起動）」
> まで自動で行い、**すぐに監視できる状態**にします。

> **実行する前に中身だけ見たい場合**（何も変更しません）：
> ```bash
> ./setup.sh --plan
> ```

---

## 8. うまくいったか確認する

### 8-1. コンテナが動いているか

```bash
docker compose ps
```
`oracle-src` `oracle-tgt` が **healthy**、`data-generator` が **running** ならOK。

### 8-2. 監視画面（HTML）を見る

```bash
bash scripts/50_migration_dashboard.sh
```
`out/migration_dashboard.html` が作られます。Windows のエクスプローラーで
`\\wsl$\Ubuntu\home\<ユーザー名>\data-transfer\out\migration_dashboard.html` を
ダブルクリックするとブラウザで開けます。

> 件数照合・遅延/鮮度・archive 保持・警告色などが一覧で見られます。

### 8-3. 運用設定の確認

```bash
bash scripts/61_ops_config.sh list
```
変更できる運用パラメータ（archive 上限・警告のしきい値・CDC 間隔など）の一覧が出ます。

---

## 9. 日々の操作（起動・停止・監視・設定変更）

| やりたいこと | コマンド |
|--------------|----------|
| 全部 起動 | `docker compose up -d` |
| 全部 停止（データは残る） | `docker compose stop` |
| 監視画面を最新化 | `bash scripts/50_migration_dashboard.sh` |
| 監視画面を自動更新で常駐 | `bash scripts/51_dashboard_daemon.sh` |
| 差分の継続反映を常駐起動 | `bash scripts/41_cdc_daemon.sh` |
| 運用設定の一覧 | `bash scripts/61_ops_config.sh list` |
| 設定を変更（例：CDC間隔を30秒に） | `bash scripts/61_ops_config.sh set cdc_interval_sec 30 "理由メモ"` |
| DBパラメータを実反映（例：FRA上限） | `bash scripts/61_ops_config.sh apply fra_quota_mb` |
| 変更履歴を見る | `bash scripts/61_ops_config.sh history` |

> 設定変更の使い方の詳細は [`docs/ops-config-design.md`](docs/ops-config-design.md) を参照。

### 完全に作り直したいとき（注意：データ消去）

```bash
docker compose down -v   # コンテナとデータを全削除
./setup.sh               # まっさらから再構築
```

---

## 10. 困ったとき（トラブルシューティング）

| 症状 | 原因と対処 |
|------|-----------|
| `setup.sh` がコンテナ起動で止まる | Oracle イメージ未取得。[6章](#6-準備oracle-のイメージ取得ログイン重要自動化できない)の `docker login` を実行してから再実行。 |
| `docker: command not found` | Docker Desktop 未起動、または WSL Integration が OFF。[5章](#5-準備docker-desktop-を入れる)を確認。 |
| `permission denied: ./setup.sh` | 実行権限が無い。`chmod +x setup.sh` を一度実行。 |
| `healthy` にならない（5分以上） | メモリ不足の可能性。Docker Desktop のメモリ割当を増やす。`docker compose logs oracle-src` でログ確認。 |
| 文字が `???` に化ける | 通常は対策済み。再発時は端末の文字コードを UTF-8 に設定。 |
| ポートが使用中（1521/1522） | 別のソフトが使用中。`sudo lsof -i :1521` で確認し停止、または `docker-compose.yml` のポートを変更。 |
| `git clone` ができない | `git` 未インストール → `sudo apt install -y git`。社内プロキシ環境なら git のプロキシ設定が必要。 |

ログの見かた（つまずいた箇所の特定に有効）：
```bash
docker compose logs oracle-src | tail -50
docker compose logs data-generator | tail -50
```

---

## 11. 用語集（はじめての方へ）

| 用語 | やさしい説明 |
|------|--------------|
| WSL2 | Windows の中で Linux を動かす仕組み。 |
| Ubuntu | Linux の種類のひとつ。今回の作業場所。 |
| Docker | アプリを「箱」に入れてどこでも同じに動かす道具。 |
| コンテナ | Docker の「箱」。中で Oracle DB などが動く。 |
| イメージ | コンテナのもとになる「型」。Oracle 社から取得する。 |
| git / git clone | プログラム一式をネットから取得する道具・操作。 |
| `.env` | パスワードなどの設定を書くファイル。`setup.sh` が自動作成。 |
| スキーマ | データベースの中の「区画」。SRC（移行元）/STAGING（移行先の写し）/TARGET（変換後）など。 |
| CDC | 変更データの継続取り込み。動いている DB の差分を移行先へ流し続ける仕組み。 |
| archive log | DB の変更履歴ファイル。差分移送に使うため、消えないよう保持量を管理する。 |
| ダッシュボード | 移行の進み具合を一目で見る HTML の画面。 |

---

### 付録：手作業が必要な箇所まとめ（自動化できない理由）

| 箇所 | なぜ手作業か |
|------|--------------|
| WSL2 / Docker のインストール | OS への初回セットアップのため。 |
| `docker login`（Oracle） | Oracle 社の**利用規約同意とログイン**が必須のため。 |
| `git clone` の1行 | どこに置くかを人が決めるため。 |

それ以外（DB 構築・テーブル作成・設定投入・コンテナ起動）は **すべて `setup.sh` が自動**で行います。
