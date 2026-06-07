#!/usr/bin/env bash
# Phase1 境界条件テスト T3: 障害再開の冪等性（G4の核心）
# 設計: docs/phase1-commit-scn-redesign.md セクション7 T3
#
# 検証内容:
#   delta_apply が「適用途中で中断」した後に再実行されたとき、
#   既適用Txは apply_ledger でスキップされ、未適用Txのみ適用されて、
#   STAGING の最終状態が「中断なし実行」と一致することを確認する。
#
# クラッシュの忠実な再現:
#   delta_apply は Tx 単位で「DML＋apply_ledger記録」を原子的にCOMMITし、
#   last_applied_commit_scn は最後にまとめて更新する。
#   したがって「一部Txはコミット済み・台帳に記録済みだが、最終の
#   last_applied_commit_scn 更新が走らなかった」状態こそがクラッシュ後の姿。
#   本テストはこれを「Tx1,Tx2 を実procで適用 → SCNを巻き戻す」で忠実に作る。
#
# シナリオ:
#   0. tgt をクリーンに（テスト用 EVENT_ID/commit_scn 範囲のみ）
#   1. Tx1,Tx2 を delta_queue に投入し delta_apply 実行（＝クラッシュ前に確定した分）
#   2. last_applied_commit_scn を巻き戻す（＝最終状態更新が失われたクラッシュ状態）
#   3. Tx3,Tx4 を delta_queue に追加（全4Txが揃う）
#   4. delta_apply 再実行（＝障害再開）
#   5. 検証: skipped_tx=2 / applied_tx=2 / 全6行が各1回 / 台帳4件APPLIED
#           （skipped であって failed でないこと＝台帳スキップが効いている証明）

set -uo pipefail   # -e は付けない: grep の空マッチ(exit1)で検証前に落ちるのを避ける

TGT="oracle-tgt"

# テスト専用の ID レンジ（実データと衝突しないよう隔離）
EID_LO=9001; EID_HI=9006        # EVENT_ID 9001..9006（全6行）
SCN_BASE=20000000               # この値を再開点ベースラインに
SCN_LO=20000001; SCN_HI=20000099

echo "=============================================="
echo " T3: 障害再開の冪等性テスト（apply_ledger / G4）"
echo "=============================================="

run_sql() {
  docker exec -u oracle ${TGT} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
$1
SQLEOF" 2>&1
}

# ----------------------------------------------------------------
# Step 0: クリーンアップ（テスト範囲のみ）
# ----------------------------------------------------------------
echo ""
echo "[0] tgt クリーンアップ（EVENT_ID ${EID_LO}..${EID_HI} / commit_scn ${SCN_LO}..${SCN_HI}）"
run_sql "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
DELETE FROM staging_schema.system_events WHERE event_id BETWEEN ${EID_LO} AND ${EID_HI};
DELETE FROM staging_ctl.delta_queue;
DELETE FROM staging_ctl.apply_ledger WHERE commit_scn BETWEEN ${SCN_LO} AND ${SCN_HI};
UPDATE staging_ctl.delta_apply_state
   SET last_applied_commit_scn = ${SCN_BASE} WHERE run_name='delta_run_01';
COMMIT;
EXIT;
" >/dev/null
echo "    完了（再開点ベースライン = ${SCN_BASE}）"

# ----------------------------------------------------------------
# Step 1: Tx1,Tx2 を投入して delta_apply（クラッシュ前に確定した分）
#   Tx1: xid=T3..0001 commit_scn=20000001 → EVENT_ID 9001,9002（2行）
#   Tx2: xid=T3..0002 commit_scn=20000002 → EVENT_ID 9003     （1行）
# ----------------------------------------------------------------
echo ""
echo "[1] Tx1,Tx2 を delta_queue に投入 → delta_apply（クラッシュ前の確定分）"
run_sql "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
INSERT INTO staging_ctl.delta_queue(delta_id,commit_scn,xid,change_scn,seq_in_tx,table_name,operation,sql_redo,pk_value,extracted_at) VALUES
 (90001,${SCN_LO},'T300000000000001',19990001,1,'SYSTEM_EVENTS','INSERT',
  'insert into \"SRC_SCHEMA\".\"SYSTEM_EVENTS\"(\"EVENT_ID\",\"EVENT_TYPE\",\"SEVERITY\",\"MESSAGE\",\"CREATED_AT\") values (9001,''T3_TX1_R1'',''INFO'',''tx1 row1'',SYSTIMESTAMP)','9001',SYSTIMESTAMP);
INSERT INTO staging_ctl.delta_queue(delta_id,commit_scn,xid,change_scn,seq_in_tx,table_name,operation,sql_redo,pk_value,extracted_at) VALUES
 (90002,${SCN_LO},'T300000000000001',19990002,2,'SYSTEM_EVENTS','INSERT',
  'insert into \"SRC_SCHEMA\".\"SYSTEM_EVENTS\"(\"EVENT_ID\",\"EVENT_TYPE\",\"SEVERITY\",\"MESSAGE\",\"CREATED_AT\") values (9002,''T3_TX1_R2'',''INFO'',''tx1 row2'',SYSTIMESTAMP)','9002',SYSTIMESTAMP);
