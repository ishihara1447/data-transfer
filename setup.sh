#!/usr/bin/env bash
# ============================================================================
#  setup.sh — Oracle データ移行検証環境 ワンコマンド構築スクリプト
# ----------------------------------------------------------------------------
#  git clone 後、このスクリプトを1回実行するだけで以下を自動で行う:
#    1. 前提コマンド(docker / docker compose)の確認
#    2. .env が無ければ .env.example から自動生成
#    3. oracle-src / oracle-tgt コンテナ起動 + 起動完了(healthy)まで待機
#    4. 両DBへスキーマ・パッケージ・設定を正しい順序で自動デプロイ
#    5. data-generator(稼働中アプリ模擬)を起動 → マスタ投入 + 継続DML
#    （オプション）--full で 初期ロード + CDCデーモン + ダッシュボードまで起動
#
#  使い方:
#    ./setup.sh            標準構築（コンテナ + スキーマ + ジェネレータ）
#    ./setup.sh --full     標準構築 + 初期ロード + CDC/ダッシュボード常駐起動
#    ./setup.sh --plan     何をするかだけ表示（実行しない・安全な確認用）
#    ./setup.sh --help     ヘルプ
#
#  事前に必要な手動作業（自動化不可・READMEとSETUP_GUIDE.md参照）:
#    - Docker Desktop(WSL2連携) または WSL2内 Docker のインストール
#    - docker login container-registry.oracle.com（Oracle社のイメージ利用に必須）
# ============================================================================

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

# ---- 表示ヘルパー -----------------------------------------------------------
c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }   # 緑（成功）
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }   # 黄（注意）
c_r(){ printf '\033[31m%s\033[0m\n' "$*"; }   # 赤（エラー）
c_b(){ printf '\033[36m%s\033[0m\n' "$*"; }   # 水色（見出し）
step(){ echo; c_b "▶ $*"; }
die(){ c_r "✗ エラー: $*"; exit 1; }

MODE="normal"
case "${1:-}" in
  --full) MODE="full" ;;
  --plan) MODE="plan" ;;
  --help|-h)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) die "不明な引数: $1（--full / --plan / --help）" ;;
esac

# ---- docker compose コマンドの判定 -----------------------------------------
detect_compose() {
  if docker compose version >/dev/null 2>&1; then echo "docker compose";
  elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose";
  else return 1; fi
}

# ---- DB 接続情報 ------------------------------------------------------------
SRC="oracle-src"; TGT="oracle-tgt"; PDB="XEPDB1"

# .env から値を読む（DEFINE 注入用）
load_env() {
  set -a; # shellcheck disable=SC1091
  [ -f "${ROOT}/.env" ] && . "${ROOT}/.env"; set +a
}

# SQL ファイルを指定コンテナへ流し込む（&&置換変数は .env から DEFINE 注入）
#   files は file の内部で CONNECT / AS SYSDBA する前提
deploy_sql() {
  local container="$1" file="$2"
  [ -f "${ROOT}/${file}" ] || die "SQLファイルが見つかりません: ${file}"
  {
    echo "SET DEFINE ON"
    echo "DEFINE SRC_SCHEMA_PASS=${SRC_SCHEMA_PASS:-srcpass1}"
    echo "DEFINE TGT_SCHEMA_PASS=${TGT_SCHEMA_PASS:-tgtpass1}"
    echo "DEFINE CDC_SCHEMA_PASS=${CDC_SCHEMA_PASS:-cdcpass1}"
    echo "DEFINE LOG_SCHEMA_PASS=${LOG_SCHEMA_PASS:-logpass1}"
    echo "DEFINE STAGING_SCHEMA_PASS=${STAGING_SCHEMA_PASS:-stagingpass1}"
    cat "${ROOT}/${file}"
  } | docker exec -i -u oracle "${container}" \
        bash -c "export NLS_LANG=American_America.AL32UTF8; sqlplus -S /nolog"
}

# 指定コンテナの healthcheck が healthy になるまで待つ
wait_healthy() {
  local container="$1" max="${2:-60}" i=0 st
  printf '  %s の起動を待機中' "${container}"
  while [ "${i}" -lt "${max}" ]; do
    st=$(docker inspect -f '{{.State.Health.Status}}' "${container}" 2>/dev/null || echo "none")
    if [ "${st}" = "healthy" ]; then echo; c_g "  ✓ ${container} 起動完了 (healthy)"; return 0; fi
    printf '.'; sleep 10; i=$((i+1))
  done
  echo; die "${container} が時間内に healthy になりませんでした（docker compose logs ${container} を確認）"
}

