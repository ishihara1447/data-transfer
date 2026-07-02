-- 差分適用手動調査キュー (oracle-tgt 用)
-- replay_allowed='N' の差分イベント（LOBテーブル・STATUS異常・ホワイトリスト未登録等）を
-- ここに格納して手動調査の対象とする。自動適用できない事象を握りつぶさないための仕組み。
--
-- 格納対象の例:
--   - LOBテーブル (replay_category='C'): CUSTOMERS, ORDERS
--   - STATUS異常 (replay_category='E'): UNSUPPORTED/MISSING_SCN等
--   - ホワイトリスト未登録 (replay_category='B')
--   - LOB操作コード (OPERATION_CODE 92/93/94: LOB_WRITE/LOB_TRIM/LOB_ERASE)
--
-- ★LOB差分反映方式（11章）との連携:
--   - pk_value: delta_queue.pk_value を伝播（LOB再同期要求のキー）
--   - review_status='IN_REVIEW': lob_resync_build_targets が処理済みに更新
--   - review_status='RESOLVED': lob_resync_merge が完了後に更新
--
-- 実行ユーザー: SYS AS SYSDBA / 実行対象: oracle-tgt XEPDB1 / Oracle 12c 互換 / 冪等

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON
SET FEEDBACK ON

CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = XEPDB1;

DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_tables
    WHERE owner = 'STAGING_CTL' AND table_name = 'DELTA_MANUAL_REVIEW_QUEUE';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'DROP TABLE staging_ctl.delta_manual_review_queue PURGE';
    END IF;
END;
/

CREATE TABLE staging_ctl.delta_manual_review_queue (
    review_id          NUMBER GENERATED ALWAYS AS IDENTITY,
    -- 元イベント情報（delta_queue への参照）
    batch_delta_id     NUMBER,             -- staging_ctl.delta_queue.delta_id
    commit_scn         NUMBER(20),
    xid                VARCHAR2(40),
    seg_owner          VARCHAR2(128),
    seg_name           VARCHAR2(128),
    operation          VARCHAR2(32),
    operation_code     NUMBER,
    status_code        NUMBER,
    info_text          VARCHAR2(4000),
    -- ★LOBフォールバック用 PK値（delta_queue.pk_value を伝播）
    pk_value           VARCHAR2(100),
    -- SQL（CSF連結済み）
    sql_redo_assembled CLOB,
    -- 分類結果（delta_extractが付与）
    replay_category    VARCHAR2(1),        -- A/B/C/D/E
    fallback_reason    VARCHAR2(4000),
    -- 調査状態
    review_status      VARCHAR2(30)  DEFAULT 'PENDING' NOT NULL,
    reviewed_at        TIMESTAMP,
    reviewed_by        VARCHAR2(128),
    review_note        VARCHAR2(4000),
    -- 管理
    created_at         TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_delta_manual_review      PRIMARY KEY (review_id),
    CONSTRAINT chk_manual_review_status    CHECK (review_status IN
        ('PENDING','IN_REVIEW','RESOLVED','IGNORED'))
);

COMMENT ON TABLE staging_ctl.delta_manual_review_queue IS '自動適用できなかった差分イベントの手動調査キュー。LOB(C)・STATUS異常(E)・ホワイトリスト未登録(B)等が対象。LOBフォールバック(PK再取得/最終再同期)の作業記録にも使用する。pk_value はLOB差分反映（lob_resync_build_targets）が集約する際のキー。';

CREATE INDEX staging_ctl.ix_manual_review_scn
    ON staging_ctl.delta_manual_review_queue (commit_scn);

CREATE INDEX staging_ctl.ix_manual_review_pending
    ON staging_ctl.delta_manual_review_queue (review_status, seg_name, created_at);

PROMPT staging_ctl.delta_manual_review_queue created on oracle-tgt.
EXIT;
