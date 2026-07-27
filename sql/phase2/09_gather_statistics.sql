-- Phase 2: 統計情報取得
-- 実行場所: oracle-tgt コンテナ内
-- 接続: STAGING_SCHEMA または SYSDBA

SET SERVEROUTPUT ON

BEGIN
    DBMS_STATS.GATHER_SCHEMA_STATS(
        ownname => 'STAGING_SCHEMA',
        cascade => TRUE,
        degree  => 1   -- 21c XE では PARALLEL 不使用
    );
    DBMS_OUTPUT.PUT_LINE('統計情報取得完了');
END;
/
