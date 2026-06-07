# Phase 1 再設計: COMMIT_SCN 基準の差分抽出・適用

## 0. この文書の位置づけ

`docs/gap-analysis.md` で最重要ギャップと判定した **G2/G3/G4** を解消するための
差分抽出・適用方式の再設計。実装前の設計合意を目的とする。

| ギャップ | 内容 | 本設計での解決 |
|---------|------|--------------|
| G2 | 差分境界が `SCN > last_scn` の単純フィルタ | COMMIT_SCN 基準へ変更 |
| G3 | COMMITTED_DATA_ONLY 未使用 | LogMiner OPTIONS に追加 |
| G4 | commit_scn 台帳がなく再開が脆弱 | apply_ledger を新設 |

関連: `docs/delta-extract-design.md`（現行方式）/ `docs/gap-analysis.md`（ギャップ）

---

## 1. なぜ現行方式が本番で破綻するか

### 現行ロジック（31_pkg_delta_extract_src.sql）

```sql
SELECT SCN, SEG_NAME, OPERATION, SQL_REDO, RS_ID, SSN
FROM V$LOGMNR_CONTENTS
WHERE SEG_OWNER = 'SRC_SCHEMA'
  AND OPERATION IN ('INSERT','UPDATE','DELETE')
  AND SCN > v_last_scn          -- ← ここが問題
  AND SCN <= v_end_scn
ORDER BY SCN, RS_ID, SSN
```

`START_LOGMNR` に COMMITTED_DATA_ONLY を付けていないため、
`SCN` は各変更レコードの **変更時SCN（=実質 START_SCN 相当）** であり、
**コミット時点ではない**。

### 破綻シナリオ1: 長時間トランザクションの欠落

```
時刻 →
T1: ───[変更 SCN=100]──────────────────[COMMIT SCN=250]
                    ↑                          ↑
バッチA: last_scn=90, end_scn=200 で抽出
  → 変更 SCN=100 を抽出してしまう（まだ未コミット！）
バッチB: last_scn=200, end_scn=300 で抽出
  → 変更 SCN=100 は範囲外（100 <= 200）→ 二度と拾われない
```

未コミットの変更を先に適用し、かつ後続バッチでも拾えず、
**ロールバックされたら誤適用・コミットされても重複管理不能**。

### 破綻シナリオ2: ロールバックの誤適用

COMMITTED_DATA_ONLY なしでは、最終的に ROLLBACK された変更も
`V$LOGMNR_CONTENTS` に出現する。現行はこれを delta_queue に入れて適用するため、
**実際には存在しないデータを移行先に作ってしまう**。

### 破綻シナリオ3: 再開点の誤り

現行の再開点 `last_extracted_scn` は「変更SCN」基準。
障害で途中再開すると、未コミットだった長時間Txの扱いが不定になる。

---

## 2. 再設計の原則

報告書の指摘どおり、**境界は COMMIT_SCN で統一**する。

```
原則1: LogMiner は COMMITTED_DATA_ONLY で起動する
        → コミット済みTxだけが、コミット順で返る
        → ROLLBACK 分は出現しない

原則2: バッチ境界は COMMIT_SCN で判定する
        → 「baseline_scn 以降にコミットされた変更」を順次適用
        → WHERE COMMIT_SCN > last_applied_commit_scn

原則3: 再開点は last_applied_commit_scn を台帳で管理する
        → トランザクション単位で適用済みを記録（XID）
        → 同一Txを二度適用しない冪等性
```

---

## 3. COMMITTED_DATA_ONLY の挙動（前提知識）

`DBMS_LOGMNR.START_LOGMNR(OPTIONS => ... + DBMS_LOGMNR.COMMITTED_DATA_ONLY)`
を指定すると:

- **コミット済みトランザクションのみ**が `V$LOGMNR_CONTENTS` に返る
- **同一Txの変更がコミット順にグループ化**されて返る
- 各行に `COMMIT_SCN`（コミットSCN）と `XID`（トランザクションID）が付与される
- ROLLBACK されたTx、未コミットTxは出現しない
- `COMMIT_SCN <= 解析範囲のENDSCN` のものだけが完結したTxとして返る

