-- フェーズ3 ビュー定義
-- 実行ユーザー: migration_ctl
-- 実行対象: oracle-tgt (localhost:1521/XEPDB1)
-- 設計: docs/phase3-design.md §1.1（ポイント2）
--
-- V_ARCHIVE_LOG_GAP: Thread 別 Sequence の連番欠落を検出するビュー
--   COLLECT_STATUS='IGNORED' の行は欠落検出から除外する

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON FEEDBACK ON

-- ---------------------------------------------------------------------------
-- V_ARCHIVE_LOG_GAP: LAG() で Thread 別 Sequence の連番欠落を検出する
--
-- 列:
--   MIG_RUN_ID    : 移行実行ID
--   THREAD_NO     : RAC Thread 番号（本検証では 1 固定）
--   GAP_FROM_SEQ  : 欠落が始まる Sequence 番号（欠落区間の先頭）
--   GAP_TO_SEQ    : 欠落が終わる Sequence 番号（欠落区間の末尾）
--
-- 例: Sequence 1, 2, 4 が登録されている場合
--   GAP_FROM_SEQ=3, GAP_TO_SEQ=3 の行が返る
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_ARCHIVE_LOG_GAP AS
SELECT
    MIG_RUN_ID,
    THREAD_NO,
    LAG_SEQ + 1   AS GAP_FROM_SEQ,
    SEQUENCE_NO - 1 AS GAP_TO_SEQ
FROM (
    SELECT
        MIG_RUN_ID,
        THREAD_NO,
        SEQUENCE_NO,
        LAG(SEQUENCE_NO) OVER (
            PARTITION BY MIG_RUN_ID, THREAD_NO
            ORDER BY SEQUENCE_NO
        ) AS LAG_SEQ
    FROM ARCHIVE_LOG
    WHERE COLLECT_STATUS <> 'IGNORED'
)
WHERE LAG_SEQ IS NOT NULL
  AND SEQUENCE_NO > LAG_SEQ + 1
;

PROMPT V_ARCHIVE_LOG_GAP created.

EXIT;
