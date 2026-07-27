-- LogMiner 辞書ビルドスクリプト
-- 実行ユーザー: / as sysdba
-- 実行対象: oracle-src CDB$ROOT
--
-- 重要: このスクリプトは必ず CDB$ROOT で実行すること。
--       XEPDB1（PDB）内で実行すると PL/SQL は正常終了するが
--       辞書が Redo ストリームへ書き出されない（docs/phase3-design.md §7 ノウハウ #1）。
--       接続は「sqlplus / as sysdba」のまま使用し、
--       ALTER SESSION SET CONTAINER は絶対に実行しないこと。
--
-- 実行方法:
--   docker exec -u oracle oracle-src bash -c \
--     "sqlplus -S '/ as sysdba' @01_build_logminer_dict_src.sql"

WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR  EXIT FAILURE
SET ECHO ON FEEDBACK ON SERVEROUTPUT ON SIZE UNLIMITED

-- -----------------------------------------------------------------------
-- Step 1: CDB$ROOT で LogMiner 辞書を Redo ストリームへ書き出す
--
-- STORE_IN_REDO_LOGS オプション: 辞書をフラットファイルではなく
-- Redo ログ自体に埋め込む。LogMiner 実行側（oracle-tgt）で辞書を
-- 別途転送する必要がなく、ログファイルだけで解析できるようになる。
-- -----------------------------------------------------------------------
BEGIN
    DBMS_LOGMNR_D.BUILD(
        OPTIONS => DBMS_LOGMNR_D.STORE_IN_REDO_LOGS
    );
    DBMS_OUTPUT.PUT_LINE('DBMS_LOGMNR_D.BUILD completed.');
END;
/

-- -----------------------------------------------------------------------
-- Step 2: 現在の Redo ログをアーカイブして辞書を含むログを確定する
-- -----------------------------------------------------------------------
ALTER SYSTEM ARCHIVE LOG CURRENT;
PROMPT Archive log current completed.

-- -----------------------------------------------------------------------
-- Step 3: マーカー確認（02_verify_dict_markers_src.sql を参照）
-- 後続のスクリプトで V$ARCHIVED_LOG の DICTIONARY_BEGIN/DICTIONARY_END
-- を確認すること。マーカーが NO のまま = PDB 内で実行した可能性がある。
-- -----------------------------------------------------------------------
PROMPT
PROMPT Next step: run 02_verify_dict_markers_src.sql to confirm DICTIONARY_BEGIN/END markers.

EXIT;
