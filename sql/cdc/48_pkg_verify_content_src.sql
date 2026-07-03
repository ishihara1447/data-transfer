-- 内容検証フェーズ (2a-src): SYS.verify_content_src プロシージャ (oracle-src 用)
-- SRC_SCHEMA 各テーブルのハッシュ・集計サマリを DBMS_OUTPUT で出力する。
-- 判定は行わない（値の算出のみ）。シェルが tgt 側と突き合わせる。
--
-- 出力フォーマット（機械可読・1テーブル=1行）:
--   CONTENT_SRC: table=<TABLE> rows=<n> scalar_hash=<sum> lob_len_sum=<n> lob_head_hash=<sum>
--
-- ハッシュ方式:
--   scalar 列: 各行を NVL(TO_CHAR(col,'書式'),'∅') で正規化し連結、
--              ORA_HASH(連結文字列) を SUM（順序非依存集約。SUM は正確には加算値）。
--              12c 互換: ORA_HASH(string) は 12c で利用可。
--   LOB 列    : DBMS_LOB.GETLENGTH + DBMS_LOB.SUBSTR(lob,2000,1) の ORA_HASH。
--              完全一致保証ではなく軽量チェック（先頭 2000 byte/char のみ）。
--              LOB が NULL の場合は長さ=0、ハッシュは ORA_HASH(NULL)=0 として扱う。
--
-- NLS 依存回避:
--   DATE/TIMESTAMP は TO_CHAR で 'YYYYMMDDHH24MISS' に固定する。
--   NUMBER は TO_CHAR(v) で標準表現に統一する。
--   これを省くと NLS 設定差で別 DB と常時不一致になる。
--
-- 対象テーブル: SRC_SCHEMA.REGIONS / CUSTOMERS / ORDERS（変換パイプラインの対象3表）
--   staging_schema と同一構造で delta_apply が置換適用する対象のみ検証対象とする。
--
-- 実行ユーザー: SYS AS SYSDBA / 実行対象: oracle-src XEPDB1 / Oracle 12c 互換
-- 冪等: CREATE OR REPLACE のため再実行可

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

SET SERVEROUTPUT ON SIZE UNLIMITED

CREATE OR REPLACE PROCEDURE SYS.verify_content_src(
    p_verbose IN VARCHAR2 DEFAULT 'N'
)
    AUTHID CURRENT_USER
AS
    -- ハッシュ計算用の変数（ローカルプロシージャより先に宣言が必要）
    v_rows        NUMBER;
    v_scalar_hash NUMBER;
    v_lob_len     NUMBER;
    v_lob_head    NUMBER;

    -- 各テーブルの出力行を組み立てて DBMS_OUTPUT へ書く
    PROCEDURE emit(p_table VARCHAR2, p_rows NUMBER,
                   p_scalar_hash NUMBER, p_lob_len NUMBER, p_lob_head NUMBER) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(
            'CONTENT_SRC: table=' || p_table
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
    DBMS_OUTPUT.PUT_LINE('verify_content_src: started at '
        || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS'));

    -- ============================================================
    -- 1. REGIONS (LOB なし)
    --    scalar 列: region_id, region_code, region_name,
    --               parent_region_id, display_order, is_active,
    --               created_at, updated_at
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
        0,  -- LOB なし
        0   -- LOB なし
    INTO v_rows, v_scalar_hash, v_lob_len, v_lob_head
    FROM src_schema.regions;
    emit('REGIONS', v_rows, v_scalar_hash, v_lob_len, v_lob_head);

    -- ============================================================
    -- 2. CUSTOMERS (LOB あり: avatar_image BLOB, remarks CLOB)
    --    scalar 列: customer_id, customer_code, company_name,
    --               last_name, first_name, email, phone, region_id,
    --               credit_limit, status, created_at, updated_at, created_by
    --    LOB  列 : avatar_image, remarks
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
        -- LOB: GETLENGTH の SUM（NULL は 0 換算）
        NVL(SUM(NVL(DBMS_LOB.GETLENGTH(avatar_image), 0) +
                NVL(DBMS_LOB.GETLENGTH(remarks),       0)), 0),
        -- LOB 先頭 2000byte/char の ORA_HASH を SUM
        NVL(SUM(ORA_HASH(DBMS_LOB.SUBSTR(avatar_image, 2000, 1)) +
                ORA_HASH(DBMS_LOB.SUBSTR(remarks,       2000, 1))), 0)
    INTO v_rows, v_scalar_hash, v_lob_len, v_lob_head
    FROM src_schema.customers;
    emit('CUSTOMERS', v_rows, v_scalar_hash, v_lob_len, v_lob_head);

    -- ============================================================
    -- 3. ORDERS (LOB あり: shipping_address CLOB)
    --    scalar 列: order_id, order_no, customer_id, shipping_region_id,
    --               status, order_date, ship_date, delivery_date,
    --               total_amount, tax_amount, notes, created_at, updated_at
    --    LOB  列 : shipping_address CLOB
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
    FROM src_schema.orders;
    emit('ORDERS', v_rows, v_scalar_hash, v_lob_len, v_lob_head);

    DBMS_OUTPUT.PUT_LINE('verify_content_src: completed');
    -- NOTE: LOB 検証は先頭 2000 byte/char のみのため完全一致保証ではない。
    --       LOB の完全ハッシュは DBMS_CRYPTO.HASH 等を要するが I/O コストが高い
    --       ため本検証では軽量チェック（lob_len_sum + lob_head_hash）に留める。

EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('verify_content_src: FAILED err=' || SUBSTR(SQLERRM,1,3900));
    RAISE;
END verify_content_src;
/
SHOW ERRORS PROCEDURE SYS.verify_content_src;

PROMPT SYS.verify_content_src created on oracle-src.
EXIT;