> 注意: `START_SCN` はトランザクション開始点が解析範囲外だと NULL になりうる。
> よって境界判定には使わず、**必ず `COMMIT_SCN` を使う**（報告書の指摘）。

---

## 4. 再設計後のデータモデル

### 4.1 抽出側 (oracle-src): delta_queue 拡張

現行の delta_queue に COMMIT_SCN / XID を追加する。

```sql
CREATE TABLE cdc_schema.delta_queue (
    delta_id      NUMBER         NOT NULL,   -- 連番（搬送単位内の順序）
    commit_scn    NUMBER(20)     NOT NULL,   -- ★追加: コミットSCN（境界の基準）
    xid           VARCHAR2(40)   NOT NULL,   -- ★追加: トランザクションID
    change_scn    NUMBER(20)     NOT NULL,   -- 変更SCN（旧 scn。Tx内順序の補助）
    seq_in_tx     NUMBER,                    -- ★追加: Tx内の操作順（commit内連番）
    table_name    VARCHAR2(100)  NOT NULL,
    operation     VARCHAR2(20)   NOT NULL,
    sql_redo      VARCHAR2(4000),
    pk_value      VARCHAR2(100),
    extracted_at  TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_delta_queue PRIMARY KEY (delta_id)
);
-- 適用順序の保証: ORDER BY commit_scn, xid, seq_in_tx
```

### 4.2 抽出進捗 (oracle-src): delta_extract_state 変更

```sql
CREATE TABLE cdc_schema.delta_extract_state (
    run_name              VARCHAR2(50)  NOT NULL,
    baseline_scn          NUMBER(20),               -- ★追加: 初期ロードのFLASHBACK_SCN
    last_extracted_commit_scn NUMBER(20) DEFAULT 0 NOT NULL,  -- ★変更: commit基準（高位水準点/HW）
    mine_start_scn        NUMBER(20),               -- ★追加: LogMiner STARTSCN用（低位水準点/LW）
    status                VARCHAR2(20)  DEFAULT 'IDLE',
    last_run_at           TIMESTAMP,
    error_message         VARCHAR2(4000),
    CONSTRAINT pk_delta_extract_state PRIMARY KEY (run_name)
);
```

#### HW（高位水準点）と LW（低位水準点）の役割分担

| 列 | 略称 | 用途 |
|----|------|------|
| `last_extracted_commit_scn` | **HW（High Watermark）** | `WHERE COMMIT_SCN > last_extracted_commit_scn` のフィルタ条件。抽出した最大 COMMIT_SCN へ前進する。「ここ以下のコミットは取得済み」を示す |
| `mine_start_scn` | **LW（Low Watermark）** | `START_LOGMNR(STARTSCN => ...)` に渡す採掘開始点。**未コミットの最古トランザクション開始SCNより前に保つ**ことが不変条件。詳細はセクション5参照 |

この2列を分離することで、「採掘窓を広く取りつつ、適用済み済みコミットは COMMIT_SCN フィルタで排除する」という長時間トランザクション対策が成立する（セクション10.1参照）。

### 4.3 適用台帳 (oracle-tgt): apply_ledger 新設 ★G4の核心

```sql
-- トランザクション単位の適用台帳（冪等性・再開点管理）
CREATE TABLE staging_ctl.apply_ledger (
    xid                VARCHAR2(40)  NOT NULL,   -- トランザクションID
    commit_scn         NUMBER(20)    NOT NULL,   -- コミットSCN
    batch_id           NUMBER,                   -- 搬送バッチID
    change_count       NUMBER,                   -- そのTxの変更行数
    applied_at         TIMESTAMP     DEFAULT SYSTIMESTAMP,
    status             VARCHAR2(20)  DEFAULT 'APPLIED',  -- APPLIED/FAILED
    error_message      VARCHAR2(4000),
    CONSTRAINT pk_apply_ledger PRIMARY KEY (xid, commit_scn)
);

-- 適用進捗のサマリ（再開点）
CREATE TABLE staging_ctl.delta_apply_state (
    run_name                 VARCHAR2(50) NOT NULL,
    last_applied_commit_scn  NUMBER(20)   DEFAULT 0 NOT NULL,  -- ★再開点
    applied_tx_count         NUMBER       DEFAULT 0,
    applied_row_count        NUMBER       DEFAULT 0,
    failed_tx_count          NUMBER       DEFAULT 0,
    last_run_at              TIMESTAMP,
    CONSTRAINT pk_delta_apply_state PRIMARY KEY (run_name)
);
```