# XEPDB1 で簡単なクエリが通るまで待つ（ARCHIVELOG再起動後の復帰確認）
wait_db_open() {
  local container="$1" max="${2:-30}" i=0 r
  printf '  %s の XEPDB1 オープンを待機中' "${container}"
  while [ "${i}" -lt "${max}" ]; do
    r=$(docker exec -i -u oracle "${container}" bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
ALTER SESSION SET CONTAINER = ${PDB};
SELECT 'OPEN' FROM dual;
EOF" 2>/dev/null | grep -o OPEN | head -1)
    if [ "${r}" = "OPEN" ]; then echo; c_g "  ✓ ${container} XEPDB1 オープン確認"; return 0; fi
    printf '.'; sleep 5; i=$((i+1))
  done
  echo; die "${container} の XEPDB1 が開きませんでした"
}

# ---- デプロイ対象（順序が重要）---------------------------------------------
SRC_FILES=(
  "sql/cdc/10_cdc_create_users.sql"        # SRC/CDC/LOG/TGT ユーザー作成
  "sql/cdc/11_cdc_src_schema.sql"          # SRC_SCHEMA テーブル群
  "sql/cdc/13_cdc_schema.sql"              # CDC_SCHEMA 制御テーブル
  "sql/cdc/14_supplemental_logging.sql"    # ARCHIVELOG + 補足ログ（DB再起動を伴う）
  "sql/cdc/30_delta_queue_src.sql"         # delta_queue / 進捗状態
  "sql/cdc/34_cdc_table_catalog.sql"       # 追跡対象テーブル・カタログ（LOB分類付き）
  "sql/cdc/35_ops_config_src.sql"          # 運用パラメータ ops_config（purge設定含む）
  "sql/cdc/36_redo_replay_whitelist.sql"   # SQL_REDO直接適用ホワイトリスト
  "sql/cdc/31_pkg_delta_extract_src.sql"   # SYS.delta_extract（LOB DELETE即時適用分岐含む）
  "sql/cdc/39_lob_resync_src.sql"          # cdc_schema.lob_resync_request / SYS.lob_resync_export_rows
  "sql/cdc/45_pkg_delta_purge_src.sql"     # SYS.delta_purge_src（delta_queue パージ）
  "sql/cdc/47_pkg_archive_gap_src.sql"     # SYS.archive_gap_check（アーカイブ連番欠落チェック）
)
TGT_FILES=(
  "sql/cdc/20_staging_users_tgt.sql"       # STAGING_SCHEMA ユーザー（1.0ミラー受け皿）
  "sql/cdc/32_delta_queue_tgt.sql"         # staging_ctl + delta_queue + apply_ledger
  "sql/cdc/37_delta_manual_review_queue.sql" # 手動調査キュー（pk_value列追加済み）
  "sql/cdc/46_pkg_delta_purge_tgt.sql"     # SYS.delta_purge_tgt（delta_queue パージ）
  "sql/transform/40_phase2_setup_tgt.sql"  # TARGET/LOG ユーザー + 各表 + 変換カタログ
  "sql/transform/41_pkg_transform_util.sql" # 共有変換関数
  "sql/transform/42_pkg_transform.sql"     # 変換オーケストレータ pkg_transform
  "sql/cdc/38_lob_resync_tgt.sql"          # lob_resync_target / シャドウ表 / build_targets / merge
  "sql/cdc/33_pkg_delta_apply_tgt.sql"     # SYS.delta_apply（pk_value伝播・C分類DELETE即時適用）
)

# ---- --plan: 実行せず手順だけ表示 ------------------------------------------
if [ "${MODE}" = "plan" ]; then
  c_b "===== setup.sh 実行計画（--plan: 実行しません）====="
  echo "1) 前提確認: docker / docker compose"
  echo "2) .env 準備（無ければ .env.example からコピー）"
  echo "3) コンテナ起動: ${SRC} / ${TGT}（healthy まで待機）"
  echo "4) ${SRC} へデプロイ:";  printf '     - %s\n' "${SRC_FILES[@]}"
  echo "5) ${TGT} へデプロイ:";  printf '     - %s\n' "${TGT_FILES[@]}"
  echo "6) data-generator 起動（マスタ投入 + 継続DML）"
  echo "7) --full 指定時: 初期ロード + CDCデーモン + ダッシュボードデーモン起動"
  exit 0
fi

# ============================================================================
#  実行
# ============================================================================
c_b "===== Oracle データ移行検証環境 セットアップ開始 ====="

# 1) 前提確認 ---------------------------------------------------------------
step "1/6 前提コマンドの確認"
command -v docker >/dev/null 2>&1 || die "docker が見つかりません。Docker Desktop(WSL2連携) を導入してください。"
docker info >/dev/null 2>&1 || die "docker デーモンに接続できません。Docker Desktop を起動してください。"
COMPOSE="$(detect_compose)" || die "docker compose が使えません。Docker Desktop を最新化してください。"
c_g "  ✓ docker / ${COMPOSE} OK"

# 2) .env 準備 --------------------------------------------------------------
step "2/6 .env の準備"
if [ ! -f "${ROOT}/.env" ]; then
  cp "${ROOT}/.env.example" "${ROOT}/.env"
  c_y "  .env.example から .env を作成しました（検証用の既定パスワード）。"
  c_y "  本番情報は絶対に入れないでください。必要ならパスワードを編集してください。"
else
  c_g "  ✓ 既存の .env を使用"
fi
load_env

# 3) コンテナ起動 -----------------------------------------------------------
step "3/6 Oracle コンテナの起動（初回はイメージ取得で数分かかります）"
if ! ${COMPOSE} up -d ${SRC} ${TGT}; then
  c_r "  コンテナ起動に失敗しました。"
  c_y "  よくある原因: Oracle イメージ未取得。先に下記を実行してください:"
  c_y "    docker login container-registry.oracle.com"
  c_y "  （https://container-registry.oracle.com で利用規約に同意が必要）"
  exit 1
fi
wait_healthy "${SRC}" 60
wait_healthy "${TGT}" 60

# 4) oracle-src デプロイ ----------------------------------------------------
step "4/6 oracle-src スキーマ・パッケージのデプロイ"
for f in "${SRC_FILES[@]}"; do
  echo "  → ${f}"
  if ! deploy_sql "${SRC}" "${f}"; then die "デプロイ失敗: ${f}"; fi
  # ARCHIVELOG 有効化は DB 再起動を伴うため、直後にオープン確認
  case "${f}" in *14_supplemental_logging.sql) wait_db_open "${SRC}" 30 ;; esac
