-- 内容検証フェーズ (2a-tgt + 2b + 段階1): oracle-tgt 用
--
-- プロシージャ 1: SYS.verify_content_stg
--   STAGING_SCHEMA のハッシュ・集計サマリを DBMS_OUTPUT で出力する。
--   フォーマット（48_ の CONTENT_SRC と同形式）:
--     CONTENT_STG: table=<TABLE> rows=<n> scalar_hash=<sum> lob_len_sum=<n> lob_head_hash=<sum>
--   ★ハッシュ計算式は 48_ と完全に同じにする（NLS 固定・NULL トークン統一）。
--
-- プロシージャ 2: SYS.verify_business_aggregates
--   STAGING ↔ TARGET の業務不変量を JOIN 照合し PASS/FAIL を出力する。
--   フォーマット: BIZAGG: check=<NAME> result=PASS|FAIL detail=<説明>
--
-- プロシージャ 3: SYS.verify_row_counts_tgt
--   段階1の形式検証（行数突き合わせ）。STAGING と TARGET の行数を出力。
--   フォーマット: ROWCOUNT_TGT: table=<TABLE> stg=<n> tgt=<n> match=Y|N
--
-- 業務不変量（2b）の根拠（42_pkg_transform.sql より):
--   orders   : net_amount = total_amount - tax_amount (全行)
--              SUM(total_amount): STAGING と TARGET で一致
--              件数: STG.orders 件数 = TGT.orders 件数
--   customers: 件数: STG.customers = TGT.customers
--              is_active 分布: status='ACTIVE' → is_active='Y', else 'N'
--              (41_pkg_transform_util.status_to_active_flag の仕様)
--   order_enriched: 件数 = STG.orders 件数 (HEAVY 変換は 1行→1行)
--                   SUM(total_amount) = SUM(orders.total_amount)
--                   参照整合: order_enriched.customer_id が customers に存在 (孤児なし)
--   regions  : PASS_THROUGH。scalar_hash 一致（同一 DB なので直接比較）
--              + 件数一致
--
-- 未検査項目 (業務確認が必要):
--   - orders.lead_time_days の算出精度（delivery_date - order_date）
--   - customers.phone_normalized の正規化結果（REGEXP_REPLACE('[^0-9]','')）
--   - order_enriched.postal_code / prefecture / city の REGEXP 解析精度
--   - order_enriched.status_label と code_mapping の一致（マッピング外値の UNKNOWN 処理）
--   - LOB 完全ハッシュ（lob_head_hash は先頭 2000byte/char のみ。完全保証ではない）
--
-- 実行ユーザー: SYS AS SYSDBA / 実行対象: oracle-tgt XEPDB1 / Oracle 12c 互換
-- 冪等: CREATE OR REPLACE のため再実行可

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

SET SERVEROUTPUT ON SIZE UNLIMITED

-- ============================================================
-- Procedure 1: verify_content_stg
--   STAGING_SCHEMA のハッシュサマリ出力 (2a-tgt 側)
-- ============================================================
CREATE OR REPLACE PROCEDURE SYS.verify_content_stg(
    p_verbose IN VARCHAR2 DEFAULT 'N'
)
    AUTHID CURRENT_USER
AS
    v_rows        NUMBER;
    v_scalar_hash NUMBER;
    v_lob_len     NUMBER;
    v_lob_head    NUMBER;

    PROCEDURE emit(p_table VARCHAR2, p_rows NUMBER,
                   p_scalar_hash NUMBER, p_lob_len NUMBER, p_lob_head NUMBER) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(
            'CONTENT_STG: table=' || p_table
            || ' rows='          || NVL(TO_CHAR(p_rows),       '0')
            || ' scalar_hash='   || NVL(TO_CHAR(p_scalar_hash),'0')
            || ' lob_len_sum='   || NVL(TO_CHAR(p_lob_len),    '0')
            || ' lob_head_hash=' || NVL(TO_CHAR(p_lob_head),   '0')
        );
        IF p_verbose = 'Y' THEN
            DBMS_OUTPUT.PUT_LINE(
                '  [verbose] table=' || p_table
                || ' rows=' || p_rows
                || ' scalar_hash=' || p_scalar_hash
            );
        END IF;
    END emit;

