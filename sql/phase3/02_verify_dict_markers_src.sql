-- LogMiner 辞書マーカー確認スクリプト
-- 実行ユーザー: / as sysdba
-- 実行対象: oracle-src CDB$ROOT
--
-- 目的: V$ARCHIVED_LOG の DICTIONARY_BEGIN/DICTIONARY_END マーカーを確認する。
--       DICTIONARY_BEGIN='YES' または DICTIONARY_END='YES' の行が存在すれば
--       辞書が正しく Redo ストリームに書き込まれている。
--
-- マーカーが付かない場合の原因と対処（docs/phase3-design.md §7 ノウハウ #1）:
--   原因: DBMS_LOGMNR_D.BUILD を XEPDB1（PDB）内で実行した
--   対処: CDB$ROOT（sysdba 接続、ALTER SESSION SET CONTAINER を行わない）で再実行
--
-- 実行方法:
--   docker exec -u oracle oracle-src bash -c \
--     "sqlplus -S '/ as sysdba' @02_verify_dict_markers_src.sql"

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET PAGESIZE 50 LINESIZE 200
SET ECHO ON FEEDBACK ON

-- -----------------------------------------------------------------------
-- 直近 10 件の Archived Redo ログで DICTIONARY_BEGIN/DICTIONARY_END を確認する
-- -----------------------------------------------------------------------
COLUMN SEQUENCE#         FORMAT 9999999 HEADING 'SEQ#'
COLUMN DICTIONARY_BEGIN  FORMAT A6      HEADING 'D_BGN'
COLUMN DICTIONARY_END    FORMAT A6      HEADING 'D_END'
COLUMN NAME              FORMAT A80     HEADING 'FILE_PATH'

SELECT * FROM (
    SELECT
        SEQUENCE#,
        DICTIONARY_BEGIN,
        DICTIONARY_END,
        NAME
    FROM V$ARCHIVED_LOG
    WHERE STATUS = 'A'
      AND NAME IS NOT NULL
    ORDER BY SEQUENCE# DESC
) WHERE ROWNUM <= 10;

-- -----------------------------------------------------------------------
-- マーカー付きログが存在するか確認（YES が 1 件でもあれば辞書ビルド成功）
-- -----------------------------------------------------------------------
COLUMN MARKER_COUNT FORMAT 9999 HEADING 'MARKER_COUNT'

SELECT COUNT(*) AS MARKER_COUNT
FROM V$ARCHIVED_LOG
WHERE STATUS = 'A'
  AND (DICTIONARY_BEGIN = 'YES' OR DICTIONARY_END = 'YES');

PROMPT
PROMPT If MARKER_COUNT > 0, dictionary was successfully embedded in Redo logs.
PROMPT If MARKER_COUNT = 0, the BUILD was likely run inside PDB (not CDB root).

EXIT;
