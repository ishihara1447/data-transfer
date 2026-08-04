# 差分移行方式の判断基準

作成日: 2026-07-28
状態: 設計方針確定、テーブル別の採用方式は PoC 後に確定

## 1. 結論

差分同期は「更新日時列あり / なし」の二分だけで決めない。変更検出、行データ取得、DELETE 捕捉、搬送、適用を分離し、テーブル特性ごとに方式を選ぶ適応型ハイブリッド方式を採用する。

ただし、次の方式は現時点では候補であり、本番採用確定ではない。

- 更新日時条件の直接 `expdp QUERY`
- 更新日時条件で差分表を固定してから Export
- LogMiner 変更キー + SCN 固定スナップショット
- パーティション単位 Export
- 現行 LogMiner SQL_REDO 適用

方式の優劣は固定の差分率では決めず、`docs/delta-performance-poc-plan.md` の結果でテーブル群ごとに決める。

## 2. 再評価結果

2026-07-27 版「Oracle更新日時差分ダンプ方式 再検証・高度化検討書」
（SHA-256: `9AD89869D298905A73BC018C78A8F3427FF80F7BCB11CEE3C5D1C1014C240013`）を、
Oracle 12c 公式仕様と現行リポジトリの実装・実測結果に照合した。

| 主張 | 判断 | 根拠・補正 |
|---|---|---|
| `expdp QUERY` は External Table 経路を使う | 確認済み | Oracle 12.2 仕様と `docs/datapump-performance-analysis.md` B4 の実測が一致 |
| 物理 DELETE は更新日時条件だけでは取得できない | 確認済み | 削除後の行は元表に存在しないため、LogMiner 等の別経路が必要 |
| 更新日時とコミット時刻は一致しない | 確認済み | 遅延コミットが重複窓を超えると欠落し得る。更新日時方式単独では欠落ゼロを証明しない |
| 索引があれば常に高速 | 不採用 | 選択率、行幅、LOB、クラスタリング・ファクタ、I/O に依存。実測で決める |
| 差分率に共通の採用しきい値がある | 不採用 | 0.1%、1%、5% 等は試験点であり採用基準ではない |
| LogMiner 変更キー + SCN 固定スナップショット | 設計候補 | 正確性上は有力。ただし実行場所、逆方向搬送、UNDO 保持、複合主キーを PoC する |
| High Water Mark を1本だけ持つ | 補正 | `LOGMINER_READER`、スナップショット固定、`APPLY_WRITER`、変換、検証のチェックポイントを分離する |
| 管理表を7本新設する | 補正 | 既存の `LOGMINER_BATCH`、`MINED_CHANGE`、`APPLY_BATCH`、`APPLY_TASK`、`MIG_CHECKPOINT` を再利用し、不足分だけ追加する |

## 3. 共通設計原則

1. 正確性の境界は業務日時ではなくコミット SCN とする。
2. SCN 範囲は `(S_prev, S_upper]` の半開区間で管理する。
3. 変更検出と最終行イメージ取得を別工程として扱う。
4. INSERT/UPDATE は最終状態へ圧縮できるが、DELETE と主キー更新を必ず別途扱う。
5. LOB は通常列と同じ性能前提に置かない。
6. 各チェックポイントは対応工程と同一トランザクション、または検証済みファイル受領後にだけ進める。
7. Export 単体ではなく、変更検出から変換・検証までの所要時間とソース影響で判断する。
8. 21c XE の絶対性能値を本番 12c / 5TB / 500表の見積りに使わない。

## 4. 方式判断表

| クラス | 第一候補 | 必須条件 | 主な弱点 | 判定状態 |
|---|---|---|---|---|
| A: 小～中規模、更新日時が信頼できる | 更新日時 + `FLASHBACK_SCN` + `expdp QUERY` | INSERT/UPDATE時に必ず更新、型・TZ・設定主体が明確、遅延コミット上限を把握 | External Table、DELETE不可、長時間Tx | PoC対象 |
| B: 更新日時は使えるが再Export性を重視 | 更新日時で固定差分表を作成してExport | 固定表作成コストが許容、再利用・監査価値がある | 元表読込みと固定表I/Oの二重化 | PoC対象 |
| C: 大規模、高更新、反復更新、DELETEあり | LogMiner変更キー + SCN固定スナップショット | 主キー抽出可、UNDO保持可、逆方向搬送または移行元LogMiner可 | 実行構成が複雑、ランダムI/O、UNDO | 重点PoC |
| D: 既存日付パーティション表 | パーティション単位Export | 差分境界とパーティション境界が整合、過去領域更新を捕捉 | 過去パーティション更新、行移動 | 対象表限定 |
| E: 巨大LOB表 | 変更キー + LOB専用再同期 | LOB更新検出または最終再同期が可能 | 搬送量、UNDO、LOB比較コスト | 既存方式と比較 |
| F: PK抽出不可、特殊型、順序再現必須 | 現行LogMiner方式 / 手動確認キュー | SQL_REDO安全分類、冪等適用、レビュー経路 | SQL文字列依存、CSF、LOB | フォールバック |

## 5. 採用ゲート

各テーブルは次を満たすまで方式を確定しない。

- 主キー列順、型、複合主キー、主キー更新有無を確認済み
- 更新日時列の設定ロジック、精度、タイムゾーン、最大遅延コミットを確認済み
- INSERT / UPDATE / DELETE 件数とユニーク変更キー数を計測済み
- LOB、特殊型、パーティション、FK依存を確認済み
- 正確性試験で欠落0、最終重複0、DELETE一致、同一バッチ再実行一致
- 実際の Data Pump ログで Access Method を確認済み
- ソースDB影響、追従余力、最終停止時間を評価済み

テーブルごとの決定は、将来追加する方式カタログに理由、PoC結果、承認日とともに記録する。

## 6. 関連成果物

- `docs/update-timestamp-subdump-design.md`: クラスA/Bの設計
- `docs/dirty-key-snapshot-design.md`: クラスC/Eの設計
- `docs/delta-performance-poc-plan.md`: 比較PoCと合格基準
- `docs/datapump-performance-analysis.md`: 現行環境での確認済み事実
- `docs/phase4-design.md`: LogMiner管理基盤と差分適用設計

## 7. 公式仕様

- [Oracle 12.2 Data Pump Overview](https://docs.oracle.com/en/database/oracle/oracle-database/12.2/sutil/oracle-data-pump-overview.html)
- [Oracle 12.2 Data Pump Export QUERY](https://docs.oracle.com/en/database/oracle/oracle-database/12.2/sutil/oracle-data-pump-export-utility.html)
- [Oracle 12c DBMS_LOGMNR](https://docs.oracle.com/database/121/ARPLS/d_logmnr.htm)
- [Oracle 12.2 LogMiner Utility](https://docs.oracle.com/en/database/oracle/oracle-database/12.2/sutil/oracle-logminer-utility.html)
- [Oracle 12.2 UNDO_RETENTION](https://docs.oracle.com/en/database/oracle/oracle-database/12.2/refrn/UNDO_RETENTION.html)
