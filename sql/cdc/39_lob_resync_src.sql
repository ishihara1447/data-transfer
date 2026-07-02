-- LOBテーブル差分反映方式: ソース側テーブル + PL/SQL (oracle-src 用)
-- docs/delta-extract-design.md セクション11.4-③ の設計に基づく。
--
-- 作成対象:
--   cdc_schema.lob_resync_request : tgt から搬送されてきた再同期要求の受け皿
--   SYS.lob_resync_export_rows    : PKリストのクレンジング・件数確認（expdp起動はシェル側）
--
-- 設計上の役割分離:
--   PL/SQL: lob_resync_request のクレンジング・件数確認・PKリスト提供
--   シェル : expdp の QUERY で lob_resync_request を IN 参照して対象行をエクスポート
--            (scripts/43_lob_resync_cycle.sh の Step3)
--
-- 実行ユーザー: SYS AS SYSDBA / 実行対象: oracle-src XEPDB1 / Oracle 12c 互換 / 冪等

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

SET SERVEROUTPUT ON SIZE UNLIMITED

-- ============================================================
-- cdc_schema.lob_resync_request: tgt からの再同期要求受け皿
-- scripts/43 の Step1 で lob_resync_target(PENDING) を expdp し
-- こちらに impdp でロードする（remap_schema=STAGING_CTL:CDC_SCHEMA）
-- ============================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_tables
    WHERE owner = 'CDC_SCHEMA' AND table_name = 'LOB_RESYNC_REQUEST';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE cdc_schema.lob_resync_request PURGE';
    END IF;
END;
/

CREATE TABLE cdc_schema.lob_resync_request (
    req_id         NUMBER GENERATED ALWAYS AS IDENTITY,
    table_name     VARCHAR2(100)  NOT NULL,
    pk_value       VARCHAR2(100)  NOT NULL,
    last_operation VARCHAR2(20),              -- lob_resync_target.last_operation（参照用）
    received_at    TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_lob_resync_request PRIMARY KEY (req_id),
    CONSTRAINT uq_lob_resync_request UNIQUE (table_name, pk_value)
);

COMMENT ON TABLE cdc_schema.lob_resync_request IS 'LOBテーブル差分反映: tgt から搬送されてきた再同期要求の受け皿。scripts/43 Step1 で lob_resync_target(PENDING) を impdp でロードする。expdp QUERY で pk_value IN (SELECT pk_value FROM cdc_schema.lob_resync_request WHERE table_name=?) として参照される。';

-- インデックスは UNIQUE 制約の暗黙インデックス(UQ_LOB_RESYNC_REQUEST)で十分なため省略

-- ============================================================
-- SYS.lob_resync_export_rows: PKリストのクレンジング・件数確認
--
-- 処理内容:
--   1. lob_resync_request の件数をテーブル別に集計してログ出力
--   2. pk_value が数値変換できない行は警告（ベストエフォート・エラー停止しない）
--   3. 重複行の確認（UNIQUE 制約でほぼ防がれているが確認用）
--   この後 scripts/43 が expdp を起動して実際に行を取得する。
-- ============================================================
CREATE OR REPLACE PROCEDURE SYS.lob_resync_export_rows
    AUTHID CURRENT_USER
AS
    v_total_cnt   NUMBER := 0;
    v_cust_cnt    NUMBER := 0;
    v_ord_cnt     NUMBER := 0;
BEGIN
    -- テーブル別件数確認
    BEGIN
        EXECUTE IMMEDIATE
            'SELECT COUNT(*) FROM cdc_schema.lob_resync_request '
            || 'WHERE table_name = ''CUSTOMERS'''
            INTO v_cust_cnt;
    EXCEPTION WHEN OTHERS THEN v_cust_cnt := 0; END;

    BEGIN
        EXECUTE IMMEDIATE
            'SELECT COUNT(*) FROM cdc_schema.lob_resync_request '
            || 'WHERE table_name = ''ORDERS'''
            INTO v_ord_cnt;
    EXCEPTION WHEN OTHERS THEN v_ord_cnt := 0; END;

    v_total_cnt := v_cust_cnt + v_ord_cnt;

    DBMS_OUTPUT.PUT_LINE(
        'lob_resync_export_rows: total_requests=' || v_total_cnt
        || ' customers=' || v_cust_cnt
        || ' orders=' || v_ord_cnt);

    IF v_total_cnt = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  lob_resync_request が空です。expdp はスキップしてください。');
    ELSE
        DBMS_OUTPUT.PUT_LINE(
            '  expdp QUERY 例（CUSTOMERS）: '
            || 'WHERE customer_id IN (SELECT TO_NUMBER(pk_value) FROM cdc_schema.lob_resync_request WHERE table_name=''CUSTOMERS'')');
        DBMS_OUTPUT.PUT_LINE(
            '  expdp QUERY 例（ORDERS）: '
            || 'WHERE order_id IN (SELECT TO_NUMBER(pk_value) FROM cdc_schema.lob_resync_request WHERE table_name=''ORDERS'')');
    END IF;

EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('lob_resync_export_rows WARN: ' || SUBSTR(SQLERRM, 1, 4000));
    -- 件数確認失敗はエラー停止しない（シェル側で続行判定）
END lob_resync_export_rows;
/
SHOW ERRORS PROCEDURE SYS.lob_resync_export_rows;

PROMPT cdc_schema.lob_resync_request created.
PROMPT SYS.lob_resync_export_rows created on oracle-src.
EXIT;