---

## 5. 再設計後の抽出ロジック (SYS.delta_extract)

### 5.1 STARTSCN（LW）と COMMIT_SCN フィルタ（HW）の分離

抽出ロジックの核心は「採掘窓の開始点（STARTSCN）」と「コミット済みフィルタの基準点」を
**別々の変数で管理する**点にある。

```
採掘窓: [mine_start_scn ─────────────────── v_end_scn]
                  ↑                                ↑
         LW: 低位水準点                  現在SCN (その時点で確定)
         (START_LOGMNR の STARTSCN)

フィルタ: WHERE COMMIT_SCN > last_extracted_commit_scn
                                    ↑
                           HW: 高位水準点
                           (前回抽出済みの最大 COMMIT_SCN)
```

- `mine_start_scn`（LW）は「まだコミットされていない最古のTxの開始SCN」以前に保つ。
  これにより、今回の採掘窓には「vend_scn 時点でオープンなTxの全変更レコード」が含まれる。
- `last_extracted_commit_scn`（HW）は採掘窓に含まれた行をフィルタして
  「前回より後にコミットされた分だけ」を取り出す役割を持つ。
- 結果として、長時間トランザクションが「STARTSCN よりも前に変更レコードを書いた」場合でも
  欠落しない（セクション10.1で詳述）。

### 5.2 低位水準点（mine_start_scn）の算出

`v_end_scn`（今回の採掘終了点 = 現在SCN）を確定した直後、XEPDB1 コンテナ内で
実行中トランザクションの最古開始SCNを次のクエリで取得する。

```sql
-- PDBローカルの実行中トランザクション最古開始SCNを取得
-- オープンTxが無い場合は v_end_scn をそのまま返す（通常進行）
SELECT NVL(MIN(START_SCN), v_end_scn)
  INTO v_oldest_open_tx_scn
  FROM V$TRANSACTION;

-- 次回の mine_start_scn を決定
-- 「最古オープンTxの開始点」と「通常の再開点(HW+1)」の小さい方
v_next_mine_start := LEAST(v_oldest_open_tx_scn, v_last_commit_scn + 1);
```

不変条件: `mine_start_scn <= 次回採掘時に初めてコミットされる任意のTxのSTART_SCN`

### 5.3 抽出ロジック全体

```sql
-- ステップ1: 採掘終了点を確定（現在SCN）
SELECT CURRENT_SCN INTO v_end_scn FROM V$DATABASE;

-- ステップ2: オープンTx最古SCN取得 → 次回 mine_start_scn を算出（上記参照）

-- ステップ3: CDB$ROOT で LogMiner 起動
--   STARTSCN に LW（mine_start_scn）を使用
--   ※ last_extracted_commit_scn + 1 ではなく mine_start_scn を指定する
DBMS_LOGMNR.START_LOGMNR(
    STARTSCN => v_mine_start_scn,          -- ★ LW: 低位水準点（採掘開始）
    ENDSCN   => v_end_scn,
    OPTIONS  => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG
              + DBMS_LOGMNR.NO_ROWID_IN_STMT
              + DBMS_LOGMNR.COMMITTED_DATA_ONLY   -- ★G3
);

-- ステップ4: COMMIT_SCN 基準で抽出（コミット順・Tx順）
--   HW（last_extracted_commit_scn）より後のコミットのみを取り出す
FOR rec IN (
    SELECT COMMIT_SCN,                    -- ★境界の基準（HWフィルタ）
           XID,                            -- ★トランザクションID
           SCN AS change_scn,              -- 変更SCN（補助）
           SEG_NAME, OPERATION,
           DBMS_LOB.SUBSTR(SQL_REDO, 4000, 1) AS sql_redo_str,
           ROW_NUMBER() OVER (
               PARTITION BY XID ORDER BY SCN, RS_ID, SSN
           ) AS seq_in_tx                  -- ★Tx内順序
    FROM V$LOGMNR_CONTENTS
    WHERE SEG_OWNER = 'SRC_SCHEMA'
      AND OPERATION IN ('INSERT','UPDATE','DELETE')
      AND COMMIT_SCN > v_last_commit_scn   -- ★G2: HW基準のフィルタ
      AND COMMIT_SCN <= v_end_scn
    ORDER BY COMMIT_SCN, XID, SCN, RS_ID, SSN
) LOOP
    -- delta_queue に commit_scn, xid, seq_in_tx 付きで格納
END LOOP;

-- ステップ5: 進捗更新
--   HW: last_extracted_commit_scn = 抽出済みの最大 COMMIT_SCN
--   LW: mine_start_scn = v_next_mine_start（ステップ2で算出済み）
UPDATE cdc_schema.delta_extract_state
   SET last_extracted_commit_scn = v_max_commit_scn,  -- HW 前進
       mine_start_scn             = v_next_mine_start  -- LW 更新
 WHERE run_name = p_run_name;
```

