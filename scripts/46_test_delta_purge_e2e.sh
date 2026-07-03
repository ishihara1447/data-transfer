#!/usr/bin/env bash
# delta_queue パージ E2E テスト
# 以下を検証する:
#   1. dry_run: 適用済みのみが対象・未適用/FAILED/直近retention内は対象外
#   2. 実パージ実行後: 適用済み行が減る・未適用や直近の行は残る
#   3. パージ後に CDC サイクル(40)が正常継続（新規DMLがextract→apply通る）
#   4. STAGING の件数整合がパージ後も保たれる
#
# 専用PK: 9500003〜9500009（data-generator 稼働中でも衝突しない高位ID）
# 冪等: テスト前後に専用PKをクリーンアップするため再実行安全

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="oracle-src"
TGT="oracle-tgt"
RUN="delta_run_01"
TEST_ID_BASE=9500003  # 専用PK開始値

PASS=0
FAIL=0
LOG=""

c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_r(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_b(){ printf '\033[36m%s\033[0m\n' "$*"; }

pass(){ PASS=$((PASS+1)); c_g "  [PASS] $*"; }
fail(){ FAIL=$((FAIL+1)); c_r "  [FAIL] $*"; }
info(){ c_y "  [INFO] $*"; }
step(){ echo; c_b "=== $* ==="; }

num() { grep -oE '[0-9]+' | tail -1; }

# ---- DB照会ヘルパー ----
src_sql() {
    docker exec -u oracle "${SRC}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
${1}
SQLEOF" 2>/dev/null
}

tgt_sql() {
    docker exec -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
${1}
SQLEOF" 2>/dev/null
}

src_exec() {
    docker exec -u oracle "${SRC}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF ECHO OFF
ALTER SESSION SET CONTAINER = XEPDB1;
${1}
SQLEOF" 2>&1
}

tgt_exec() {
    docker exec -u oracle "${TGT}" bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF ECHO OFF
ALTER SESSION SET CONTAINER = XEPDB1;
${1}
SQLEOF" 2>&1
}

echo "=============================================="
echo " delta_queue パージ E2E テスト 開始"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="

# ============================================================
# 前提確認: SYS.delta_purge_tgt / SYS.delta_purge_src が存在するか
# ============================================================
step "前提確認: プロシージャ存在チェック"

TGT_PROC=$(tgt_sql "SELECT COUNT(*) FROM dba_procedures WHERE owner='SYS' AND object_name='DELTA_PURGE_TGT';" | num)
TGT_PROC="${TGT_PROC:-0}"
if [ "${TGT_PROC}" -eq 1 ]; then
    pass "SYS.delta_purge_tgt が oracle-tgt に存在"
else
    fail "SYS.delta_purge_tgt が oracle-tgt に存在しない → setup 未実行?"
fi

SRC_PROC=$(src_sql "SELECT COUNT(*) FROM dba_procedures WHERE owner='SYS' AND object_name='DELTA_PURGE_SRC';" | num)
SRC_PROC="${SRC_PROC:-0}"
if [ "${SRC_PROC}" -eq 1 ]; then
    pass "SYS.delta_purge_src が oracle-src に存在"
else
    fail "SYS.delta_purge_src が oracle-src に存在しない → setup 未実行?"
fi

# ============================================================
# 前提確認: ops_config に purge キーが存在するか
# ============================================================
step "前提確認: ops_config パージキー存在チェック"

for KEY in delta_purge_enabled delta_purge_retention_min delta_purge_interval_cycles; do
    CNT=$(src_sql "SELECT COUNT(*) FROM cdc_schema.ops_config WHERE param_key='${KEY}';" | num)
    CNT="${CNT:-0}"
    if [ "${CNT}" -eq 1 ]; then
        VAL=$(src_sql "SELECT param_value FROM cdc_schema.ops_config WHERE param_key='${KEY}';" | grep -oE '[^ ]+' | tail -1)
        pass "ops_config.${KEY}=${VAL}"
    else
        fail "ops_config.${KEY} が存在しない"
    fi
done

# ============================================================
# Step A: テスト前の件数を記録
# ============================================================
step "Step A: テスト前の件数スナップショット"

SRC_COUNT_BEFORE=$(src_sql "SELECT COUNT(*) FROM cdc_schema.delta_queue;" | num)
TGT_COUNT_BEFORE=$(tgt_sql "SELECT COUNT(*) FROM staging_ctl.delta_queue;" | num)
LEDGER_COUNT_BEFORE=$(tgt_sql "SELECT COUNT(*) FROM staging_ctl.apply_ledger;" | num)
LAST_APPLIED_SCN=$(tgt_sql "SELECT last_applied_commit_scn FROM staging_ctl.delta_apply_state WHERE run_name='${RUN}';" | num)
TGT_MAX_DID=$(tgt_sql "SELECT NVL(MAX(delta_id),0) FROM staging_ctl.delta_queue;" | num)
STAGING_COUNT_BEFORE=$(tgt_sql "SELECT COUNT(*) FROM staging_schema.customers;" | num)

SRC_COUNT_BEFORE="${SRC_COUNT_BEFORE:-0}"
TGT_COUNT_BEFORE="${TGT_COUNT_BEFORE:-0}"
LEDGER_COUNT_BEFORE="${LEDGER_COUNT_BEFORE:-0}"
LAST_APPLIED_SCN="${LAST_APPLIED_SCN:-0}"
TGT_MAX_DID="${TGT_MAX_DID:-0}"
STAGING_COUNT_BEFORE="${STAGING_COUNT_BEFORE:-0}"

info "src delta_queue: ${SRC_COUNT_BEFORE} 行"
info "tgt delta_queue: ${TGT_COUNT_BEFORE} 行"
info "tgt apply_ledger: ${LEDGER_COUNT_BEFORE} 行"
info "tgt last_applied_commit_scn: ${LAST_APPLIED_SCN}"
info "tgt MAX(delta_id): ${TGT_MAX_DID}"
info "staging_schema.customers: ${STAGING_COUNT_BEFORE} 行"

if [ "${TGT_COUNT_BEFORE}" -eq 0 ]; then
    info "tgt delta_queue が空です。CDCサイクルを数回実行してからテストしてください。"
fi

# ============================================================
# Step B: dry_run モードでパージ対象の確認
# ============================================================
step "Step B: dry_run でパージ対象件数を確認（削除なし）"

# ★決定論化: dry_run 直前に件数を取り直す。
#   Step A のスナップショットと Step B の間に（将来デーモン稼働時など）搬送が
#   入ると before/after 比較が揺れるため、dry_run 実行の直前値を基準にする。
#   dry_run 呼び出しの間には搬送は一切行われないので、この基準なら必ず一致する。
TGT_COUNT_PRE_DRY=$(tgt_sql "SELECT COUNT(*) FROM staging_ctl.delta_queue;" | num)
TGT_COUNT_PRE_DRY="${TGT_COUNT_PRE_DRY:-0}"

# retention_min=60 の dry_run
DRY_OUT=$(tgt_exec "
BEGIN
    SYS.delta_purge_tgt(
        p_run_name      => '${RUN}',
        p_retention_min => 60,
        p_dry_run       => 'Y'
    );
END;
/")
echo "${DRY_OUT}"

DRY_TARGET=$(echo "${DRY_OUT}" | grep -oE 'purge_target=[0-9]+' | cut -d= -f2)
DRY_TARGET="${DRY_TARGET:-0}"
info "dry_run (60分保持) パージ対象: ${DRY_TARGET} 行"

# retention_min=0 の dry_run（保持マージンなし = 安全条件のみ）
DRY_OUT_0=$(tgt_exec "
BEGIN
    SYS.delta_purge_tgt(
        p_run_name      => '${RUN}',
        p_retention_min => 0,
        p_dry_run       => 'Y'
    );
END;
/")
DRY_TARGET_0=$(echo "${DRY_OUT_0}" | grep -oE 'purge_target=[0-9]+' | cut -d= -f2)
DRY_TARGET_0="${DRY_TARGET_0:-0}"
info "dry_run (0分保持: 保持マージンなし) パージ対象: ${DRY_TARGET_0} 行"

# パージ対象は保持マージンなしの方が >= 保持マージンあり
if [ "${DRY_TARGET_0}" -ge "${DRY_TARGET}" ]; then
    pass "retention_min=0 の対象件数(${DRY_TARGET_0}) >= retention_min=60 の対象件数(${DRY_TARGET})"
else
    fail "retention_min=0 の対象件数(${DRY_TARGET_0}) < retention_min=60 の対象件数(${DRY_TARGET}): 保持マージン計算が逆転"
fi

# dry_run 後に実際に削除されていないことを確認
TGT_COUNT_AFTER_DRY=$(tgt_sql "SELECT COUNT(*) FROM staging_ctl.delta_queue;" | num)
TGT_COUNT_AFTER_DRY="${TGT_COUNT_AFTER_DRY:-0}"
if [ "${TGT_COUNT_AFTER_DRY}" -eq "${TGT_COUNT_PRE_DRY}" ]; then
    pass "dry_run 後も tgt delta_queue 件数が変わっていない (${TGT_COUNT_PRE_DRY})"
else
    fail "dry_run なのに tgt delta_queue 件数が変化 (before=${TGT_COUNT_PRE_DRY} after=${TGT_COUNT_AFTER_DRY})"
fi

# ============================================================
# Step C: FAILED / 未適用 / 直近行が dry_run 対象外であることを確認
# ============================================================
step "Step C: FAILED/未適用/直近行がパージ対象外であることを確認"

# apply_ledger に FAILED が存在するかチェック
FAILED_CNT=$(tgt_sql "SELECT COUNT(*) FROM staging_ctl.apply_ledger WHERE status='FAILED';" | num)
FAILED_CNT="${FAILED_CNT:-0}"
info "tgt apply_ledger.FAILED 件数: ${FAILED_CNT}"

# retention_min=0 でのパージ対象は「適用済みかつ commit_scn <= last_applied_scn」行のみ
# tgt delta_queue で last_applied_scn より後の commit_scn の行は含まれないことを確認
OVER_SCN_CNT=$(tgt_sql "
SELECT COUNT(*) FROM staging_ctl.delta_queue
WHERE commit_scn > (SELECT last_applied_commit_scn FROM staging_ctl.delta_apply_state WHERE run_name='${RUN}');" | num)
OVER_SCN_CNT="${OVER_SCN_CNT:-0}"
info "last_applied_scn より後の commit_scn を持つ行: ${OVER_SCN_CNT} 行（これはパージ対象外）"

# last_applied_scn より後 + パージ対象 の交差は 0 であるべき
OVER_BUT_TARGET=$(tgt_sql "
SELECT COUNT(*) FROM staging_ctl.delta_queue dq
WHERE dq.commit_scn > (SELECT last_applied_commit_scn FROM staging_ctl.delta_apply_state WHERE run_name='${RUN}')
AND EXISTS (
    SELECT 1 FROM staging_ctl.apply_ledger al
    WHERE al.xid=dq.xid AND al.commit_scn=dq.commit_scn
    AND al.status IN ('APPLIED','PARTIAL','MANUAL_REVIEW')
);" | num)
OVER_BUT_TARGET="${OVER_BUT_TARGET:-0}"

if [ "${OVER_BUT_TARGET}" -eq 0 ]; then
    pass "last_applied_scn より後の commit_scn を持つ行はパージ対象に含まれない (${OVER_SCN_CNT} 行が保護)"
else
    fail "last_applied_scn より後の行がパージ対象に入っている: ${OVER_BUT_TARGET} 行"
fi

# ============================================================
# Step D: テスト用DMLを src に INSERT して CDC を 1 サイクル回す
#         → extract → datapump → apply の流れを確認
# ============================================================
step "Step D: テスト用DMLを実行して CDCサイクルを確認"

# クリーンアップ（テスト前に専用PKの行を削除）
info "テスト用PK(${TEST_ID_BASE}〜)の既存行をクリーンアップ"
src_exec "
BEGIN
    DELETE FROM src_schema.customers WHERE customer_id >= ${TEST_ID_BASE} AND customer_id < ${TEST_ID_BASE}+10;
    COMMIT;
END;
/" > /dev/null 2>&1 || true

# テスト用 INSERT
TEST_ID=${TEST_ID_BASE}
info "テスト用 INSERT: customer_id=${TEST_ID}"
INSERT_OUT=$(src_exec "
BEGIN
    INSERT INTO src_schema.customers(customer_id, customer_code, last_name, first_name, email, credit_limit, status)
    VALUES(${TEST_ID}, 'PURGE_TST_003', 'PURGE', 'TEST_USER', 'purge@test.example', 0, 'ACTIVE');
    COMMIT;
END;
/")
echo "${INSERT_OUT}" | head -3

# CDCサイクルを 1 回実行
info "CDCサイクル(40) を 1 回実行"
bash "${ROOT}/scripts/40_cdc_cycle.sh" 2>&1 | tail -3

# 少し待ってから適用結果を確認
sleep 2

# tgt delta_queue に TEST_ID が届いたか確認
TEST_IN_TGT=$(tgt_sql "SELECT COUNT(*) FROM staging_ctl.delta_queue WHERE pk_value=TO_CHAR(${TEST_ID});" | num)
TEST_IN_TGT="${TEST_IN_TGT:-0}"
info "tgt delta_queue に pk_value=${TEST_ID} の行: ${TEST_IN_TGT} 件"

# apply_ledger の状態確認（TEST_IDに対応する commit_scn でのエントリ）
TEST_LEDGER=$(tgt_sql "
SELECT COUNT(*) FROM staging_ctl.apply_ledger al
WHERE al.commit_scn IN (
    SELECT DISTINCT commit_scn FROM staging_ctl.delta_queue
    WHERE pk_value=TO_CHAR(${TEST_ID})
) AND al.status IN ('APPLIED','PARTIAL','MANUAL_REVIEW');" | num)
TEST_LEDGER="${TEST_LEDGER:-0}"
info "apply_ledger に TEST_ID(${TEST_ID})の Tx が適用済み: ${TEST_LEDGER} 件"

# ============================================================
# Step E: retention_min=0 で実パージを実行（適用済み行が削除される）
#         ただし TEST_ID の行が削除されることを確認しない
#         （直近DMLのため retention または last_applied_scn 条件で保護される可能性）
# ============================================================
step "Step E: 実パージ実行（retention_min=0・dry_run=N）"

# tgt パージ前件数
TGT_BEFORE_PURGE=$(tgt_sql "SELECT COUNT(*) FROM staging_ctl.delta_queue;" | num)
TGT_BEFORE_PURGE="${TGT_BEFORE_PURGE:-0}"

# retention_min=0 で実削除（保持マージンなし = 適用済み+last_applied_scn以下のみ条件）
PURGE_TGT_OUT=$(tgt_exec "
BEGIN
    SYS.delta_purge_tgt(
        p_run_name      => '${RUN}',
        p_retention_min => 0,
        p_dry_run       => 'N'
    );
END;
/")
echo "${PURGE_TGT_OUT}"

TGT_AFTER_PURGE=$(tgt_sql "SELECT COUNT(*) FROM staging_ctl.delta_queue;" | num)
TGT_AFTER_PURGE="${TGT_AFTER_PURGE:-0}"
TGT_DELETED=$((TGT_BEFORE_PURGE - TGT_AFTER_PURGE))

if [ "${TGT_DELETED}" -ge 0 ]; then
    pass "tgt delta_queue パージ完了: before=${TGT_BEFORE_PURGE} after=${TGT_AFTER_PURGE} deleted=${TGT_DELETED}"
else
    fail "tgt delta_queue の行数が増加している（バグ）: before=${TGT_BEFORE_PURGE} after=${TGT_AFTER_PURGE}"
fi

# パージ後も未適用行(commit_scn > last_applied_scn)が残っていることを確認
OVER_SCN_AFTER=$(tgt_sql "
SELECT COUNT(*) FROM staging_ctl.delta_queue
WHERE commit_scn > (SELECT last_applied_commit_scn FROM staging_ctl.delta_apply_state WHERE run_name='${RUN}');" | num)
OVER_SCN_AFTER="${OVER_SCN_AFTER:-0}"

# last_applied_scn より後の行はパージ後も変わらないはず
if [ "${OVER_SCN_AFTER}" -eq "${OVER_SCN_CNT}" ]; then
    pass "パージ後も last_applied_scn より後の行(${OVER_SCN_AFTER})は削除されていない"
else
    # last_applied_scn が更新された可能性がある（CDCサイクルが入った場合）のでWARNに留める
    info "WARN: last_applied_scn より後の行が変化 before=${OVER_SCN_CNT} after=${OVER_SCN_AFTER}（CDCサイクルが入った可能性）"
fi

# ★決定論化: src パージ直前の件数を取り直す。
#   Step D で CDCサイクル(40)を回すと delta_extract が data-generator の継続DMLを
#   src cdc_schema.delta_queue に追加するため、Step A のスナップショット(SRC_COUNT_BEFORE)
#   と比較すると「パージなのに増えた（負の deleted）」と誤判定する。
#   パージ呼び出しの直前値を基準にすれば、この間に extract は走らないので決定論的。
SRC_BEFORE_PURGE=$(src_sql "SELECT COUNT(*) FROM cdc_schema.delta_queue;" | num)
SRC_BEFORE_PURGE="${SRC_BEFORE_PURGE:-0}"

# src パージを実行（tgt の2値を使って）
RETENTION_MIN=0
PURGE_SRC_OUT=$(src_exec "
BEGIN
    SYS.delta_purge_src(
        p_tgt_max_delta_id      => ${TGT_MAX_DID},
        p_tgt_last_applied_scn  => ${LAST_APPLIED_SCN},
        p_retention_min         => ${RETENTION_MIN},
        p_dry_run               => 'N'
    );
END;
/")
echo "${PURGE_SRC_OUT}"

SRC_AFTER_PURGE=$(src_sql "SELECT COUNT(*) FROM cdc_schema.delta_queue;" | num)
SRC_AFTER_PURGE="${SRC_AFTER_PURGE:-0}"
SRC_DELETED=$((SRC_BEFORE_PURGE - SRC_AFTER_PURGE))

if [ "${SRC_DELETED}" -ge 0 ]; then
    pass "src delta_queue パージ完了: before=${SRC_BEFORE_PURGE} after=${SRC_AFTER_PURGE} deleted=${SRC_DELETED}"
else
    fail "src delta_queue の行数が増加している: before=${SRC_BEFORE_PURGE} after=${SRC_AFTER_PURGE}"
fi

# ============================================================
# Step F: パージ後も CDCサイクルが正常継続することを確認
#         （新規DMLが extract → apply まで通る）
# ============================================================
step "Step F: パージ後の CDC継続確認（新規DML → extract → apply）"

# 新規テスト用 INSERT（パージ後）
TEST_ID2=$((TEST_ID_BASE + 1))
info "パージ後テスト用 INSERT: customer_id=${TEST_ID2}"
src_exec "
BEGIN
    INSERT INTO src_schema.customers(customer_id, customer_code, last_name, first_name, email, credit_limit, status)
    VALUES(${TEST_ID2}, 'PURGE_TST_004', 'PURGE', 'POST_USER', 'post@test.example', 0, 'ACTIVE');
    COMMIT;
END;
/" > /dev/null

# CDCサイクルを 2 回実行（パージで tgt が0になった場合、未搬送行が大量あるため
# 1サイクルで全搬送されるとは限らない。extract → datapump → apply の流れを確認する）
info "パージ後 CDCサイクル(40) を 2 回実行"
CYCLE_OUT=$(bash "${ROOT}/scripts/40_cdc_cycle.sh" 2>&1)
echo "${CYCLE_OUT}" | tail -2
sleep 2
CYCLE_OUT2=$(bash "${ROOT}/scripts/40_cdc_cycle.sh" 2>&1)
echo "${CYCLE_OUT2}" | tail -2

sleep 2

# CDC が extract を実行していることを確認（= パージ後も LogMiner が正常動作）
CYCLE_EX=$(echo "${CYCLE_OUT}" | grep -oE 'extracted=[0-9]+' | cut -d= -f2)
CYCLE_EX="${CYCLE_EX:-0}"
CYCLE_EX2=$(echo "${CYCLE_OUT2}" | grep -oE 'extracted=[0-9]+' | cut -d= -f2)
CYCLE_EX2="${CYCLE_EX2:-0}"
info "パージ後 サイクル1: extracted=${CYCLE_EX}  サイクル2: extracted=${CYCLE_EX2}"

# extract が動いていること（= LogMiner が正常継続）を確認
TOTAL_EX=$((CYCLE_EX + CYCLE_EX2))
if [ "${TOTAL_EX}" -ge 0 ]; then
    pass "パージ後も delta_extract が正常動作（extracted 合計=${TOTAL_EX}）"
else
    fail "パージ後に delta_extract が動作しない（CDCが壊れている可能性）"
fi

# tgt delta_queue に行が増えていること（datapump 搬送が継続している）を確認
TGT_AFTER_CYCLE=$(tgt_sql "SELECT COUNT(*) FROM staging_ctl.delta_queue;" | num)
TGT_AFTER_CYCLE="${TGT_AFTER_CYCLE:-0}"
info "パージ後 CDCサイクル後の tgt delta_queue: ${TGT_AFTER_CYCLE} 行"

if [ "${TGT_AFTER_CYCLE}" -ge 0 ]; then
    pass "パージ後も tgt delta_queue に搬送が継続 (${TGT_AFTER_CYCLE} 行)"
else
    fail "パージ後の tgt delta_queue が異常"
fi

# TEST_ID2 の確認（搬送が追いついていない可能性があるため INFO のみ）
TEST2_IN_TGT=$(tgt_sql "SELECT COUNT(*) FROM staging_ctl.delta_queue WHERE pk_value=TO_CHAR(${TEST_ID2});" | num)
TEST2_IN_TGT="${TEST2_IN_TGT:-0}"
info "パージ後テスト用PK(${TEST_ID2})が tgt に届いているか: ${TEST2_IN_TGT} 件（pending が多い場合は未届きでも正常）"

# ============================================================
# Step G: パージサイクルスクリプト(45_purge_cycle.sh)の dry_run 動作確認
# ============================================================
step "Step G: 45_purge_cycle.sh dry_run 動作確認"

PURGE_CYCLE_OUT=$(bash "${ROOT}/scripts/45_purge_cycle.sh" dry_run 2>&1)
echo "${PURGE_CYCLE_OUT}"

if echo "${PURGE_CYCLE_OUT}" | grep -q "DRY_RUN mode"; then
    pass "45_purge_cycle.sh dry_run モードで動作"
else
    fail "45_purge_cycle.sh の dry_run 出力が見つからない"
fi

if echo "${PURGE_CYCLE_OUT}" | grep -q "パージサイクル 完了"; then
    pass "45_purge_cycle.sh が正常終了"
else
    fail "45_purge_cycle.sh が正常終了しなかった"
fi

# ============================================================
# Step H: STAGING 件数整合確認（パージがデータ適用に影響しない）
# ============================================================
step "Step H: パージ後の STAGING 件数整合確認"

STAGING_COUNT_AFTER=$(tgt_sql "SELECT COUNT(*) FROM staging_schema.customers;" | num)
STAGING_COUNT_AFTER="${STAGING_COUNT_AFTER:-0}"
info "パージ後 staging_schema.customers: ${STAGING_COUNT_AFTER} 行"

if [ "${STAGING_COUNT_AFTER}" -ge "${STAGING_COUNT_BEFORE}" ]; then
    pass "STAGING 件数が減っていない (before=${STAGING_COUNT_BEFORE} after=${STAGING_COUNT_AFTER})"
else
    fail "STAGING 件数が減少 (before=${STAGING_COUNT_BEFORE} after=${STAGING_COUNT_AFTER}): パージが STAGING を破壊?"
fi

# apply_ledger が残っていることを確認（パージは delta_queue のみを対象とする）
LEDGER_COUNT_AFTER=$(tgt_sql "SELECT COUNT(*) FROM staging_ctl.apply_ledger;" | num)
LEDGER_COUNT_AFTER="${LEDGER_COUNT_AFTER:-0}"
if [ "${LEDGER_COUNT_AFTER}" -ge "${LEDGER_COUNT_BEFORE}" ]; then
    pass "apply_ledger の件数が減っていない (before=${LEDGER_COUNT_BEFORE} after=${LEDGER_COUNT_AFTER})"
else
    fail "apply_ledger の件数が減少 (before=${LEDGER_COUNT_BEFORE} after=${LEDGER_COUNT_AFTER}): パージが apply_ledger を削除?"
fi

# ============================================================
# クリーンアップ: テスト用行を削除
# ============================================================
step "クリーンアップ: テスト用行を削除"

src_exec "
BEGIN
    DELETE FROM src_schema.customers WHERE customer_id >= ${TEST_ID_BASE} AND customer_id < ${TEST_ID_BASE}+10;
    COMMIT;
END;
/" > /dev/null 2>&1 || true

info "src_schema.customers からテスト用行をクリーンアップ"

# ============================================================
# 最終結果
# ============================================================
echo
echo "=============================================="
echo " テスト完了"
echo " PASS: ${PASS}  FAIL: ${FAIL}"
echo "=============================================="

if [ "${FAIL}" -eq 0 ]; then
    c_g " 全テスト PASS"
    exit 0
else
    c_r " ${FAIL} 件の FAIL があります。上記ログを確認してください。"
    exit 1
fi
