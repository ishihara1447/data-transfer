#!/usr/bin/env bash
# Phase1 境界条件テスト T1: 長時間トランザクション境界
# 設計: docs/phase1-commit-scn-redesign.md セクション7
#
# 検証内容:
#   baseline を跨ぐ長時間トランザクションが、欠落も二重適用もなく
#   「ちょうど1回」抽出・適用されることを確認する。
#
# シナリオ:
#   1. セッションA: INSERT 後に DBMS_LOCK.SLEEP(20) でホールド（未コミット状態を維持）
#   2. セッションB: 別の行を INSERT して即 COMMIT
#   3. delta_extract 実行 → B だけ抽出される（A は未コミット）
#   4. セッションA の SLEEP 終了 → 自動 COMMIT
#   5. delta_extract 再実行 → A が今度は抽出される
#   6. 検証: A も B も delta_queue にちょうど1回ずつ存在
#
# ポイント: PL/SQL から shell FIFO は読めないため DBMS_LOCK.SLEEP で待機

set -euo pipefail

SRC="oracle-src"
SLEEP_SEC=20  # セッションA が COMMIT するまでの待機秒数

echo "=============================================="
echo " T1: 長時間トランザクション境界テスト"
echo " セッションA hold = ${SLEEP_SEC}s (DBMS_LOCK.SLEEP)"
echo "=============================================="

# ----------------------------------------------------------------
# Step 0: 起点をリセット（クリーンな状態から）
# ----------------------------------------------------------------
echo ""
echo "[0] delta_queue クリア & 起点設定"
docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
DELETE FROM cdc_schema.delta_queue;
UPDATE cdc_schema.delta_extract_state
  SET last_extracted_commit_scn = 0 WHERE run_name='delta_run_01';
COMMIT;
EXIT;
SQLEOF
" >/dev/null 2>&1

# 現在SCNを起点として記録する（余分な過去データを拾わないよう先に一度 extract）
docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF ECHO OFF
BEGIN SYS.delta_extract('delta_run_01'); END;
/
EXIT;
SQLEOF
" 2>&1 | grep -E "extracted|ORA-" || true

docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET ECHO OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = XEPDB1;
DELETE FROM cdc_schema.delta_queue;
COMMIT;
EXIT;
SQLEOF
" >/dev/null 2>&1

echo "    起点 SCN 設定完了（queue クリア済み）"

# ----------------------------------------------------------------
# Step 1: セッションA をバックグラウンドで開始
#         INSERT → DBMS_LOCK.SLEEP(N) → COMMIT の順で実行
#         SLEEP 中は未コミット状態が N 秒間維持される
# ----------------------------------------------------------------
echo ""
echo "[1] セッションA: INSERT 後 ${SLEEP_SEC}s sleep してから COMMIT（バックグラウンド）"
docker exec -u oracle -d ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
ALTER SESSION SET CONTAINER = XEPDB1;
BEGIN
  INSERT INTO src_schema.system_events(event_type,source_system,severity,message)
  VALUES('T1_LONG_TX_A','t1','WARN','long tx A - committed late');
  DBMS_LOCK.SLEEP(${SLEEP_SEC});
  COMMIT;
END;
/
EXIT;
SQLEOF
"
sleep 3  # セッションA の INSERT が確実に実行されるのを待つ

# ----------------------------------------------------------------
# Step 2: セッションB を即コミット
# ----------------------------------------------------------------
echo "[2] セッションB: INSERT して即 COMMIT"
docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
ALTER SESSION SET CONTAINER = XEPDB1;
INSERT INTO src_schema.system_events(event_type,source_system,severity,message)
VALUES('T1_SHORT_TX_B','t1','INFO','short tx B - committed early');
COMMIT;
EXIT;
SQLEOF
" 2>&1 | grep -iE "(row created|commit complete|ORA-)"

docker exec -u oracle ${SRC} bash -c \
  "sqlplus -S '/ as sysdba' <<< 'ALTER SYSTEM SWITCH LOGFILE;'" >/dev/null 2>&1

