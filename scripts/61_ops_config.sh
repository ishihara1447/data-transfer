#!/usr/bin/env bash
# 運用パラメータ設定ツール (ops_config 管理CLI)
# 本番相当のリスク（archive/FRA枯渇・遅延・UNDO不足）に備え、運用者が閾値・バッチ・
# DBパラメータ目標値を「安全に」変更制御するための入口。範囲検証・履歴記録・反映を行う。
#
# 設定の実体: oracle-src XEPDB1 の cdc_schema.ops_config（単一の真実源）
#
# 使い方:
#   bash scripts/61_ops_config.sh list [category]   # 一覧（任意でARCHIVE/CDC/LAG/UNDO絞込）
#   bash scripts/61_ops_config.sh get  <key>        # 1キーの現在値
#   bash scripts/61_ops_config.sh set  <key> <value> [note]   # 変更（範囲検証+履歴記録）
#   bash scripts/61_ops_config.sh reset <key> [note]          # 既定値に戻す
#   bash scripts/61_ops_config.sh history [key]      # 変更履歴
#   bash scripts/61_ops_config.sh apply [key]        # SRC_SYSTEM値をALTER SYSTEMで実DBへ反映
#
# 例:
#   bash scripts/61_ops_config.sh set fra_quota_mb 20480 "本番5TB向け拡張"
#   bash scripts/61_ops_config.sh apply fra_quota_mb     # db_recovery_file_dest_size を反映

set -uo pipefail
SRC="oracle-src"
PDB="XEPDB1"
ACTION="${1:-list}"

# oracle-src XEPDB1 で SQL を実行（標準出力に結果のみ）
# ★日本語(AL32UTF8)の化け防止に NLS_LANG を設定。
# ★SET SERVEROUTPUT は ALTER SESSION SET CONTAINER の「後」に置く（前だとPUT_LINEが消える既知挙動）。
sql_pdb() {
  docker exec -i -u oracle "${SRC}" bash -c "export NLS_LANG=American_America.AL32UTF8; sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 400 ECHO OFF
ALTER SESSION SET CONTAINER = ${PDB};
SET SERVEROUTPUT ON
$(cat)
EXIT;
EOF" 2>/dev/null
}
# CDB$ROOT で SQL を実行（ALTER SYSTEM 用）
sql_root() {
  docker exec -i -u oracle "${SRC}" bash -c "export NLS_LANG=American_America.AL32UTF8; sqlplus -S '/ as sysdba' <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON LINESIZE 400 ECHO OFF
SET SERVEROUTPUT ON
$(cat)
EXIT;
EOF" 2>/dev/null
}

# キーの行を取得（key|cat|value|default|min|max|type|applies|desc）
fetch_row() {
  local key="$1"
  echo "SELECT param_key||'|'||category||'|'||param_value||'|'||default_value||'|'||
        NVL(TO_CHAR(min_value),'')||'|'||NVL(TO_CHAR(max_value),'')||'|'||value_type||'|'||
        applies_to||'|'||description
        FROM cdc_schema.ops_config WHERE param_key='${key}';" | sql_pdb | grep '|'
}

die() { echo "エラー: $*" >&2; exit 1; }