### 5.4 重要な変更点

| 項目 | 現行 | 再設計 |
|------|------|--------|
| LogMiner OPTIONS | DICT + NO_ROWID | **+ COMMITTED_DATA_ONLY** |
| START_LOGMNR STARTSCN | `last_scn + 1` | **`mine_start_scn`（LW）** |
| 抽出フィルタ | `SCN > last_scn` | **`COMMIT_SCN > last_extracted_commit_scn`（HW）** |
| 並び順 | `SCN, RS_ID, SSN` | **`COMMIT_SCN, XID, SCN, RS_ID, SSN`** |
| 進捗キー | last_extracted_scn | **last_extracted_commit_scn（HW）+ mine_start_scn（LW）** |
| 格納列 | scn | **commit_scn, xid, change_scn, seq_in_tx** |
| add_logfiles 基準 | last_scn 相当 | **mine_start_scn（LW）基準** |

---

## 6. 再設計後の適用ロジック (SYS.delta_apply)

```sql
-- 再開点を取得
SELECT last_applied_commit_scn INTO v_last_commit
FROM staging_ctl.delta_apply_state WHERE run_name = p_run_name;

-- 未適用Txを commit_scn, xid 順に処理（トランザクション境界で適用）
FOR rec IN (
    SELECT delta_id, commit_scn, xid, seq_in_tx,
           table_name, operation, sql_redo
    FROM staging_ctl.delta_queue
    WHERE commit_scn > v_last_commit
    ORDER BY commit_scn, xid, seq_in_tx
) LOOP
    -- ★冪等性チェック: この XID+commit_scn が既に台帳にあればスキップ
    IF NOT exists_in_ledger(rec.xid, rec.commit_scn) THEN
        -- SRC→STAGING 置換して適用
        -- Tx の境界（xid 変化）で COMMIT し、apply_ledger に記録
    END IF;
END LOOP;

-- トランザクション単位で apply_ledger に INSERT（冪等性担保）
-- last_applied_commit_scn を「完全に適用しきった最大 commit_scn」に更新
```

### 冪等性の保証

```
再実行・障害再開時:
  1. apply_ledger に (xid, commit_scn) があれば適用済み → スキップ
  2. なければ適用 → 台帳に記録
  3. last_applied_commit_scn は「そのSCN以下の全Txが台帳にある」最大値

→ 同じ搬送ファイルを二度ロードしても二重適用しない
→ 途中で落ちても、台帳にない Tx から再開できる
```

### トランザクション境界での COMMIT（重要）

適用は **Tx 単位（同一 xid）でまとめて COMMIT** する。
1つのTxの途中で COMMIT すると、部分適用状態が生じて整合性が崩れるため、
`xid` が変わるタイミングで DB COMMIT + apply_ledger 記録を行う。

---

## 7. テスト設計（報告書のテストケースに対応）

### T1: 長時間トランザクション境界（G2の核心 / LW設計の主要テスト）

このテストは、`mine_start_scn`（LW）と `last_extracted_commit_scn`（HW）を分離する
設計変更の正しさを直接検証する。旧設計（STARTSCN = HW + 1）では Step 6 で TxA が消失する。

