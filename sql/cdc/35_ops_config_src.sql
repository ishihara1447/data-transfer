-- 運用パラメータ設定テーブル: ops_config / ops_config_history (oracle-src 用)
-- 本番相当（多PDB・500テーブル超）で運用者が「枯渇・遅延リスク」に備えて
-- 閾値やバッチサイズ・実行間隔・DBパラメータの目標値を変更制御するための単一の真実源。
--
-- 利用方法（CLI）: scripts/61_ops_config.sh list|get|set|reset|history|apply
-- 参照側        : scripts/50_migration_dashboard.sh（閾値で警告色） /
--                 scripts/40_cdc_cycle.sh・41_cdc_daemon.sh（間隔・バッチ） /
--                 scripts/61 apply（SRC_SYSTEM の ALTER SYSTEM 反映）
--
-- 実行ユーザー: SYS AS SYSDBA / 実行対象: oracle-src XEPDB1 / Oracle 12c 互換 / 冪等
-- ★冪等性の方針: 既存テーブルは DROP しない（運用者が変更した値を保護）。
--   テーブルが無ければ作成し、不足キーのみ既定値で MERGE 補充する。

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

-- ============================================================
-- ops_config: 運用パラメータ（キー=値 + 範囲・分類・反映先）
--   value_type : INT(整数) / SEC(秒) / PCT(%) / MB(メガバイト)
--   applies_to : DASHBOARD(可視化閾値) / CDC(パイプライン制御) /
--                SRC_SYSTEM(DBパラメータ。apply で ALTER SYSTEM 反映)
-- ============================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_tables
    WHERE owner = 'CDC_SCHEMA' AND table_name = 'OPS_CONFIG';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE q'[
            CREATE TABLE cdc_schema.ops_config (
                param_key    VARCHAR2(60)  NOT NULL,
                category     VARCHAR2(20)  NOT NULL,   -- ARCHIVE/CDC/LAG/UNDO
                param_value  VARCHAR2(100) NOT NULL,
                default_value VARCHAR2(100) NOT NULL,
                min_value    NUMBER,                   -- 数値型の下限（NULL=無制限）
                max_value    NUMBER,                   -- 数値型の上限（NULL=無制限）
                value_type   VARCHAR2(10)  NOT NULL,
                applies_to   VARCHAR2(12)  NOT NULL,
                description  VARCHAR2(400),
                updated_at   TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
                updated_by   VARCHAR2(60)  DEFAULT USER NOT NULL,
                CONSTRAINT pk_ops_config PRIMARY KEY (param_key),
                CONSTRAINT chk_ops_config_type
                    CHECK (value_type IN ('INT','SEC','PCT','MB')),
                CONSTRAINT chk_ops_config_applies
                    CHECK (applies_to IN ('DASHBOARD','CDC','SRC_SYSTEM'))
            )]';
    END IF;
END;
/

-- ============================================================
-- ops_config_history: 変更履歴（誰が・いつ・どの値を）
-- ============================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_tables
    WHERE owner = 'CDC_SCHEMA' AND table_name = 'OPS_CONFIG_HISTORY';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE q'[
            CREATE TABLE cdc_schema.ops_config_history (
                hist_id     NUMBER         NOT NULL,
                param_key   VARCHAR2(60)   NOT NULL,
                old_value   VARCHAR2(100),
                new_value   VARCHAR2(100),
                changed_at  TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
                changed_by  VARCHAR2(60)   DEFAULT USER NOT NULL,
                note        VARCHAR2(400),
                CONSTRAINT pk_ops_config_history PRIMARY KEY (hist_id)
            )]';
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM dba_sequences
    WHERE sequence_owner = 'CDC_SCHEMA' AND sequence_name = 'SEQ_OPS_CONFIG_HIST';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE SEQUENCE cdc_schema.seq_ops_config_hist '
                       || 'START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE';
    END IF;
END;
/

-- ============================================================
-- 既定値の補充（不足キーのみ。既存値は上書きしない）
--   ヘルパープロシージャで MERGE。再実行しても運用者変更を保持する。
-- ============================================================
DECLARE
    PROCEDURE seed(
        p_key   VARCHAR2, p_cat VARCHAR2, p_default VARCHAR2,
        p_min   NUMBER,   p_max VARCHAR2, p_type VARCHAR2,
        p_applies VARCHAR2, p_desc VARCHAR2
    ) IS
    BEGIN
        MERGE INTO cdc_schema.ops_config t
        USING (SELECT p_key AS k FROM dual) s
        ON (t.param_key = s.k)
        WHEN NOT MATCHED THEN INSERT
            (param_key, category, param_value, default_value,
             min_value, max_value, value_type, applies_to, description)
        VALUES
            (p_key, p_cat, p_default, p_default,
             p_min, p_max, p_type, p_applies, p_desc);
    END;
