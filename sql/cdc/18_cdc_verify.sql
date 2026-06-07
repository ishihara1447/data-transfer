-- CDC 検証フェーズ: 整合性チェック・ラグ計測スクリプト
-- cdc_schema.pkg_cdc_snapshot.verify_snapshot の SQL 版
-- フルテキスト比較・CDC ラグ・エラーサマリを出力する
-- 実行ユーザー: SYS AS SYSDBA
-- 実行対象: oracle-src XEPDB1 (localhost:1521/XEPDB1)

WHENEVER SQLERROR CONTINUE
WHENEVER OSERROR  CONTINUE
SET ECHO OFF
SET FEEDBACK OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 50

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

-- ============================================================
-- Section 1: CDC 実行状態
-- ============================================================
PROMPT
PROMPT ============================================================
PROMPT Section 1: CDC State
PROMPT ============================================================

SELECT
    state_id,
    run_name,
    snapshot_scn,
    last_applied_scn,
    status,
    TO_CHAR(started_at,  'YYYY-MM-DD HH24:MI:SS') AS started_at,
    TO_CHAR(last_run_at, 'YYYY-MM-DD HH24:MI:SS') AS last_run_at,
    SUBSTR(error_message, 1, 80)                   AS error_message
FROM cdc_schema.cdc_state
ORDER BY state_id;

-- ============================================================
-- Section 2: CDC ラグ（SCN 差）
-- ============================================================
PROMPT
PROMPT ============================================================
PROMPT Section 2: CDC Lag (current_scn - last_applied_scn)
PROMPT ============================================================

SELECT
    s.run_name,
    d.CURRENT_SCN                                   AS current_scn,
    NVL(s.last_applied_scn, s.snapshot_scn)         AS last_applied_scn,
    d.CURRENT_SCN - NVL(s.last_applied_scn, s.snapshot_scn) AS lag_scn,
    s.status
FROM cdc_schema.cdc_state s, V$DATABASE d
ORDER BY s.state_id;

-- ============================================================
-- Section 3: テーブル件数比較 (src vs tgt)
-- ============================================================
PROMPT
PROMPT ============================================================
PROMPT Section 3: Row Count Comparison (src vs tgt)
PROMPT ============================================================

SELECT 'REGIONS'               AS table_name,
       (SELECT COUNT(*) FROM src_schema.regions)              AS src_count,
       (SELECT COUNT(*) FROM tgt_schema.regions@tgt_db)       AS tgt_count
FROM DUAL
UNION ALL
SELECT 'PRODUCT_CATEGORIES',
       (SELECT COUNT(*) FROM src_schema.product_categories),
       (SELECT COUNT(*) FROM tgt_schema.product_categories@tgt_db)
FROM DUAL
UNION ALL
SELECT 'CUSTOMERS',
       (SELECT COUNT(*) FROM src_schema.customers),
       (SELECT COUNT(*) FROM tgt_schema.customers@tgt_db)
FROM DUAL
UNION ALL
SELECT 'PRODUCTS',
       (SELECT COUNT(*) FROM src_schema.products),
       (SELECT COUNT(*) FROM tgt_schema.products@tgt_db)
FROM DUAL
UNION ALL
SELECT 'ORDERS',
       (SELECT COUNT(*) FROM src_schema.orders),
       (SELECT COUNT(*) FROM tgt_schema.orders@tgt_db)
FROM DUAL
UNION ALL
SELECT 'ORDER_ITEMS',
       (SELECT COUNT(*) FROM src_schema.order_items),
       (SELECT COUNT(*) FROM tgt_schema.order_items@tgt_db)
FROM DUAL
UNION ALL
SELECT 'CUSTOMER_CONTRACTS',
       (SELECT COUNT(*) FROM src_schema.customer_contracts),
       (SELECT COUNT(*) FROM tgt_schema.customer_contracts@tgt_db)
FROM DUAL
UNION ALL
SELECT 'ORDER_STATUS_HISTORY',
       (SELECT COUNT(*) FROM src_schema.order_status_history),
       (SELECT COUNT(*) FROM tgt_schema.order_status_history@tgt_db)
FROM DUAL
UNION ALL
SELECT 'PRICE_HISTORY',
       (SELECT COUNT(*) FROM src_schema.price_history),
       (SELECT COUNT(*) FROM tgt_schema.price_history@tgt_db)
FROM DUAL
UNION ALL
SELECT 'SYSTEM_EVENTS',
       (SELECT COUNT(*) FROM src_schema.system_events),
       (SELECT COUNT(*) FROM tgt_schema.system_events@tgt_db)
FROM DUAL;

-- ============================================================
-- Section 4: CDC エラーサマリ (直近 50 件)
-- ============================================================
PROMPT
PROMPT ============================================================
PROMPT Section 4: CDC Error Summary (last 50)
PROMPT ============================================================

SELECT
    error_id,
    state_id,
    scn,
    table_name,
    operation,
    error_code,
    SUBSTR(error_message, 1, 80)              AS error_message,
    lob_fallback,
    TO_CHAR(occurred_at, 'YYYY-MM-DD HH24:MI:SS') AS occurred_at
FROM (
    SELECT * FROM cdc_schema.cdc_error_log
    ORDER BY error_id DESC
)
WHERE ROWNUM <= 50;

-- ============================================================
-- Section 5: LOB フォールバック統計
-- ============================================================
PROMPT
PROMPT ============================================================
PROMPT Section 5: LOB Fallback Statistics
PROMPT ============================================================

SELECT
    table_name,
    operation,
    COUNT(*)                  AS total,
    SUM(lob_fallback)         AS lob_fallback_count,
    MIN(occurred_at)          AS first_occurred,
    MAX(occurred_at)          AS last_occurred
FROM cdc_schema.cdc_error_log
GROUP BY table_name, operation
ORDER BY table_name, operation;

-- ============================================================
-- Section 6: CUSTOMERS PK 不一致チェック (サンプル)
-- ============================================================
PROMPT
PROMPT ============================================================
PROMPT Section 6: CUSTOMERS PK Diff (src - tgt, max 20 rows)
PROMPT ============================================================

SELECT customer_id, 'IN_SRC_ONLY' AS diff_type
FROM (
    SELECT customer_id FROM src_schema.customers
    MINUS
    SELECT customer_id FROM tgt_schema.customers@tgt_db
)
WHERE ROWNUM <= 20
UNION ALL
SELECT customer_id, 'IN_TGT_ONLY'
FROM (
    SELECT customer_id FROM tgt_schema.customers@tgt_db
    MINUS
    SELECT customer_id FROM src_schema.customers
)
WHERE ROWNUM <= 20;

PROMPT
PROMPT Verification completed.
EXIT;