# ----------------------------------------------------------------
# Step 3: delta_extract 実行 → B だけ抽出されるはず（A は未コミット）
# ----------------------------------------------------------------
echo ""
echo "[3] delta_extract 実行（A 未コミット中 → B だけ抽出されるはず）"
docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF ECHO OFF
BEGIN SYS.delta_extract('delta_run_01'); END;
/
EXIT;
SQLEOF
" 2>&1 | grep -E "extracted|ORA-" || true

echo ""
echo "    --- Step3 時点の delta_queue ---"
docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET ECHO OFF FEEDBACK OFF PAGESIZE 20 LINESIZE 80
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT REGEXP_SUBSTR(sql_redo,'T1_[A-Z_]+') AS event_type, COUNT(*) AS cnt
FROM cdc_schema.delta_queue
WHERE operation='INSERT'
GROUP BY REGEXP_SUBSTR(sql_redo,'T1_[A-Z_]+')
ORDER BY 1;
EXIT;
SQLEOF
" 2>&1 | grep -v "^$"

echo ""
echo "    期待: T1_SHORT_TX_B のみ（T1_LONG_TX_A は未コミット → 出てはいけない）"

# ----------------------------------------------------------------
# Step 4: セッションA の SLEEP 終了を待つ（自動 COMMIT）
# ----------------------------------------------------------------
WAIT_TOTAL=$((SLEEP_SEC + 5))
echo ""
echo "[4] セッションA の SLEEP 終了待ち（最大 ${WAIT_TOTAL}s）..."
sleep ${WAIT_TOTAL}

docker exec -u oracle ${SRC} bash -c \
  "sqlplus -S '/ as sysdba' <<< 'ALTER SYSTEM SWITCH LOGFILE;'" >/dev/null 2>&1

# ----------------------------------------------------------------
# Step 5: delta_extract 再実行 → A が抽出されるはず
# ----------------------------------------------------------------
echo "[5] delta_extract 再実行（A コミット済み → A が抽出されるはず）"
docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF ECHO OFF
BEGIN SYS.delta_extract('delta_run_01'); END;
/
EXIT;
SQLEOF
" 2>&1 | grep -E "extracted|ORA-" || true

# ----------------------------------------------------------------
# Step 6: 最終検証 — A も B も「ちょうど1回」
# ----------------------------------------------------------------
echo ""
echo "[6] 最終検証: A も B も delta_queue にちょうど1回ずつ"
# パース容易化のため "イベント名=件数" の単一トークンで出力する
RESULT=$(docker exec -u oracle ${SRC} bash -c "sqlplus -S '/ as sysdba' <<'SQLEOF'
SET ECHO OFF FEEDBACK OFF PAGESIZE 0 HEADING OFF LINESIZE 120 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT REGEXP_SUBSTR(sql_redo,'T1_[A-Z_]+') || '=' || COUNT(*)
FROM cdc_schema.delta_queue
WHERE operation='INSERT'
GROUP BY REGEXP_SUBSTR(sql_redo,'T1_[A-Z_]+')
ORDER BY 1;
EXIT;
SQLEOF
" 2>&1 | grep -E '^T1_[A-Z_]+=[0-9]+$')

echo "${RESULT}"

echo ""
# 検証判定（"T1_LONG_TX_A=1" 形式から件数を取り出す）
A_OCC=$(echo "${RESULT}" | grep "^T1_LONG_TX_A=" | cut -d= -f2)
B_OCC=$(echo "${RESULT}" | grep "^T1_SHORT_TX_B=" | cut -d= -f2)
A_OCC=${A_OCC:-0}
B_OCC=${B_OCC:-0}

echo "  T1_LONG_TX_A: 件数=${A_OCC}"
echo "  T1_SHORT_TX_B: 件数=${B_OCC}"

if [ "${A_OCC}" = "1" ] && [ "${B_OCC}" = "1" ]; then
    echo ""
    echo "  [PASS] T1: A も B もちょうど1回 → G2 境界条件 OK"
else
    echo ""
    echo "  [FAIL] T1: 期待 A=1,B=1 / 実際 A=${A_OCC},B=${B_OCC}"
    exit 1
fi

echo "=============================================="
echo " T1 完了"
echo "=============================================="
