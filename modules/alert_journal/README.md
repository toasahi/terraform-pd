# alert_journal

DynamoDB テーブル `AlertEventJournal` です。アラートの状態遷移（`transition_id`）ごとに、耐久性のある冪等な記録を残します。

- 書き込みは Conditional Put（`attribute_not_exists`）で行います。SQS FIFO の重複排除（5 分）は補助的な役割にとどまります。
- 状態は `RECEIVED` → `QUEUED` → `ROUTED` → `KEEP_ACCEPTED` の順に前進のみです（`state_rank` による条件付き更新）。
- GSI `state-updated_at`：`KEEP_ACCEPTED` 未満のまま滞留している遷移を抽出し、再処理や監視に使います。
- **後から変えられない設定を最初から固定しています**（フェーズ 3 のグローバルテーブル化の前提）。
  - Streams は `NEW_AND_OLD_IMAGES`
  - オンデマンド課金
- PITR、TTL（`expires_at`）、削除保護、`prevent_destroy`。

出力：`table_name`、`table_arn`、`stream_arn`
