-- Phase 2: pkg_transform_util — 共有変換関数（決定論的・副作用なし）
-- 設計: docs/phase2-transform-design.md 5.1 / 6.1
--   すべて PURE（入力のみで出力が決まる）。SYSDATE/RANDOM 等の非決定論的要素を含めない。
-- 実行ユーザー: SYS AS SYSDBA / 所有: LOG_SCHEMA / 対象: oracle-tgt XEPDB1
-- Oracle 12c 互換（REGEXP_REPLACE / TO_DATE / CASE）

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

CREATE OR REPLACE PACKAGE log_schema.pkg_transform_util AS
    -- 文字列(YYYYMMDD等)→DATE。不正値は NULL（決定論的）。
    FUNCTION safe_to_date(p_str IN VARCHAR2, p_fmt IN VARCHAR2 DEFAULT 'YYYYMMDD') RETURN DATE;
    -- 文字列→NUMBER。不正値は NULL。
    FUNCTION safe_to_number(p_str IN VARCHAR2) RETURN NUMBER;
    -- 電話番号正規化: 数字以外を除去（ハイフン・空白・括弧を落とす）。
    FUNCTION normalize_phone(p_phone IN VARCHAR2) RETURN VARCHAR2;
    -- 注文ステータス検証: 許可値以外は 'UNKNOWN'。
    FUNCTION validate_order_status(p_status IN VARCHAR2) RETURN VARCHAR2;
    -- 顧客ステータス→稼働フラグ: 'ACTIVE'→'Y'、それ以外→'N'。
    FUNCTION status_to_active_flag(p_status IN VARCHAR2) RETURN CHAR;
END pkg_transform_util;
/
SHOW ERRORS PACKAGE log_schema.pkg_transform_util;

CREATE OR REPLACE PACKAGE BODY log_schema.pkg_transform_util AS

    FUNCTION safe_to_date(p_str IN VARCHAR2, p_fmt IN VARCHAR2 DEFAULT 'YYYYMMDD') RETURN DATE IS
    BEGIN
        IF p_str IS NULL THEN RETURN NULL; END IF;
        -- 8桁数字フォーマット時は厳密に桁チェック（非数字・桁不足を弾く）
        IF p_fmt = 'YYYYMMDD' AND NOT REGEXP_LIKE(p_str, '^[0-9]{8}$') THEN
            RETURN NULL;
        END IF;
        RETURN TO_DATE(p_str, p_fmt);
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;   -- 無効月日（例 20261301）等
    END safe_to_date;

    FUNCTION safe_to_number(p_str IN VARCHAR2) RETURN NUMBER IS
    BEGIN
        IF p_str IS NULL THEN RETURN NULL; END IF;
        RETURN TO_NUMBER(p_str);
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END safe_to_number;

    FUNCTION normalize_phone(p_phone IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_phone IS NULL THEN RETURN NULL; END IF;
        RETURN REGEXP_REPLACE(p_phone, '[^0-9]', '');
    END normalize_phone;

    FUNCTION validate_order_status(p_status IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE
            WHEN p_status IN ('DRAFT','PENDING','CONFIRMED','SHIPPED','DELIVERED','CANCELLED','RETURNED')
                THEN p_status
            ELSE 'UNKNOWN'
        END;
    END validate_order_status;

    FUNCTION status_to_active_flag(p_status IN VARCHAR2) RETURN CHAR IS
    BEGIN
        RETURN CASE WHEN p_status = 'ACTIVE' THEN 'Y' ELSE 'N' END;
    END status_to_active_flag;

END pkg_transform_util;
/
SHOW ERRORS PACKAGE BODY log_schema.pkg_transform_util;

PROMPT pkg_transform_util created on oracle-tgt.
EXIT;
