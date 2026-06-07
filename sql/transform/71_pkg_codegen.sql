-- 変換PL/SQL自動生成器 pkg_codegen
-- 設計: docs/codegen-design.md / 計画: DD駆動 変換PL/SQL 自動生成器
--
-- データディクショナリ(dba_tab_columns) + マッピング設定(codegen_table_map/column_map) を読み、
-- per-table 変換プロシージャ package pkg_transform_gen と transform_catalog/transform_state 登録を
-- SQL テキストとして DBMS_OUTPUT に出力する（scripts/70 が spool でファイル化→デプロイ）。
--
-- LLM不要・決定論的。固定プリミティブ: DIRECT/CONCAT/CODE_MAP/JSON_EXTRACT/EXPRESSION。
-- 所有: LOG_SCHEMA / 実行: SYS AS SYSDBA / 対象: oracle-tgt XEPDB1 / Oracle 12c 互換

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

CREATE OR REPLACE PACKAGE log_schema.pkg_codegen AS
    -- 生成結果を DBMS_OUTPUT へ出力（SET SERVEROUTPUT ON + spool で取得）
    PROCEDURE generate_all;
END pkg_codegen;
/
SHOW ERRORS PACKAGE log_schema.pkg_codegen;

CREATE OR REPLACE PACKAGE BODY log_schema.pkg_codegen AS

    Q CONSTANT VARCHAR2(1) := CHR(39);   -- 単一引用符（生成コードへの埋め込み用）

    PROCEDURE p(s IN VARCHAR2) IS
    BEGIN DBMS_OUTPUT.PUT_LINE(s); END;

    -- src 表に指定列があるか（DELTA差分窓の updated_at 判定等）
    FUNCTION has_col(p_schema VARCHAR2, p_table VARCHAR2, p_col VARCHAR2) RETURN BOOLEAN IS
        v NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v FROM dba_tab_columns
        WHERE owner=p_schema AND table_name=p_table AND column_name=p_col;
        RETURN v > 0;
    END has_col;

    -- カンマ区切りの n 番目要素（1始まり, TRIM済）
    FUNCTION nth(p_list VARCHAR2, p_n PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN TRIM(REGEXP_SUBSTR(p_list, '[^,]+', 1, p_n));
    END nth;

    FUNCTION cnt(p_list VARCHAR2) RETURN PLS_INTEGER IS
    BEGIN
        IF p_list IS NULL THEN RETURN 0; END IF;
        RETURN REGEXP_COUNT(p_list, ',') + 1;
    END cnt;

    -- 1列の SELECT 式を生成（プリミティブごと）。別名 s（主表）/ l_*（join）。
    FUNCTION gen_expr(p_type VARCHAR2, p_srccols VARCHAR2, p_arg VARCHAR2) RETURN VARCHAR2 IS
        v VARCHAR2(4000);
        c1 VARCHAR2(128) := nth(p_srccols, 1);
        i PLS_INTEGER;
    BEGIN
        CASE p_type
        WHEN 'DIRECT' THEN
            CASE NVL(UPPER(p_arg),'NONE')
            WHEN 'NUMBER'        THEN v := 'log_schema.pkg_transform_util.safe_to_number(s."'||c1||'")';
            WHEN 'DATE'          THEN v := 'log_schema.pkg_transform_util.safe_to_date(s."'||c1||'")';
            WHEN 'DATE_FROM_TS'  THEN v := 'CAST(s."'||c1||'" AS DATE)';
            ELSE                      v := 's."'||c1||'"';
            END CASE;
        WHEN 'CONCAT' THEN
            v := 's."'||nth(p_srccols,1)||'"';
            FOR i IN 2 .. cnt(p_srccols) LOOP
                v := v || ' || '||Q||p_arg||Q||' || s."'||nth(p_srccols,i)||'"';
            END LOOP;
        WHEN 'CODE_MAP' THEN
            v := 'NVL((SELECT m.tgt_value FROM log_schema.code_mapping m WHERE m.code_type='
                 ||Q||p_arg||Q||' AND m.src_code=s."'||c1||'"), s."'||c1||'")';
        WHEN 'JSON_EXTRACT' THEN
            v := 'REGEXP_SUBSTR(DBMS_LOB.SUBSTR(s."'||c1||'",2000,1),'
                 ||Q||'"'||p_arg||'"[[:space:]]*:[[:space:]]*"([^"]*)"'||Q||',1,1,NULL,1)';
        WHEN 'EXPRESSION' THEN
            v := p_arg;
        ELSE
            v := 'NULL';
        END CASE;
        RETURN v;
    END gen_expr;

    -- 1テーブル分の transform_<tgt> プロシージャ本体を出力
    PROCEDURE gen_table_body(p_tgt VARCHAR2, p_src_schema VARCHAR2, p_tgt_schema VARCHAR2,
                             p_src_table VARCHAR2, p_pk VARCHAR2, p_join VARCHAR2) IS
        v_proc      VARCHAR2(128) := 'transform_'||LOWER(p_tgt);
        v_step      VARCHAR2(128) := 'TRANSFORM_'||UPPER(p_tgt);
        v_collist   VARCHAR2(8000);     -- "C1","C2",...
        v_pkset     VARCHAR2(400) := ','||UPPER(p_pk)||',';
        v_on        VARCHAR2(2000);
        v_set       VARCHAR2(8000);
        v_insvals   VARCHAR2(8000);
        v_window    VARCHAR2(400) := '';
        first BOOLEAN := TRUE;
    BEGIN
        -- DELTA 差分窓（src に updated_at があれば適用）
        IF has_col(p_src_schema, p_src_table, 'UPDATED_AT') THEN
            v_window := ' WHERE NVL(s.updated_at, s.created_at) > p_last '||
                        'AND NVL(s.updated_at, s.created_at) <= p_snap';
        END IF;

        -- ON句（複合PK対応）
        FOR i IN 1 .. cnt(p_pk) LOOP
            v_on := v_on || CASE WHEN v_on IS NULL THEN '' ELSE ' AND ' END
                    || 't."'||nth(p_pk,i)||'"=src."'||nth(p_pk,i)||'"';
        END LOOP;

        -- 列リスト・SET句・INSERT VALUES句
        FOR c IN (SELECT tgt_column FROM log_schema.codegen_column_map
                  WHERE tgt_table=p_tgt ORDER BY col_order) LOOP
            v_collist := v_collist || CASE WHEN v_collist IS NULL THEN '' ELSE ',' END||'"'||c.tgt_column||'"';
            v_insvals := v_insvals || CASE WHEN v_insvals IS NULL THEN '' ELSE ',' END||'src."'||c.tgt_column||'"';
            IF INSTR(v_pkset, ','||c.tgt_column||',') = 0 THEN
                v_set := v_set || CASE WHEN v_set IS NULL THEN '' ELSE ',' END
                         ||'t."'||c.tgt_column||'"=src."'||c.tgt_column||'"';
            END IF;
        END LOOP;

        p('  PROCEDURE '||v_proc||'(p_run_id NUMBER, p_mode VARCHAR2, p_last TIMESTAMP, p_snap TIMESTAMP) IS');
        p('    v_src NUMBER; v_tgt NUMBER;');
        p('  BEGIN');
        p('    SELECT COUNT(*) INTO v_src FROM '||p_src_schema||'.'||p_src_table||';');
        p('    log_schema.pkg_transform.log_step(p_run_id,'||Q||v_step||Q||','||Q||'RUNNING'||Q||',v_src,0);');
        p('    IF p_mode='||Q||'INITIAL'||Q||' THEN');
        p('      INSERT INTO '||p_tgt_schema||'.'||p_tgt||' ('||v_collist||')');
        p('      SELECT');
        -- INITIAL SELECT 式（列ごと1行・末尾カンマ制御）
        first := TRUE;
        FOR c IN (SELECT tgt_column, transform_type, src_columns, arg_text
                  FROM log_schema.codegen_column_map WHERE tgt_table=p_tgt ORDER BY col_order) LOOP
            p('        '||CASE WHEN first THEN ' ' ELSE ',' END||
              gen_expr(c.transform_type, c.src_columns, c.arg_text));
            first := FALSE;
        END LOOP;
        p('      FROM '||p_src_schema||'.'||p_src_table||' s '||NVL(p_join,'')||';');
        p('    ELSE');
        p('      MERGE INTO '||p_tgt_schema||'.'||p_tgt||' t USING (');
        p('        SELECT');
        first := TRUE;
        FOR c IN (SELECT tgt_column, transform_type, src_columns, arg_text
                  FROM log_schema.codegen_column_map WHERE tgt_table=p_tgt ORDER BY col_order) LOOP
            p('          '||CASE WHEN first THEN ' ' ELSE ',' END||
              gen_expr(c.transform_type, c.src_columns, c.arg_text)||' AS "'||c.tgt_column||'"');
            first := FALSE;
        END LOOP;
        p('        FROM '||p_src_schema||'.'||p_src_table||' s '||NVL(p_join,'')||v_window);
        p('      ) src ON ('||v_on||')');
        p('      WHEN MATCHED THEN UPDATE SET '||v_set);
        p('      WHEN NOT MATCHED THEN INSERT ('||v_collist||') VALUES ('||v_insvals||');');
        p('    END IF;');
        p('    SELECT COUNT(*) INTO v_tgt FROM '||p_tgt_schema||'.'||p_tgt||';');
        p('    log_schema.pkg_transform.log_step(p_run_id,'||Q||v_step||Q||','||Q||'SUCCESS'||Q||',v_src,v_tgt);');
        p('  END '||v_proc||';');
        p('');
    END gen_table_body;

    -- 分類自動判定（codegen_table_map.transform_class が NULL のとき）
    FUNCTION derive_class(p_tgt VARCHAR2, p_join VARCHAR2) RETURN VARCHAR2 IS
        v_cols NUMBER; v_nondirect NUMBER;
    BEGIN
        SELECT COUNT(*), COUNT(CASE WHEN transform_type<>'DIRECT' OR NVL(UPPER(arg_text),'NONE')<>'NONE' THEN 1 END)
        INTO v_cols, v_nondirect
        FROM log_schema.codegen_column_map WHERE tgt_table=p_tgt;
        IF p_join IS NOT NULL THEN RETURN 'HEAVY_TRANSFORM'; END IF;
        IF v_cols=0 THEN RETURN 'PASS_THROUGH'; END IF;
        IF v_nondirect=0 THEN RETURN 'PASS_THROUGH'; END IF;
        RETURN 'LIGHT_TRANSFORM';
    END derive_class;

    PROCEDURE generate_all IS
        v_class    VARCHAR2(20);
        v_proc_fq  VARCHAR2(200);
        v_gen_cnt  NUMBER := 0;
    BEGIN
        p('-- ============================================================');
        p('-- 自動生成: pkg_transform_gen + transform_catalog/state 登録');
        p('-- generated by log_schema.pkg_codegen.generate_all');
        p('-- ============================================================');
        p('SET DEFINE OFF');
        p('');
        -- 1) パッケージ spec
        p('CREATE OR REPLACE PACKAGE log_schema.pkg_transform_gen AS');
        FOR t IN (SELECT tgt_table, transform_class, join_clause FROM log_schema.codegen_table_map
                  WHERE is_active='Y' ORDER BY sort_order) LOOP
            v_class := NVL(t.transform_class, derive_class(t.tgt_table, t.join_clause));
            IF v_class <> 'PASS_THROUGH' THEN
                p('  PROCEDURE transform_'||LOWER(t.tgt_table)||
                  '(p_run_id NUMBER, p_mode VARCHAR2, p_last TIMESTAMP, p_snap TIMESTAMP);');
                v_gen_cnt := v_gen_cnt + 1;
            END IF;
        END LOOP;
        IF v_gen_cnt = 0 THEN p('  PROCEDURE noop;'); END IF;
        p('END pkg_transform_gen;');
        p('/');
        p('');
        -- 2) パッケージ body
        p('CREATE OR REPLACE PACKAGE BODY log_schema.pkg_transform_gen AS');
        FOR t IN (SELECT tgt_table, src_schema, tgt_schema, src_table, pk_columns,
                         transform_class, join_clause
                  FROM log_schema.codegen_table_map WHERE is_active='Y' ORDER BY sort_order) LOOP
            v_class := NVL(t.transform_class, derive_class(t.tgt_table, t.join_clause));
            IF v_class <> 'PASS_THROUGH' THEN
                gen_table_body(t.tgt_table, t.src_schema, t.tgt_schema, t.src_table,
                               t.pk_columns, t.join_clause);
            END IF;
        END LOOP;
        IF v_gen_cnt = 0 THEN p('  PROCEDURE noop IS BEGIN NULL; END;'); END IF;
        p('END pkg_transform_gen;');
        p('/');
        p('');
        -- 3) transform_catalog / transform_state 登録（マッピングが唯一の真実源）
        FOR t IN (SELECT tgt_table, src_table, transform_class, join_clause, pk_columns,
                         delete_src_table, sort_order
                  FROM log_schema.codegen_table_map WHERE is_active='Y' ORDER BY sort_order) LOOP
            v_class := NVL(t.transform_class, derive_class(t.tgt_table, t.join_clause));
            IF v_class = 'PASS_THROUGH' THEN
                v_proc_fq := 'NULL';
            ELSE
                v_proc_fq := Q||'LOG_SCHEMA.PKG_TRANSFORM_GEN.TRANSFORM_'||UPPER(t.tgt_table)||Q;
            END IF;
            p('MERGE INTO log_schema.transform_catalog c USING (SELECT '||Q||t.tgt_table||Q||
              ' AS tgt FROM DUAL) d ON (c.tgt_table_name=d.tgt)');
            p('WHEN MATCHED THEN UPDATE SET c.src_table_name='||Q||t.src_table||Q||
              ', c.transform_class='||Q||v_class||Q||', c.proc_name='||v_proc_fq||
              ', c.pk_columns='||Q||t.pk_columns||Q||
              ', c.delete_src_table='||Q||NVL(t.delete_src_table,t.src_table)||Q||
              ', c.sort_order='||t.sort_order||', c.is_active='||Q||'Y'||Q);
            p('WHEN NOT MATCHED THEN INSERT (catalog_id,src_table_name,tgt_table_name,transform_class,'||
              'proc_name,pk_columns,delete_src_table,sort_order,is_active)');
            p(' VALUES (log_schema.seq_catalog_id.NEXTVAL,'||Q||t.src_table||Q||','||Q||t.tgt_table||Q||','||
              Q||v_class||Q||','||v_proc_fq||','||Q||t.pk_columns||Q||','||
              Q||NVL(t.delete_src_table,t.src_table)||Q||','||t.sort_order||','||Q||'Y'||Q||');');
            p('MERGE INTO log_schema.transform_state s USING (SELECT '||Q||t.tgt_table||Q||
              ' AS tgt FROM DUAL) d ON (s.tgt_table_name=d.tgt)');
            p('WHEN NOT MATCHED THEN INSERT (tgt_table_name) VALUES ('||Q||t.tgt_table||Q||');');
        END LOOP;
        p('COMMIT;');
        p('-- end generated');
    END generate_all;

END pkg_codegen;
/
SHOW ERRORS PACKAGE BODY log_schema.pkg_codegen;

PROMPT pkg_codegen created on oracle-tgt.
EXIT;
