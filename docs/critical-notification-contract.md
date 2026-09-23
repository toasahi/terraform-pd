# critical アラート通知の契約（内製ツール / SNS）

critical アラート（`labels.severity` が `critical_severities` に含まれるもの）は、Keep を経由せず次の **2 経路に常時並行して**届けます。router Lambda（`lambda/src/handlers/router.ts`）が送ります。

| 経路 | 位置づけ | 送り先 | 受け手 |
|---|---|---|---|
| 内製ツール | 主経路 | SQS キュー（既定は `alert-pipeline-critical-inhouse.fifo`。`inhouse_notifier_existing_queue_arn` で既存キューも指定可） | 管理アカウントの内製ツール Lambda（SQS イベントソースで起動） |
| SNS | 並行経路 | SNS トピック `alert-pipeline-critical-direct` | メール購読者（`critical_email_endpoints`）。今後 Slack 連携などを購読に追加できる |

- 片方の経路が落ちても、もう片方で届きます。送信に成功した経路は Journal（`delivered_channels`）に記録されます。再試行では失敗した経路だけを送り直すので、成功済みの経路には原則として重複しません。
- それでも配送は **at-least-once** です（送信成功から記録までの間に障害が起きると再送されます）。受け手は `transitionId` で重複を除いてください。
- critical 経路で送信に失敗すると、そのレコードは Keep にも送られずに再試行されます。Keep への配送より critical 通知を優先するためです。

## メッセージ（両経路で同じ JSON、`schemaVersion: 1`）

SQS ではメッセージ本文、SNS では `Message` にそのまま入ります（SNS の `Subject` は `[FIRING] <alertname> (<source>)`）。

```json
{
  "schemaVersion": 1,
  "transitionId": "3f9c…（sha256 hex。重複排除キー）",
  "source": "prod",
  "fingerprint": "prod:a1b2c3d4e5f60708",
  "status": "firing",
  "severity": "critical",
  "alertname": "KubePodCrashLooping",
  "summary": "pod is crash looping",
  "description": "（annotations.description があれば）",
  "startsAt": "2026-09-23T00:00:00Z",
  "endsAt": "（resolved のときのみ）",
  "generatorURL": "http://prometheus/graph?...",
  "receivedAt": "2026-09-23T00:00:01.234Z",
  "labels": { "alertname": "KubePodCrashLooping", "severity": "critical", "namespace": "default" },
  "annotations": { "summary": "pod is crash looping" }
}
```

| フィールド | 意味 |
|---|---|
| `transitionId` | 状態遷移ごとの ID（`sha256(source|fingerprint|status|startsAt)`）。同じ firing の再通知は同じ ID、resolved は別の ID になる。**重複排除キー** |
| `fingerprint` | `<source>:<Alertmanager の fingerprint>`。firing と resolved を対応付けるキー |
| `status` | `firing` または `resolved` |
| `endsAt` | resolved のときのみ（Alertmanager が firing 中に送るゼロ時刻は除外） |

スキーマ定義は `lambda/src/lib/critical.ts` の `CriticalNotification`（Effect Schema）です。互換性のない変更をする場合は `schemaVersion` を上げます。

## 内製ツール側の設定（管理アカウント）

既定では、キューは本リポジトリの `alert-pipeline` ルートが作ります。ARN は出力 `inhouse_notifier_queue_arn` で確認できます。

1. **イベントソースマッピング**：内製ツールの Lambda に、このキューを SQS トリガーとして設定します。
   - `function_response_types = ["ReportBatchItemFailures"]` を推奨します。失敗したメッセージだけを再配信させるためです。
   - FIFO キューでは、失敗したメッセージ以降を同じバッチ内ですべて失敗として返すと、アラート（`MessageGroupId` = fingerprint）ごとの順序（firing → resolved）が保たれます。
2. **IAM**：ツールの実行ロールに `sqs:ReceiveMessage`、`sqs:DeleteMessage`、`sqs:GetQueueAttributes` をこのキューの ARN に対して付与します（同一アカウントなのでキューポリシーは不要）。
3. **タイムアウト**：キューの可視性タイムアウト（既定 900 秒）は、ツール Lambda のタイムアウトの 6 倍以上にします。`inhouse_notifier_visibility_timeout_seconds` で調整できます。
4. **重複排除**：`transitionId` で冪等に処理してください（例：DynamoDB の条件付き書き込み）。
5. **失敗時**：5 回受信しても処理できないと DLQ（`alert-pipeline-critical-inhouse-dlq.fifo`）に移り、アラームが鳴ります。

ツールがすでに別のキューを監視している場合は、`inhouse_notifier_existing_queue_arn` にその ARN を渡すと、そこへ送ります。

- FIFO（`.fifo`）なら、`MessageGroupId` = fingerprint、`MessageDeduplicationId` = transitionId を付けて送ります。
- 標準キューならこの 2 つは付けません。
- キューを SSE-KMS（カスタマー管理キー）で暗号化している場合は、`inhouse_notifier_kms_key_arn` も渡してください。

## 監視

| アラーム | 意味 |
|---|---|
| `alert-pipeline-critical_inhouse-oldest-message-age` | 内製ツールがキューを消費していない（既定 120 秒）。この間、critical は SNS 経路だけで届いている |
| `alert-pipeline-critical_inhouse-dlq-not-empty` | 内製ツールがメッセージを処理できていない |
| `alert-pipeline-router-errors` | どちらかの経路への送信が失敗している（SNS の障害や、キューへの送信権限不足など） |