```
手順:
  1. baseline_scn を採番
  2. セッションA: INSERT するが COMMIT しない（長時間Tx開始）
     → この時点の SCN を v_tx_a_start とする
  3. セッションB: 別の行を INSERT して COMMIT（短時間Tx）
     → COMMIT_SCN を v_tx_b_commit とする
  4. delta_extract 実行
     → セッションB だけが抽出される（TxA は未コミット = COMMITTED_DATA_ONLY で排除）
     → HW(last_extracted_commit_scn) = v_tx_b_commit に前進
     → LW(mine_start_scn) = MIN(V$TRANSACTION.START_SCN) ≤ v_tx_a_start に設定
       ※ TxA がまだオープンなので LW は HW より後退したままになる
  5. セッションA を COMMIT
     → TxA の COMMIT_SCN = v_tx_a_commit (> v_tx_b_commit)
  6. delta_extract 再実行
     → STARTSCN = mine_start_scn ≤ v_tx_a_start（LW が保持されているため）
     → TxA の変更レコードが採掘窓に含まれる → COMMITTED_DATA_ONLY が再構成
     → COMMIT_SCN = v_tx_a_commit > HW なのでフィルタを通過
     → TxA が抽出される（欠落なし）
  7. 検証: A も B も「ちょうど1回」適用される（欠落なし・重複なし）
```

### T2: ROLLBACK の非適用（G3）

```
手順:
  1. INSERT して ROLLBACK
  2. delta_extract 実行
  3. 検証: ROLLBACK 分が delta_queue に入らない（COMMITTED_DATA_ONLY 効果）
```

### T3: 障害再開の冪等性（G4）

```
手順:
  1. 差分を搬送して delta_apply を途中まで実行（一部Tx適用）
  2. 強制中断
  3. delta_apply 再実行
  4. 検証: 既適用Txは apply_ledger でスキップ、未適用Txのみ適用
          → STAGING の最終状態が「中断なし実行」と一致
```

### T4: 同一ファイル二重ロード（G4）

```
手順:
  1. delta 搬送 → 適用
  2. 同じダンプファイルを再度 impdp + delta_apply
  3. 検証: 二重適用されない（apply_ledger で防止）
```

---

## 8. 移行ステップ（現行からの差分）

| # | 作業 | 対象ファイル |
|---|------|------------|
| 1 | delta_queue に commit_scn/xid/seq_in_tx/change_scn 追加 | 30_delta_queue_src.sql |
| 1b | delta_extract_state に mine_start_scn 列（LW）追加 | 30_delta_queue_src.sql |
| 2 | delta_extract を COMMITTED_DATA_ONLY + STARTSCN=LW + COMMIT_SCNフィルタ=HW に改修 | 31_pkg_delta_extract_src.sql |
| 3 | tgt 側 delta_queue に同列追加 + apply_ledger 新設 | 32_delta_queue_tgt.sql |
| 4 | delta_apply を Tx境界・台帳ベースに改修 | 33_pkg_delta_apply_tgt.sql |
| 5 | T1〜T4 テストスクリプト作成（T1 は長時間Tx欠落を重点確認） | scripts/11_test_commit_boundary.sh |

---

## 9. この再設計でも残る課題（Phase 2/3 送り）

- **G5/G6**: STAGING→TARGET 変換層・テーブル3分類（Phase 2）
- **G7**: DDL凍結・辞書不一致検知（Phase 3）
- **G12**: ハッシュ・業務集計検証（Phase 3）
- **G13**: LOBフォールバック（COMMIT_SCN化と独立して別途）
- INSERT文のPK抽出（VALUES形式対応。LOBフォールバック時に必要）

---

## 10. 設計上の判断ポイント（レビュー観点）

レビュー時に確認すべき設計判断:

### 10.1 長時間トランザクションで欠落ゼロが保証されるか

#### 問題: STARTSCN = last_commit + 1 方式の落とし穴

旧設計では `START_LOGMNR(STARTSCN => last_extracted_commit_scn + 1, ...)` と指定していた。
これは下記のシナリオで長時間Txの欠落を起こす。