done
c_g "  ✓ oracle-src デプロイ完了"

# 5) oracle-tgt デプロイ ----------------------------------------------------
step "5/6 oracle-tgt スキーマ・パッケージのデプロイ"
for f in "${TGT_FILES[@]}"; do
  echo "  → ${f}"
  if ! deploy_sql "${TGT}" "${f}"; then die "デプロイ失敗: ${f}"; fi
done
c_g "  ✓ oracle-tgt デプロイ完了"

# 6) data-generator 起動 ----------------------------------------------------
step "6/6 data-generator の起動（マスタ投入 + 継続DML）"
${COMPOSE} up -d data-generator >/dev/null 2>&1 || c_y "  data-generator 起動に失敗（後で再試行可）"
c_g "  ✓ data-generator 起動指示済み"

c_g "========================================================="
c_g " 基本セットアップ完了 🎉"
c_g "========================================================="

# ---- --full: 初期ロード + 常駐起動 ----------------------------------------
if [ "${MODE}" = "full" ]; then
  step "オプション: 初期ロード + 常駐デーモン起動 (--full)"
  c_y "  data-generator のマスタ投入を待機します（最大90秒）…"
  sleep 30
  # マスタ投入が進んでから初期ロード（FLASHBACK_SCN）
  for i in 1 2 3; do
    n=$(docker exec -i -u oracle "${SRC}" bash -c "sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
ALTER SESSION SET CONTAINER = ${PDB};
SELECT COUNT(*) FROM src_schema.customers;
EOF" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    [ "${n:-0}" -gt 0 ] 2>/dev/null && break || sleep 20
  done
  echo "  初期ロード（移行元1.0 → 移行先1.0）を実行…"
  bash "${ROOT}/scripts/30_initial_load_flashback.sh" || c_y "  初期ロードでエラー（ログ確認）"
  # ★初期変換（移行先1.0 → 2.0）を全件で実行して TARGET を満たす。
  #   これが無いと CDC デーモンの DELTA 変換は baseline 分を拾えず TARGET が空のままになる。
  echo "  初期変換（移行先1.0 → 2.0・全件）を実行…"
  docker exec -i -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'EOF'
ALTER SESSION SET CONTAINER = ${PDB};
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF
BEGIN log_schema.pkg_transform.transform_all('INITIAL_LOAD','INITIAL',10000,'Y'); END;
/
EOF" 2>&1 | grep -iE 'status=|ORA-|変換' | head -3 || c_y "  初期変換でエラー（ログ確認）"
  echo "  CDCデーモン・ダッシュボードデーモンをバックグラウンド起動…"
  nohup bash "${ROOT}/scripts/41_cdc_daemon.sh"      >"${ROOT}/out/cdc_daemon.log" 2>&1 &
  nohup bash "${ROOT}/scripts/51_dashboard_daemon.sh">"${ROOT}/out/dashboard_daemon.log" 2>&1 &
  c_g "  ✓ 常駐起動完了（ログ: out/cdc_daemon.log / out/dashboard_daemon.log）"
fi

# ---- 次の一手の案内 -------------------------------------------------------
echo
c_b "次にできること:"
echo "  ・状態をHTMLで確認:   bash scripts/50_migration_dashboard.sh && out/migration_dashboard.html を開く"
echo "  ・運用パラメータ確認: bash scripts/61_ops_config.sh list"
if [ "${MODE}" != "full" ]; then
  echo "  ・初期ロード＋常駐起動まで自動化: ./setup.sh --full"
fi
echo "  ・コンテナ状態:       ${COMPOSE} ps"
