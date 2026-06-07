-- CDC 検証フェーズ: PKG_CDC_SNAPSHOT パッケージ (oracle-src 用)
-- Phase A: 初期スナップショット（全テーブルを特定 SCN 時点でコピー）
-- Oracle 12c 互換: FETCH FIRST / OFFSET 不使用, EXECUTE IMMEDIATE で動的 SQL
-- 実行ユーザー: SYS AS SYSDBA (cdc_schema パッケージの作成)
-- 実行対象: oracle-src XEPDB1 (localhost:1521/XEPDB1)

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

-- ============================================================
-- Package Specification
-- ============================================================
CREATE OR REPLACE PACKAGE cdc_schema.pkg_cdc_snapshot AS

    -- Phase A メインエントリ: スナップショットを取得して oracle-tgt に全テーブルをコピーする
    -- p_run_name: cdc_state.run_name に登録する識別名
    PROCEDURE take_snapshot(p_run_name IN VARCHAR2);

    -- スナップショット整合性検証: src/tgt の件数と PK 集合を比較してレポート出力
    PROCEDURE verify_snapshot(p_state_id IN NUMBER);

    -- 指定 run_name のスナップショット SCN を返す (Phase B の開始 SCN として使用)
    FUNCTION get_snapshot_scn(p_run_name IN VARCHAR2) RETURN NUMBER;

END pkg_cdc_snapshot;
/
SHOW ERRORS PACKAGE cdc_schema.pkg_cdc_snapshot;

