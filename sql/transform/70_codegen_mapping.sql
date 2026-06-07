-- 変換PL/SQL自動生成: マッピング設定表（対応関係の入力先）
-- 設計: docs/codegen-design.md / 計画: DD駆動 変換PL/SQL 自動生成器
--
-- 利用者は「移行元↔移行先の対応関係」を本2表に INSERT（CSVロード可）する。
-- pkg_codegen がこれと データディクショナリ(dba_tab_columns) を読み、
-- per-table 変換プロシージャ(pkg_transform_gen) と transform_catalog 登録を生成する。
--
-- 所有: LOG_SCHEMA / 実行: SYS AS SYSDBA / 対象: oracle-tgt XEPDB1 / 冪等

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

DECLARE
    PROCEDURE drop_tab(p_tab VARCHAR2) IS
        v_cnt NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_cnt FROM dba_tables WHERE owner='LOG_SCHEMA' AND table_name=p_tab;
        IF v_cnt>0 THEN EXECUTE IMMEDIATE 'DROP TABLE log_schema.'||p_tab||' PURGE'; END IF;
    END;
BEGIN
    drop_tab('CODEGEN_COLUMN_MAP');
    drop_tab('CODEGEN_TABLE_MAP');
END;
/

-- ============================================================
-- codegen_table_map: 1行 = 1移行先テーブルの変換定義
-- ============================================================
CREATE TABLE log_schema.codegen_table_map (
    tgt_table        VARCHAR2(128) NOT NULL,                 -- 移行先テーブル名（PK）
    src_schema       VARCHAR2(30)  DEFAULT 'STAGING_SCHEMA' NOT NULL, -- 移行元スキーマ
    tgt_schema       VARCHAR2(30)  DEFAULT 'TARGET_SCHEMA'  NOT NULL, -- 移行先スキーマ
    src_table        VARCHAR2(128) NOT NULL,                 -- 駆動元テーブル（別名 s）
    pk_columns       VARCHAR2(400) NOT NULL,                 -- 移行先PK（MERGE ON句）
    transform_class  VARCHAR2(20),                           -- NULL=自動判定 / 明示も可
    join_clause      VARCHAR2(2000),                         -- HEAVY用 LEFT JOIN句（別名 l_*）
    delete_src_table VARCHAR2(128),                          -- 削除伝播の検出元（NULL=src_table）
    sort_order       NUMBER(5)     DEFAULT 100 NOT NULL,     -- FK依存順（親小）
    is_active        VARCHAR2(1)   DEFAULT 'Y' NOT NULL,
    remarks          VARCHAR2(4000),
    CONSTRAINT pk_codegen_table_map PRIMARY KEY (tgt_table),
    CONSTRAINT chk_codegen_tclass CHECK (transform_class IS NULL OR
        transform_class IN ('PASS_THROUGH','LIGHT_TRANSFORM','HEAVY_TRANSFORM')),
    CONSTRAINT chk_codegen_tactive CHECK (is_active IN ('Y','N'))
);

-- ============================================================
-- codegen_column_map: 1行 = 1移行先列の変換ルール（固定プリミティブ）
--   transform_type と src_columns / arg_text の意味:
--   - DIRECT      : src_columns=1列。arg_text=キャスト種別(NONE/NUMBER/DATE/DATE_FROM_TS)
--   - CONCAT      : src_columns=複数列。arg_text=区切り文字リテラル(例 ' ')
--   - CODE_MAP    : src_columns=1列。arg_text=code_type（log_schema.code_mapping 参照）
--   - JSON_EXTRACT: src_columns=1列(JSON CLOB)。arg_text=JSONキー
--   - EXPRESSION  : arg_text=生SQL式（別名 s. / l_* 使用可）。src_columnsは無視
--   ※ COALESCE/CONSTANT/LOOKUP単列取得 等は EXPRESSION で表現する
-- ============================================================
CREATE TABLE log_schema.codegen_column_map (
    tgt_table       VARCHAR2(128) NOT NULL,
    tgt_column      VARCHAR2(128) NOT NULL,
    col_order       NUMBER(5)     NOT NULL,                  -- 生成列順
    transform_type  VARCHAR2(20)  NOT NULL,
    src_columns     VARCHAR2(400),                           -- カンマ区切り
    arg_text        VARCHAR2(2000),                          -- 種別ごとの引数/式
    CONSTRAINT pk_codegen_column_map PRIMARY KEY (tgt_table, tgt_column),
    CONSTRAINT chk_codegen_ttype CHECK (transform_type IN
        ('DIRECT','CONCAT','CODE_MAP','JSON_EXTRACT','EXPRESSION'))
);
CREATE INDEX log_schema.ix_codegen_col_order ON log_schema.codegen_column_map (tgt_table, col_order);

PROMPT codegen_table_map / codegen_column_map created on oracle-tgt.
EXIT;