```
バッチN回目の採掘:
  TxA: 変更レコードSCN≈10865136（未コミット）
  TxB: COMMIT_SCN=10865181（コミット済み）

  → COMMITTED_DATA_ONLY により TxB のみ抽出（意図通り）
  → HW を TxB の COMMIT_SCN=10865181 に前進

バッチN+1回目の採掘 (TxA がコミット済, COMMIT_SCN≈10865297):
  旧設計: STARTSCN = 10865181 + 1 = 10865182
  → TxA の COMMIT_SCN(10865297) は採掘窓 [10865182, new_end] に含まれる
  → しかし TxA の最初の変更レコード(SCN≈10865136) は STARTSCN(10865182) より前
  → COMMITTED_DATA_ONLY は採掘窓にTxの開始レコードが含まれないと Tx を再構成不能
  → TxA が永久に消失する ← 致命的バグ
```

`COMMITTED_DATA_ONLY が欠落ゼロを保証するのは「採掘窓がそのTxの開始SCNを含む場合のみ」`
であり、旧設計の「STARTSCN = last_commit + 1」という同一視は誤りである。

#### 解決: HW/LW の分離による不変条件の確立

```
HW（last_extracted_commit_scn）: コミットフィルタの基準点のみに使用
LW（mine_start_scn）           : START_LOGMNR の STARTSCN に使用

不変条件:
  mine_start_scn <= 次回採掘窓終了時点でオープンな任意のTxの START_SCN

この不変条件が成立すれば:
  「v_end_scn 時点でオープンだったTx」は必ず次回の採掘窓 [mine_start_scn, 新end_scn] に
  Tx開始から含まれ、COMMITTED_DATA_ONLY が正しく再構成できる → 欠落しない
```

上記の不変条件は、各バッチ終了時に `V$TRANSACTION` で最古オープンTxの START_SCN を
取得し、それを次回の `mine_start_scn` として記録することで維持される（セクション5.2参照）。

### 10.2 高位水準点(HW)と低位水準点(LW)の分離図解

```
SCN の時系列 ─────────────────────────────────────────────►

        LW                  HW          v_end_scn
   mine_start_scn    last_commit_scn  (現在SCN)
        │                   │              │
        ▼                   ▼              ▼
────────●───────────────────●──────────────●────────
        │←─────── 採掘窓 ──────────────────►│
        │                   │←─ 今回の新規 ─►│
        │                   │  (HWフィルタ)  │
```

採掘窓: `[mine_start_scn, v_end_scn]` — LogMiner が読む範囲
HWフィルタ: `COMMIT_SCN > last_extracted_commit_scn` — 重複排除

- 採掘窓は「まだコミットが到達していない可能性があるTx」の開始点まで後退させて広く取る。
- HWフィルタで「前回バッチ以前にコミット済みのTx」を除外し、採掘窓の重複部分を無視する。
- これにより、採掘窓がどれだけ前後に揺れても、抽出されるのは「ちょうど未取得のコミット分」になる。

#### LW（mine_start_scn）の更新ロジック

| 状況 | 次回 mine_start_scn |
|------|---------------------|
| v_end_scn 時点でオープンTxが存在する | `LEAST(最古オープンTxのSTART_SCN, last_extracted_commit_scn + 1)` |
| オープンTxが存在しない | `last_extracted_commit_scn + 1`（通常進行） |

オープンTxが存在しない場合は HW+1 と LW が一致し、従来の「STARTSCN = last_commit + 1」と
等価になる。長時間Txが存在する場合のみ LW が HW より後退する。

### 10.3 delta_id と commit_scn の二重管理は冗長でないか

delta_id は搬送単位内の物理順、commit_scn は論理境界。役割が違うため両方必要。
再開判定は commit_scn（HW）、Data Pump 搬送は delta_id 範囲で行う。

### 10.4 apply_ledger の肥大化

Tx 単位で1行。5TB初期ロード後の差分のみなので増加は限定的。
カットオーバー後にアーカイブ可能。

### 10.5 XID の一意性

XID は インスタンス内で一意だが、RAC や再起動を跨ぐと再利用されうる。
本検証は単一インスタンスのため (xid, commit_scn) 複合キーで十分。
本番RAC時は thread# を含める検討が必要。