INSERT INTO staging_ctl.delta_queue(delta_id,commit_scn,xid,change_scn,seq_in_tx,table_name,operation,sql_redo,pk_value,extracted_at) VALUES
 (90003,${SCN_LO}+1,'T300000000000002',19990003,1,'SYSTEM_EVENTS','INSERT',
  'insert into \"SRC_SCHEMA\".\"SYSTEM_EVENTS\"(\"EVENT_ID\",\"EVENT_TYPE\",\"SEVERITY\",\"MESSAGE\",\"CREATED_AT\") values (9003,''T3_TX2_R1'',''INFO'',''tx2 row1'',SYSTIMESTAMP)','9003',SYSTIMESTAMP);
COMMIT;
EXIT;
" >/dev/null

run_sql "
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF ECHO OFF
BEGIN SYS.delta_apply('delta_run_01'); END;
/
EXIT;
" | grep -E "delta_apply:|ORA-" || true

echo "    --- Step1 後の状態 ---"
run_sql "
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 80 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'ledger=' || COUNT(*) FROM staging_ctl.apply_ledger WHERE commit_scn BETWEEN ${SCN_LO} AND ${SCN_HI};
SELECT 'staging_rows=' || COUNT(*) FROM staging_schema.system_events WHERE event_id BETWEEN ${EID_LO} AND ${EID_HI};
EXIT;
" | grep -E "ledger=|staging_rows="

# ----------------------------------------------------------------
# Step 2: クラッシュ再現 — last_applied_commit_scn を巻き戻す
#   （Tx毎コミット＋台帳は残るが、最終のSCN更新が失われた状態）
# ----------------------------------------------------------------
echo ""
echo "[2] クラッシュ再現: last_applied_commit_scn を ${SCN_BASE} に巻き戻す"
run_sql "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
UPDATE staging_ctl.delta_apply_state
   SET last_applied_commit_scn = ${SCN_BASE} WHERE run_name='delta_run_01';
COMMIT;
EXIT;
" >/dev/null
echo "    → 再開点は ${SCN_BASE}（Tx1,Tx2 は台帳には残るが SCN 上は未確定扱い）"

# ----------------------------------------------------------------
# Step 3: Tx3,Tx4 を追加（全4Txが揃う）
#   Tx3: xid=T3..0003 commit_scn=20000003 → EVENT_ID 9004,9005（2行）
#   Tx4: xid=T3..0004 commit_scn=20000004 → EVENT_ID 9006     （1行）
# ----------------------------------------------------------------
echo ""
echo "[3] Tx3,Tx4 を delta_queue に追加（全4Txが揃う）"
run_sql "
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
INSERT INTO staging_ctl.delta_queue(delta_id,commit_scn,xid,change_scn,seq_in_tx,table_name,operation,sql_redo,pk_value,extracted_at) VALUES
 (90004,${SCN_LO}+2,'T300000000000003',19990004,1,'SYSTEM_EVENTS','INSERT',
  'insert into \"SRC_SCHEMA\".\"SYSTEM_EVENTS\"(\"EVENT_ID\",\"EVENT_TYPE\",\"SEVERITY\",\"MESSAGE\",\"CREATED_AT\") values (9004,''T3_TX3_R1'',''INFO'',''tx3 row1'',SYSTIMESTAMP)','9004',SYSTIMESTAMP);
INSERT INTO staging_ctl.delta_queue(delta_id,commit_scn,xid,change_scn,seq_in_tx,table_name,operation,sql_redo,pk_value,extracted_at) VALUES
 (90005,${SCN_LO}+2,'T300000000000003',19990005,2,'SYSTEM_EVENTS','INSERT',
  'insert into \"SRC_SCHEMA\".\"SYSTEM_EVENTS\"(\"EVENT_ID\",\"EVENT_TYPE\",\"SEVERITY\",\"MESSAGE\",\"CREATED_AT\") values (9005,''T3_TX3_R2'',''INFO'',''tx3 row2'',SYSTIMESTAMP)','9005',SYSTIMESTAMP);
INSERT INTO staging_ctl.delta_queue(delta_id,commit_scn,xid,change_scn,seq_in_tx,table_name,operation,sql_redo,pk_value,extracted_at) VALUES
 (90006,${SCN_LO}+3,'T300000000000004',19990006,1,'SYSTEM_EVENTS','INSERT',
  'insert into \"SRC_SCHEMA\".\"SYSTEM_EVENTS\"(\"EVENT_ID\",\"EVENT_TYPE\",\"SEVERITY\",\"MESSAGE\",\"CREATED_AT\") values (9006,''T3_TX4_R1'',''INFO'',''tx4 row1'',SYSTIMESTAMP)','9006',SYSTIMESTAMP);