-- ============================================================
-- Package Body
-- ============================================================
CREATE OR REPLACE PACKAGE BODY cdc_schema.pkg_cdc_snapshot AS

    -- ----------------------------------------------------------
    -- copy_single_table: 1テーブルを AS OF SCN で oracle-tgt にコピーする
    -- INSERT INTO tgt_schema.TABLE@tgt_db SELECT * FROM src_schema.TABLE AS OF SCN p_scn
    -- Oracle が LOB データ転送を内部処理する（小〜中サイズ LOB 対応）
    -- ----------------------------------------------------------
    PROCEDURE copy_single_table(
        p_table IN VARCHAR2,
        p_scn   IN NUMBER
    ) IS
        v_sql    VARCHAR2(4000);
        v_count  NUMBER;
    BEGIN
        -- 対象テーブルの件数確認 (AS OF SCN)
        EXECUTE IMMEDIATE
            'SELECT COUNT(*) FROM src_schema.' || p_table ||
            ' AS OF SCN ' || p_scn
        INTO v_count;

        IF v_count = 0 THEN
            DBMS_OUTPUT.PUT_LINE('  [SKIP] ' || p_table || ': 0 rows');
            RETURN;
        END IF;

        -- tgt 側を一旦クリア (冪等対応)
        EXECUTE IMMEDIATE 'DELETE FROM tgt_schema.' || p_table || '@tgt_db';

        -- AS OF SCN でスナップショット時点のデータを全件コピー
        -- Oracle は LOB (BLOB/CLOB) の DB リンク転送を SELECT * で内部的に処理する
        EXECUTE IMMEDIATE
            'INSERT INTO tgt_schema.' || p_table || '@tgt_db ' ||
            'SELECT * FROM src_schema.' || p_table ||
            ' AS OF SCN ' || p_scn;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('  [OK] ' || p_table || ': ' || v_count || ' rows copied');

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            DBMS_OUTPUT.PUT_LINE('  [ERROR] ' || p_table || ': ' || SQLERRM);
            RAISE;
    END copy_single_table;

    -- ----------------------------------------------------------
    -- take_snapshot: Phase A メインエントリ
    -- ----------------------------------------------------------
    PROCEDURE take_snapshot(p_run_name IN VARCHAR2) IS
        v_scn      NUMBER;
        v_count    NUMBER;
        v_state_id NUMBER;
    BEGIN
        -- 二重実行チェック
        SELECT COUNT(*) INTO v_count
        FROM cdc_schema.cdc_state
        WHERE run_name = p_run_name AND status IN ('RUNNING', 'IDLE');

        IF v_count > 0 THEN
            RAISE_APPLICATION_ERROR(-20010,
                'CDC run already exists for run_name: ' || p_run_name ||
                '. Use a different run_name or drop the existing run.');
        END IF;

        -- 現在 SCN を取得（スナップショット基準時刻）
        SELECT CURRENT_SCN INTO v_scn FROM V$DATABASE;
        DBMS_OUTPUT.PUT_LINE('Snapshot SCN: ' || v_scn);

        -- cdc_state に登録（RUNNING）
        INSERT INTO cdc_schema.cdc_state (
            run_name, snapshot_scn, status, started_at
        ) VALUES (
            p_run_name, v_scn, 'RUNNING', SYSTIMESTAMP
        );
        COMMIT;

        -- FK 依存順にテーブルをコピー（親 → 子）
        DBMS_OUTPUT.PUT_LINE('Copying tables in FK order...');
        copy_single_table('REGIONS',               v_scn);
        copy_single_table('PRODUCT_CATEGORIES',    v_scn);
        copy_single_table('CUSTOMERS',             v_scn);
        copy_single_table('PRODUCTS',              v_scn);
        copy_single_table('ORDERS',                v_scn);
        copy_single_table('ORDER_ITEMS',           v_scn);
        copy_single_table('CUSTOMER_CONTRACTS',    v_scn);
        copy_single_table('ORDER_STATUS_HISTORY',  v_scn);
        copy_single_table('PRICE_HISTORY',         v_scn);
        copy_single_table('SYSTEM_EVENTS',         v_scn);

        -- cdc_state を IDLE に更新（Phase B 開始待ち）
        UPDATE cdc_schema.cdc_state
        SET
            status      = 'IDLE',
            last_run_at = SYSTIMESTAMP
        WHERE run_name = p_run_name;
        COMMIT;

        DBMS_OUTPUT.PUT_LINE('Snapshot completed. SCN=' || v_scn ||
                             ', run_name=' || p_run_name);

    EXCEPTION
        WHEN OTHERS THEN
            -- エラー時: cdc_state を ERROR に更新
            -- SQLERRM は SQL コンテキストで使用不可のため先に変数に退避
            DECLARE
                v_errm VARCHAR2(4000) := SUBSTR(SQLERRM, 1, 4000);
            BEGIN
                UPDATE cdc_schema.cdc_state
                SET
                    status        = 'ERROR',
                    error_message = v_errm,
                    last_run_at   = SYSTIMESTAMP
                WHERE run_name = p_run_name;
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
            RAISE;
    END take_snapshot;

    -- ----------------------------------------------------------
    -- verify_snapshot: 件数比較と PK 集合比較レポート
    -- ----------------------------------------------------------
    PROCEDURE verify_snapshot(p_state_id IN NUMBER) IS
        v_scn          NUMBER;
        v_src_count    NUMBER;
        v_tgt_count    NUMBER;
        v_missing_src  NUMBER;
        v_missing_tgt  NUMBER;

        TYPE t_table_list IS TABLE OF VARCHAR2(100);
        v_tables t_table_list := t_table_list(
            'REGIONS', 'PRODUCT_CATEGORIES', 'CUSTOMERS', 'PRODUCTS',
            'ORDERS', 'ORDER_ITEMS', 'CUSTOMER_CONTRACTS',
            'ORDER_STATUS_HISTORY', 'PRICE_HISTORY', 'SYSTEM_EVENTS'
        );

        TYPE t_pk_map IS TABLE OF VARCHAR2(100) INDEX BY VARCHAR2(100);
        v_pk_cols t_pk_map;

    BEGIN
        SELECT snapshot_scn INTO v_scn
        FROM cdc_schema.cdc_state WHERE state_id = p_state_id;

        -- PK カラム定義 (テーブル名 → PK カラム名)
        v_pk_cols('REGIONS')               := 'REGION_ID';
        v_pk_cols('PRODUCT_CATEGORIES')    := 'CATEGORY_ID';
        v_pk_cols('CUSTOMERS')             := 'CUSTOMER_ID';
        v_pk_cols('PRODUCTS')              := 'PRODUCT_ID';
        v_pk_cols('ORDERS')                := 'ORDER_ID';
        v_pk_cols('ORDER_ITEMS')           := 'ITEM_ID';
        v_pk_cols('CUSTOMER_CONTRACTS')    := 'CONTRACT_ID';
        v_pk_cols('ORDER_STATUS_HISTORY')  := 'HISTORY_ID';
        v_pk_cols('PRICE_HISTORY')         := 'HISTORY_ID';
        v_pk_cols('SYSTEM_EVENTS')         := 'EVENT_ID';

        DBMS_OUTPUT.PUT_LINE(RPAD('TABLE', 30) || RPAD('SRC', 10) ||
                             RPAD('TGT', 10) || RPAD('DIFF', 8) ||
                             RPAD('PK_MISSING_IN_TGT', 20) || 'PK_MISSING_IN_SRC');
        DBMS_OUTPUT.PUT_LINE(RPAD('-', 90, '-'));

        FOR i IN 1 .. v_tables.COUNT LOOP
            DECLARE
                v_table VARCHAR2(100) := v_tables(i);
                v_pk    VARCHAR2(100) := v_pk_cols(v_table);
            BEGIN
                EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM src_schema.' || v_table ||
                                  ' AS OF SCN ' || v_scn
                INTO v_src_count;

                EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM tgt_schema.' || v_table || '@tgt_db'
                INTO v_tgt_count;

                -- PK が tgt に存在しない件数 (src にあって tgt にない)
                EXECUTE IMMEDIATE
                    'SELECT COUNT(*) FROM (' ||
                    '  SELECT ' || v_pk || ' FROM src_schema.' || v_table ||
                    '  AS OF SCN ' || v_scn ||
                    '  MINUS' ||
                    '  SELECT ' || v_pk || ' FROM tgt_schema.' || v_table || '@tgt_db' ||
                    ')'
                INTO v_missing_tgt;

                -- PK が src に存在しない件数 (tgt にあって src にない)
                EXECUTE IMMEDIATE
                    'SELECT COUNT(*) FROM (' ||
                    '  SELECT ' || v_pk || ' FROM tgt_schema.' || v_table || '@tgt_db' ||
                    '  MINUS' ||
                    '  SELECT ' || v_pk || ' FROM src_schema.' || v_table ||
                    '  AS OF SCN ' || v_scn ||
                    ')'
                INTO v_missing_src;

                DBMS_OUTPUT.PUT_LINE(
                    RPAD(v_table, 30) ||
                    RPAD(v_src_count, 10) ||
                    RPAD(v_tgt_count, 10) ||
                    RPAD(v_tgt_count - v_src_count, 8) ||
                    RPAD(v_missing_tgt, 20) ||
                    v_missing_src
                );
            EXCEPTION
                WHEN OTHERS THEN
                    DBMS_OUTPUT.PUT_LINE(RPAD(v_table, 30) || 'ERROR: ' || SQLERRM);
            END;
        END LOOP;

        DBMS_OUTPUT.PUT_LINE(RPAD('-', 90, '-'));
        DBMS_OUTPUT.PUT_LINE('Snapshot SCN: ' || v_scn ||
                             ', state_id: ' || p_state_id);
    END verify_snapshot;

    -- ----------------------------------------------------------
    -- get_snapshot_scn: Phase B 開始 SCN を返す
    -- ----------------------------------------------------------
    FUNCTION get_snapshot_scn(p_run_name IN VARCHAR2) RETURN NUMBER IS
        v_scn NUMBER;
    BEGIN
        SELECT snapshot_scn INTO v_scn
        FROM cdc_schema.cdc_state
        WHERE run_name = p_run_name;
        RETURN v_scn;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END get_snapshot_scn;

END pkg_cdc_snapshot;
/
SHOW ERRORS PACKAGE BODY cdc_schema.pkg_cdc_snapshot;

PROMPT pkg_cdc_snapshot created.
EXIT;
