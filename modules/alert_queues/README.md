# alert_queues

SQS FIFO キューと DLQ を、`queues` のキーごとに作ります。

- `MessageGroupId` は `<source>:<fingerprint>`（アラート単位の順序保証）、`MessageDeduplicationId` は `transition_id` を使います。
- 高スループット FIFO（`deduplication_scope = messageGroup`、`fifo_throughput_limit = perMessageGroupId`）を使います。
- `visibility_timeout_seconds` は、消費側 Lambda のタイムアウトの 6 倍以上にしてください。
- 暗号化は SSE-SQS（`kms_master_key_id` を指定すると SSE-KMS）です。DLQ の redrive allow policy は元のキューだけを許可します。

```hcl
queues = {
  alerts        = { visibility_timeout_seconds = 180 }
  keep_delivery = { visibility_timeout_seconds = 360 }
}
```

出力：`queue_urls`、`queue_arns`、`queue_names`、`dead_letter_queue_names`、`dead_letter_queue_arns`