case "${ACTION}" in

  list)
    CAT="${2:-}"
    WHERE=""
    [ -n "${CAT}" ] && WHERE="WHERE category='${CAT^^}'"
    echo "=============================================================================="
    echo " 運用パラメータ (cdc_schema.ops_config)  ${CAT:+[${CAT^^}]}"
    echo "=============================================================================="
    printf "%-26s %-9s %-12s %-9s %-12s %s\n" "KEY" "CAT" "VALUE" "DEFAULT" "RANGE" "APPLIES"
    echo "------------------------------------------------------------------------------"
    echo "SELECT RPAD(param_key,26)||' '||RPAD(category,9)||' '||RPAD(param_value,12)||' '||
          RPAD(default_value,9)||' '||
          RPAD(NVL(TO_CHAR(min_value),'-')||'..'||NVL(TO_CHAR(max_value),'-'),12)||' '||applies_to
          FROM cdc_schema.ops_config ${WHERE} ORDER BY category, param_key;" | sql_pdb
    echo "------------------------------------------------------------------------------"
    echo "変更: set <key> <value> [note] / 反映(SRC_SYSTEM): apply <key> / 説明: get <key>"
    ;;

  get)
    KEY="${2:-}"; [ -n "${KEY}" ] || die "key を指定してください"
    ROW=$(fetch_row "${KEY}")
    [ -n "${ROW}" ] || die "キー '${KEY}' は存在しません"
    IFS='|' read -r k cat val def mn mx typ app desc <<< "${ROW}"
    echo "キー       : ${k}"
    echo "分類       : ${cat}"
    echo "現在値     : ${val} (${typ})"
    echo "既定値     : ${def}"
    echo "範囲       : ${mn:--} .. ${mx:--}"
    echo "反映先     : ${app}"
    echo "説明       : ${desc}"
    ;;

  set)
    KEY="${2:-}"; VAL="${3:-}"; NOTE="${4:-CLI set}"
    [ -n "${KEY}" ] && [ -n "${VAL}" ] || die "使い方: set <key> <value> [note]"
    ROW=$(fetch_row "${KEY}")
    [ -n "${ROW}" ] || die "キー '${KEY}' は存在しません"
    IFS='|' read -r k cat cur def mn mx typ app desc <<< "${ROW}"
    # 数値検証（全value_typeが数値前提）
    [[ "${VAL}" =~ ^[0-9]+$ ]] || die "値は整数で指定してください（指定: '${VAL}'）"
    if [ -n "${mn}" ] && [ "${VAL}" -lt "${mn}" ]; then die "下限 ${mn} を下回っています（指定: ${VAL}）"; fi
    if [ -n "${mx}" ] && [ "${VAL}" -gt "${mx}" ]; then die "上限 ${mx} を超えています（指定: ${VAL}）"; fi
    if [ "${VAL}" = "${cur}" ]; then echo "変更なし（現在値と同じ: ${cur}）"; exit 0; fi
    # 更新 + 履歴（NOTEのシングルクォートはエスケープ）
    SAFE_NOTE="${NOTE//\'/\'\'}"
    echo "DECLARE v_old VARCHAR2(100);
    BEGIN
      SELECT param_value INTO v_old FROM cdc_schema.ops_config WHERE param_key='${k}' FOR UPDATE;
      UPDATE cdc_schema.ops_config
         SET param_value='${VAL}', updated_at=SYSTIMESTAMP, updated_by=USER
       WHERE param_key='${k}';
      INSERT INTO cdc_schema.ops_config_history(hist_id,param_key,old_value,new_value,note)
        VALUES (cdc_schema.seq_ops_config_hist.NEXTVAL,'${k}',v_old,'${VAL}','${SAFE_NOTE}');
      COMMIT;
      DBMS_OUTPUT.PUT_LINE('OK: ${k} '||v_old||' -> ${VAL}');
    END;
    /" | sql_pdb
    if [ "${app}" = "SRC_SYSTEM" ]; then
      echo "※ '${k}' はDBパラメータです。実DBへ反映するには: bash scripts/61_ops_config.sh apply ${k}"
    fi
    ;;

  reset)
    KEY="${2:-}"; NOTE="${3:-CLI reset to default}"
    [ -n "${KEY}" ] || die "key を指定してください"
    ROW=$(fetch_row "${KEY}")
    [ -n "${ROW}" ] || die "キー '${KEY}' は存在しません"
    IFS='|' read -r k cat cur def mn mx typ app desc <<< "${ROW}"
    bash "$0" set "${k}" "${def}" "${NOTE}"
    ;;

  history)
    KEY="${2:-}"
    WHERE=""
    [ -n "${KEY}" ] && WHERE="WHERE param_key='${KEY}'"
    echo "=============================================================================="
    echo " 変更履歴 (ops_config_history)  ${KEY:+[${KEY}]}"
    echo "=============================================================================="
    printf "%-20s %-22s %-10s %-10s %s\n" "WHEN" "KEY" "OLD" "NEW" "NOTE"
    echo "------------------------------------------------------------------------------"
    echo "SELECT RPAD(TO_CHAR(changed_at,'YYYY-MM-DD HH24:MI:SS'),20)||' '||RPAD(param_key,22)||' '||
          RPAD(NVL(old_value,'-'),10)||' '||RPAD(NVL(new_value,'-'),10)||' '||NVL(note,'-')
          FROM (SELECT * FROM cdc_schema.ops_config_history ${WHERE} ORDER BY hist_id DESC)
          WHERE ROWNUM<=30;" | sql_pdb
    ;;

  apply)
    KEY="${2:-}"
    echo "=============================================================================="
    echo " SRC_SYSTEM パラメータの実DB反映 (ALTER SYSTEM)  ${KEY:+[${KEY}]}"
    echo "=============================================================================="
    # 反映対象キーを取得（KEY指定なら1件、なければ全SRC_SYSTEM）
    SEL="SELECT param_key||'|'||param_value FROM cdc_schema.ops_config WHERE applies_to='SRC_SYSTEM'"
    [ -n "${KEY}" ] && SEL="${SEL} AND param_key='${KEY}'"
    ROWS=$(echo "${SEL};" | sql_pdb | grep '|')
    [ -n "${ROWS}" ] || die "反映対象(SRC_SYSTEM)が見つかりません ${KEY:+(key=${KEY})}"
    while IFS='|' read -r k v; do
      [ -z "${k}" ] && continue
      case "${k}" in
        fra_quota_mb)
          echo "→ db_recovery_file_dest_size = ${v}M"
          echo "ALTER SYSTEM SET db_recovery_file_dest_size=${v}M SCOPE=BOTH;
                SELECT 'applied db_recovery_file_dest_size='||value FROM v\$parameter WHERE name='db_recovery_file_dest_size';" | sql_root
          ;;
        undo_retention_sec)
          echo "→ undo_retention = ${v}"
          echo "ALTER SYSTEM SET undo_retention=${v} SCOPE=BOTH;
                SELECT 'applied undo_retention='||value FROM v\$parameter WHERE name='undo_retention';" | sql_root
          ;;
        *)
          echo "→ (スキップ) ${k} は自動反映マッピング未定義"
          ;;
      esac
    done <<< "${ROWS}"
    echo "------------------------------------------------------------------------------"
    echo "反映完了。現状計測は: bash scripts/10_measure_archivelog.sh"
    ;;

  *)
    echo "使い方: $0 list|get|set|reset|history|apply ..." >&2
    echo "  list [category]      一覧 (ARCHIVE/CDC/LAG/UNDO)"
    echo "  get  <key>           1キーの詳細"
    echo "  set  <key> <value> [note]  変更（範囲検証+履歴）"
    echo "  reset <key> [note]   既定値に戻す"
    echo "  history [key]        変更履歴"
    echo "  apply [key]          SRC_SYSTEM値をALTER SYSTEMで反映"
    exit 1
    ;;
esac