BEGIN
    DBMS_OUTPUT.PUT_LINE('verify_content_stg: started at '
        || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS'));

    -- ============================================================
    -- 1. STAGING.REGIONS (LOB なし)
    --    ★ hash 式を 48_(SRC) と完全同一にする
    --      STAGING は synced_at 列が追加されているが、SRC と突き合わせるため
    --      SRC と共通の列のみを使う（SRC と同一の列リストで計算）。
    --      synced_at は STAGING 固有列で SRC には存在しないためハッシュに含めない。
    -- ============================================================
    SELECT
        COUNT(*),
        NVL(SUM(ORA_HASH(
            NVL(TO_CHAR(region_id),          '∅') || '|' ||
            NVL(region_code,                 '∅') || '|' ||
            NVL(region_name,                 '∅') || '|' ||
            NVL(TO_CHAR(parent_region_id),   '∅') || '|' ||
            NVL(TO_CHAR(display_order),      '∅') || '|' ||
            NVL(TO_CHAR(is_active),          '∅') || '|' ||
            NVL(TO_CHAR(created_at, 'YYYYMMDDHH24MISS'), '∅') || '|' ||
            NVL(TO_CHAR(updated_at, 'YYYYMMDDHH24MISS'), '∅')
        )), 0),
        0,
        0
    INTO v_rows, v_scalar_hash, v_lob_len, v_lob_head
    FROM staging_schema.regions;
    emit('REGIONS', v_rows, v_scalar_hash, v_lob_len, v_lob_head);

    -- ============================================================
    -- 2. STAGING.CUSTOMERS (LOB あり)
    --    ★ SRC と同一の列リスト（synced_at 除く）
    -- ============================================================
    SELECT
        COUNT(*),
        NVL(SUM(ORA_HASH(
            NVL(TO_CHAR(customer_id),        '∅') || '|' ||
            NVL(customer_code,               '∅') || '|' ||
            NVL(company_name,                '∅') || '|' ||
            NVL(last_name,                   '∅') || '|' ||
            NVL(first_name,                  '∅') || '|' ||
            NVL(email,                       '∅') || '|' ||
            NVL(phone,                       '∅') || '|' ||
            NVL(TO_CHAR(region_id),          '∅') || '|' ||
            NVL(TO_CHAR(credit_limit),       '∅') || '|' ||
            NVL(status,                      '∅') || '|' ||
            NVL(TO_CHAR(created_at, 'YYYYMMDDHH24MISS'), '∅') || '|' ||
            NVL(TO_CHAR(updated_at, 'YYYYMMDDHH24MISS'), '∅') || '|' ||
            NVL(created_by,                  '∅')
        )), 0),
        NVL(SUM(NVL(DBMS_LOB.GETLENGTH(avatar_image), 0) +
                NVL(DBMS_LOB.GETLENGTH(remarks),       0)), 0),
        NVL(SUM(ORA_HASH(DBMS_LOB.SUBSTR(avatar_image, 2000, 1)) +
                ORA_HASH(DBMS_LOB.SUBSTR(remarks,       2000, 1))), 0)
    INTO v_rows, v_scalar_hash, v_lob_len, v_lob_head
    FROM staging_schema.customers;
    emit('CUSTOMERS', v_rows, v_scalar_hash, v_lob_len, v_lob_head);

    -- ============================================================
    -- 3. STAGING.ORDERS (LOB あり: shipping_address CLOB)
    --    ★ SRC と同一の列リスト（synced_at 除く）
    -- ============================================================
    SELECT
        COUNT(*),
        NVL(SUM(ORA_HASH(
            NVL(TO_CHAR(order_id),           '∅') || '|' ||
            NVL(order_no,                    '∅') || '|' ||
            NVL(TO_CHAR(customer_id),        '∅') || '|' ||
            NVL(TO_CHAR(shipping_region_id), '∅') || '|' ||
            NVL(status,                      '∅') || '|' ||
            NVL(TO_CHAR(order_date, 'YYYYMMDD'),   '∅') || '|' ||
            NVL(TO_CHAR(ship_date,  'YYYYMMDD'),   '∅') || '|' ||
            NVL(TO_CHAR(delivery_date, 'YYYYMMDD'),'∅') || '|' ||
            NVL(TO_CHAR(total_amount),       '∅') || '|' ||
            NVL(TO_CHAR(tax_amount),         '∅') || '|' ||
            NVL(notes,                       '∅') || '|' ||
            NVL(TO_CHAR(created_at, 'YYYYMMDDHH24MISS'), '∅') || '|' ||
            NVL(TO_CHAR(updated_at, 'YYYYMMDDHH24MISS'), '∅')
        )), 0),
        NVL(SUM(NVL(DBMS_LOB.GETLENGTH(shipping_address), 0)), 0),
        NVL(SUM(ORA_HASH(DBMS_LOB.SUBSTR(shipping_address, 2000, 1))), 0)
    INTO v_rows, v_scalar_hash, v_lob_len, v_lob_head
    FROM staging_schema.orders;
    emit('ORDERS', v_rows, v_scalar_hash, v_lob_len, v_lob_head);

    DBMS_OUTPUT.PUT_LINE('verify_content_stg: completed');

EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('verify_content_stg: FAILED err=' || SUBSTR(SQLERRM,1,3900));
    RAISE;
END verify_content_stg;
/
SHOW ERRORS PROCEDURE SYS.verify_content_stg;

-- ============================================================
-- Procedure 2: verify_business_aggregates
--   STAGING ↔ TARGET 業務集計 JOIN 照合 (2b)
--   同一 DB(oracle-tgt) なので PL/SQL で直接 JOIN 可。
-- ============================================================
CREATE OR REPLACE PROCEDURE SYS.verify_business_aggregates(
    p_verbose IN VARCHAR2 DEFAULT 'N'
)
    AUTHID CURRENT_USER
AS
    -- 数値比較用（ローカルプロシージャより先に宣言が必要）
    v_n1 NUMBER; v_n2 NUMBER; v_n3 NUMBER;
    v_r  VARCHAR2(10);
    v_d  VARCHAR2(500);

    PROCEDURE emit_check(p_check VARCHAR2, p_result VARCHAR2, p_detail VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(
            'BIZAGG: check=' || p_check
            || ' result=' || p_result
            || ' detail=' || SUBSTR(p_detail, 1, 300)
        );
    END emit_check;

BEGIN
    DBMS_OUTPUT.PUT_LINE('verify_business_aggregates: started at '
        || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS'));

    -- ============================================================
    -- CHK-01: orders 件数 (STG.orders = TGT.orders)
    -- ============================================================
    SELECT COUNT(*) INTO v_n1 FROM staging_schema.orders;
    SELECT COUNT(*) INTO v_n2 FROM target_schema.orders;
    v_r := CASE WHEN v_n1 = v_n2 THEN 'PASS' ELSE 'FAIL' END;
    v_d := 'stg_orders=' || v_n1 || ' tgt_orders=' || v_n2;
    emit_check('ORDERS_COUNT', v_r, v_d);

    -- ============================================================
    -- CHK-02: orders SUM(total_amount) 一致
    --   変換は total_amount をそのまま持ち越す（42_ LIGHT 変換の仕様）。
    -- ============================================================
    SELECT NVL(SUM(total_amount),0) INTO v_n1 FROM staging_schema.orders;
    SELECT NVL(SUM(total_amount),0) INTO v_n2 FROM target_schema.orders;
    v_r := CASE WHEN v_n1 = v_n2 THEN 'PASS' ELSE 'FAIL' END;
    v_d := 'stg_sum=' || v_n1 || ' tgt_sum=' || v_n2;
    emit_check('ORDERS_TOTAL_AMOUNT_SUM', v_r, v_d);

    -- ============================================================
    -- CHK-03: orders 全行 net_amount = total_amount - tax_amount
    --   42_ transform_orders: net_amount = s.total_amount - s.tax_amount
    --   全行でこの等式が成立するか確認（不成立行数が 0 なら PASS）。
    -- ============================================================
    SELECT COUNT(*) INTO v_n1
    FROM target_schema.orders
    WHERE net_amount <> total_amount - tax_amount;
    v_r := CASE WHEN v_n1 = 0 THEN 'PASS' ELSE 'FAIL' END;
    v_d := 'violation_rows=' || v_n1 || ' (expected 0)';
    emit_check('ORDERS_NET_AMOUNT_INVARIANT', v_r, v_d);

    -- ============================================================
    -- CHK-04: customers 件数 (STG.customers = TGT.customers)
    -- ============================================================
    SELECT COUNT(*) INTO v_n1 FROM staging_schema.customers;
    SELECT COUNT(*) INTO v_n2 FROM target_schema.customers;
    v_r := CASE WHEN v_n1 = v_n2 THEN 'PASS' ELSE 'FAIL' END;
    v_d := 'stg_customers=' || v_n1 || ' tgt_customers=' || v_n2;
    emit_check('CUSTOMERS_COUNT', v_r, v_d);

    -- ============================================================
    -- CHK-05: customers is_active 分布の一致
    --   41_pkg_transform_util.status_to_active_flag:
    --     status='ACTIVE' → is_active='Y', それ以外 → 'N'
    --   STG で status='ACTIVE' の件数 = TGT で is_active='Y' の件数
    -- ============================================================
    SELECT COUNT(*) INTO v_n1 FROM staging_schema.customers WHERE status = 'ACTIVE';
    SELECT COUNT(*) INTO v_n2 FROM target_schema.customers   WHERE is_active = 'Y';
    v_r := CASE WHEN v_n1 = v_n2 THEN 'PASS' ELSE 'FAIL' END;
    v_d := 'stg_active_status=' || v_n1 || ' tgt_is_active_Y=' || v_n2;
    emit_check('CUSTOMERS_IS_ACTIVE_DIST', v_r, v_d);

    -- ============================================================
    -- CHK-06: order_enriched 件数 = STG.orders 件数
    --   42_ HEAVY 変換は orders を 1行→1行で出力する
    -- ============================================================
    SELECT COUNT(*) INTO v_n1 FROM staging_schema.orders;
    SELECT COUNT(*) INTO v_n2 FROM target_schema.order_enriched;
    v_r := CASE WHEN v_n1 = v_n2 THEN 'PASS' ELSE 'FAIL' END;
    v_d := 'stg_orders=' || v_n1 || ' tgt_order_enriched=' || v_n2;
    emit_check('ORDER_ENRICHED_COUNT', v_r, v_d);

    -- ============================================================
    -- CHK-07: order_enriched SUM(total_amount) = STG.orders SUM(total_amount)
    --   42_: HEAVY 変換で o.total_amount をそのまま持ち越す
    -- ============================================================
    SELECT NVL(SUM(total_amount),0) INTO v_n1 FROM staging_schema.orders;
    SELECT NVL(SUM(total_amount),0) INTO v_n2 FROM target_schema.order_enriched;
    v_r := CASE WHEN v_n1 = v_n2 THEN 'PASS' ELSE 'FAIL' END;
    v_d := 'stg_sum=' || v_n1 || ' enriched_sum=' || v_n2;
    emit_check('ORDER_ENRICHED_TOTAL_SUM', v_r, v_d);

    -- ============================================================
    -- CHK-08: order_enriched 参照整合性（孤児なし）
    --   order_enriched.customer_id が customers に存在しない行 = 0
    -- ============================================================
    SELECT COUNT(*) INTO v_n1
    FROM target_schema.order_enriched e
    WHERE NOT EXISTS (
        SELECT 1 FROM target_schema.customers c WHERE c.customer_id = e.customer_id
    );
    v_r := CASE WHEN v_n1 = 0 THEN 'PASS' ELSE 'FAIL' END;
    v_d := 'orphan_rows=' || v_n1 || ' (expected 0; order_enriched.customer_id not in customers)';
    emit_check('ORDER_ENRICHED_REF_INTEGRITY', v_r, v_d);

    -- ============================================================
    -- CHK-09: regions 件数 (STG.regions = TGT.regions)
    --   PASS_THROUGH のため件数一致が基本保証
    -- ============================================================
    SELECT COUNT(*) INTO v_n1 FROM staging_schema.regions;
    SELECT COUNT(*) INTO v_n2 FROM target_schema.regions;
    v_r := CASE WHEN v_n1 = v_n2 THEN 'PASS' ELSE 'FAIL' END;
    v_d := 'stg_regions=' || v_n1 || ' tgt_regions=' || v_n2;
    emit_check('REGIONS_COUNT', v_r, v_d);

    -- ============================================================
    -- CHK-10: regions scalar_hash 一致（PASS_THROUGH・同一 DB で直接比較）
    --   PASS_THROUGH は変換なし 1:1 コピーなので scalar_hash が一致すべき。
    --   STAGING の hash 計算: SRC/STG hash と同じ列リスト（SRC 定義に準拠）。
    --   TARGET.regions は STAGING から LOB なし共通列のみコピー（synced_at 除く）。
    --   ★ TARGET には synced_at がないため STG 側も synced_at を除いて計算する。
    -- ============================================================
    SELECT NVL(SUM(ORA_HASH(
        NVL(TO_CHAR(region_id),          '∅') || '|' ||
        NVL(region_code,                 '∅') || '|' ||
        NVL(region_name,                 '∅') || '|' ||
        NVL(TO_CHAR(parent_region_id),   '∅') || '|' ||
        NVL(TO_CHAR(display_order),      '∅') || '|' ||
        NVL(TO_CHAR(is_active),          '∅') || '|' ||
        NVL(TO_CHAR(created_at, 'YYYYMMDDHH24MISS'), '∅') || '|' ||
        NVL(TO_CHAR(updated_at, 'YYYYMMDDHH24MISS'), '∅')
    )), 0) INTO v_n1 FROM staging_schema.regions;

    SELECT NVL(SUM(ORA_HASH(
        NVL(TO_CHAR(region_id),          '∅') || '|' ||
        NVL(region_code,                 '∅') || '|' ||
        NVL(region_name,                 '∅') || '|' ||
        NVL(TO_CHAR(parent_region_id),   '∅') || '|' ||
        NVL(TO_CHAR(display_order),      '∅') || '|' ||
        NVL(TO_CHAR(is_active),          '∅') || '|' ||
        NVL(TO_CHAR(created_at, 'YYYYMMDDHH24MISS'), '∅') || '|' ||
        NVL(TO_CHAR(updated_at, 'YYYYMMDDHH24MISS'), '∅')
    )), 0) INTO v_n2 FROM target_schema.regions;

    v_r := CASE WHEN v_n1 = v_n2 THEN 'PASS' ELSE 'FAIL' END;
    v_d := 'stg_hash=' || v_n1 || ' tgt_hash=' || v_n2;
    emit_check('REGIONS_SCALAR_HASH', v_r, v_d);

    DBMS_OUTPUT.PUT_LINE('verify_business_aggregates: completed');

    -- 未検査項目の注記（人間可読）
    DBMS_OUTPUT.PUT_LINE(
        'NOTE: unchecked - lead_time_days_precision/phone_normalized'
        || '/postal_code-prefecture-city(REGEXP)/status_label(code_mapping)'
        || '/LOB_full_hash(head_2000bytes_only)'
    );

EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('verify_business_aggregates: FAILED err=' || SUBSTR(SQLERRM,1,3900));
    RAISE;
END verify_business_aggregates;
/
SHOW ERRORS PROCEDURE SYS.verify_business_aggregates;

-- ============================================================
-- Procedure 3: verify_row_counts_tgt
--   段階1: STAGING / TARGET 行数突き合わせ出力
--   フォーマット: ROWCOUNT_TGT: table=<T> stg=<n> tgt=<n> match=Y|N
-- ============================================================
CREATE OR REPLACE PROCEDURE SYS.verify_row_counts_tgt(
    p_verbose IN VARCHAR2 DEFAULT 'N'
)
    AUTHID CURRENT_USER
AS
    v_stg NUMBER; v_tgt NUMBER;

    PROCEDURE emit(p_table VARCHAR2, p_stg NUMBER, p_tgt NUMBER) IS
        v_match CHAR(1) := CASE WHEN p_stg = p_tgt THEN 'Y' ELSE 'N' END;
    BEGIN
        DBMS_OUTPUT.PUT_LINE(
            'ROWCOUNT_TGT: table=' || p_table
            || ' stg='   || NVL(TO_CHAR(p_stg), '0')
            || ' tgt='   || NVL(TO_CHAR(p_tgt), '0')
            || ' match=' || v_match
        );
    END emit;

BEGIN
    DBMS_OUTPUT.PUT_LINE('verify_row_counts_tgt: started at '
        || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS'));

    SELECT COUNT(*) INTO v_stg FROM staging_schema.regions;
    SELECT COUNT(*) INTO v_tgt FROM target_schema.regions;
    emit('REGIONS', v_stg, v_tgt);

    SELECT COUNT(*) INTO v_stg FROM staging_schema.customers;
    SELECT COUNT(*) INTO v_tgt FROM target_schema.customers;
    emit('CUSTOMERS', v_stg, v_tgt);

    SELECT COUNT(*) INTO v_stg FROM staging_schema.orders;
    SELECT COUNT(*) INTO v_tgt FROM target_schema.orders;
    emit('ORDERS', v_stg, v_tgt);

    -- order_enriched は orders 件数との比較
    SELECT COUNT(*) INTO v_stg FROM staging_schema.orders;
    SELECT COUNT(*) INTO v_tgt FROM target_schema.order_enriched;
    emit('ORDER_ENRICHED', v_stg, v_tgt);

    DBMS_OUTPUT.PUT_LINE('verify_row_counts_tgt: completed');

EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('verify_row_counts_tgt: FAILED err=' || SUBSTR(SQLERRM,1,3900));
    RAISE;
END verify_row_counts_tgt;
/
SHOW ERRORS PROCEDURE SYS.verify_row_counts_tgt;

PROMPT SYS.verify_content_stg / verify_business_aggregates / verify_row_counts_tgt created on oracle-tgt.
EXIT;