COMMIT;
EXIT;
" >/dev/null
echo "    delta_queue に Tx3(9004,9005),Tx4(9006) を追加"

# ----------------------------------------------------------------
# Step 4: delta_apply 再実行（＝障害再開）
# ----------------------------------------------------------------
echo ""
echo "[4] delta_apply 再実行（障害再開: Tx1,Tx2 はスキップ・Tx3,Tx4 のみ適用）"
APPLY_OUT=$(run_sql "
ALTER SESSION SET CONTAINER = XEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF ECHO OFF
BEGIN SYS.delta_apply('delta_run_01'); END;
/
EXIT;
" | grep -E "delta_apply:|WARN|ORA-" || true)
echo "    ${APPLY_OUT}"

# ----------------------------------------------------------------
# Step 5: 最終検証
# ----------------------------------------------------------------
echo ""
echo "[5] 最終検証"
VERIFY=$(run_sql "
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 80 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT 'total_rows=' || COUNT(*) FROM staging_schema.system_events WHERE event_id BETWEEN ${EID_LO} AND ${EID_HI};
SELECT 'distinct_rows=' || COUNT(DISTINCT event_id) FROM staging_schema.system_events WHERE event_id BETWEEN ${EID_LO} AND ${EID_HI};
SELECT 'ledger_applied=' || COUNT(*) FROM staging_ctl.apply_ledger WHERE commit_scn BETWEEN ${SCN_LO} AND ${SCN_HI} AND status='APPLIED';
SELECT 'ledger_failed=' || COUNT(*) FROM staging_ctl.apply_ledger WHERE commit_scn BETWEEN ${SCN_LO} AND ${SCN_HI} AND status='FAILED';
EXIT;
" | grep -E "=")
echo "${VERIFY}"

# 値を取り出す
SKIPPED=$(echo "${APPLY_OUT}" | grep -oE "skipped_tx=[0-9]+" | cut -d= -f2)
APPLIED=$(echo "${APPLY_OUT}" | grep -oE "applied_tx=[0-9]+" | cut -d= -f2)
FAILED_TX=$(echo "${APPLY_OUT}" | grep -oE "failed_tx=[0-9]+" | cut -d= -f2)
TOTAL=$(echo "${VERIFY}" | grep -oE "total_rows=[0-9]+" | cut -d= -f2)
DISTINCT=$(echo "${VERIFY}" | grep -oE "distinct_rows=[0-9]+" | cut -d= -f2)
LED_APPLIED=$(echo "${VERIFY}" | grep -oE "ledger_applied=[0-9]+" | cut -d= -f2)
LED_FAILED=$(echo "${VERIFY}" | grep -oE "ledger_failed=[0-9]+" | cut -d= -f2)

echo ""
echo "  再実行時: skipped_tx=${SKIPPED:-?}, applied_tx=${APPLIED:-?}, failed_tx=${FAILED_TX:-?}"
echo "  STAGING : total=${TOTAL:-?}, distinct=${DISTINCT:-?}（期待 6/6）"
echo "  台帳    : APPLIED=${LED_APPLIED:-?}, FAILED=${LED_FAILED:-?}（期待 4/0）"

echo ""
PASS=1
# 1) 既適用2Txがスキップされた（failではない＝台帳スキップが効いている証明）
[ "${SKIPPED:-0}" = "2" ] || { echo "  [NG] skipped_tx 期待2 / 実際${SKIPPED:-0}（既適用Txが台帳スキップされていない）"; PASS=0; }
# 2) 未適用2Txのみ適用
[ "${APPLIED:-0}" = "2" ] || { echo "  [NG] applied_tx 期待2 / 実際${APPLIED:-0}"; PASS=0; }
# 3) 失敗0（PK重複で誤再適用が起きていない）
[ "${FAILED_TX:-1}" = "0" ] || { echo "  [NG] failed_tx 期待0 / 実際${FAILED_TX:-?}（二重適用がPK衝突を起こした疑い）"; PASS=0; }
# 4) 全6行が各1回だけ存在（欠落も二重もない）
[ "${TOTAL:-0}" = "6" ] && [ "${DISTINCT:-0}" = "6" ] || { echo "  [NG] STAGING 行数 期待6/6 / 実際${TOTAL:-?}/${DISTINCT:-?}"; PASS=0; }
# 5) 台帳が全4TxきっちりAPPLIED
[ "${LED_APPLIED:-0}" = "4" ] && [ "${LED_FAILED:-1}" = "0" ] || { echo "  [NG] 台帳 期待 APPLIED=4/FAILED=0 / 実際 ${LED_APPLIED:-?}/${LED_FAILED:-?}"; PASS=0; }

echo ""
if [ "${PASS}" = "1" ]; then
  echo "  [PASS] T3: 障害再開で既適用Txは台帳スキップ・未適用のみ適用 → G4 冪等性 OK"
else
  echo "  [FAIL] T3: 冪等性に問題あり（上記NG参照）"
  exit 1
fi
echo "=============================================="
echo " T3 完了"
echo "=============================================="