BEGIN
    -- ---- ARCHIVE: archive log 保持・FRA(リドログ/アーカイブ領域上限) ----
    seed('fra_quota_mb',            'ARCHIVE', '4096',  1024, 10485760, 'MB', 'SRC_SYSTEM',
         'FRA(db_recovery_file_dest_size)の上限MB。リドログ/アーカイブ保管領域の上限。apply でALTER SYSTEM反映。');
    seed('fra_warn_pct',            'ARCHIVE', '80',    1,    100,      'PCT','DASHBOARD',
         'FRA使用率がこの%を超えたらダッシュボードで警告(黄)。');
    seed('fra_crit_pct',            'ARCHIVE', '90',    1,    100,      'PCT','DASHBOARD',
         'FRA使用率がこの%を超えたら危険(赤)。RMAN削除が追いつかない兆候。');
    seed('arch_retention_warn_days','ARCHIVE', '7',     1,    365,      'INT','DASHBOARD',
         'archive保持日数がこの日数を下回ったら警告(黄)。差分が読める期間の余裕。');
    seed('arch_retention_crit_days','ARCHIVE', '3',     1,    365,      'INT','DASHBOARD',
         'archive保持日数がこの日数を下回ったら危険(赤)。CDC再開不能リスク。');

    -- ---- CDC: パイプライン制御（間隔・バッチ） ----
    seed('cdc_interval_sec',        'CDC',     '10',    1,    3600,     'SEC','CDC',
         '継続CDCデーモン(41)のサイクル間隔秒。短いほど低遅延・高負荷。');
    seed('transform_batch_rows',    'CDC',     '10000', 100,  1000000,  'INT','CDC',
         'transform DELTA の1バッチ処理行数。UNDO/REDO負荷とのバランス。');

    -- ---- LAG: 遅延・鮮度の警告閾値（ダッシュボード） ----
    seed('transform_age_warn_sec',  'LAG',     '60',    1,    86400,    'SEC','DASHBOARD',
         'TARGET鮮度(最終変換からの経過)がこの秒数を超えたら警告(黄)。');
    seed('transform_age_crit_sec',  'LAG',     '300',   1,    86400,    'SEC','DASHBOARD',
         'TARGET鮮度がこの秒数を超えたら危険(赤)。CDC停滞の疑い。');
    seed('pending_xfer_warn',       'LAG',     '1000',  1,    100000000,'INT','DASHBOARD',
         '未搬送delta件数(src-tgt)がこの件数を超えたら警告(黄)。搬送遅延。');

    -- ---- UNDO: ORA-01555/初期ロード関連の目標値 ----
    seed('undo_retention_sec',      'UNDO',    '3600',  300,  172800,   'SEC','SRC_SYSTEM',
         'undo_retention目標秒。初期ロード(FLASHBACK_SCN)所要時間+マージン。apply でALTER SYSTEM反映。');
    seed('initial_load_hours',      'UNDO',    '6',     1,    168,      'INT','DASHBOARD',
         '5TB初期ロードの想定所要時間(時間)。undo_retentionの目安算出に使用(参照値)。');

    -- ---- CDC: LOBテーブル差分反映（周期的ターゲット再同期）の制御 ----
    seed('lob_resync_interval_cycles', 'CDC',  '6',     1,    1000,     'INT','CDC',
         'CDCサイクル(40)を何回まわすごとに LOB再同期サイクル(43)を起動するか。'
         || '既定6=6サイクルに1回。小さいほど低遅延・高負荷(expdp/impdp往復コスト)。');
    seed('lob_resync_pending_threshold', 'CDC','500',   1,    100000000,'INT','CDC',
         'lob_resync_target の PENDING 件数がこれを超えたら周期を待たず即起動。'
         || '既定500。大量LOB変更が発生した場合の遅延防止。');

    COMMIT;
END;
/

PROMPT ops_config / ops_config_history created and seeded (missing keys only) on oracle-src.
EXIT;
