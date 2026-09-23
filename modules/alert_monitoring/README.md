# alert_monitoring

アラートパイプライン自体を監視するアラームと、その通知先の SNS トピックを作ります。CloudWatch アラームは `aws/sns` で暗号化されたトピックに発行できないため、トピックは CMK で暗号化します。

| アラーム | 条件 |
|---|---|
| `<queue>-oldest-message-age` | 最古メッセージの経過時間がしきい値を超えた |
| `<queue>-dlq-not-empty` | DLQ に可視メッセージがある |
| `<fn>-errors` / `<fn>-throttles` | Lambda の Errors / Throttles |
| `api-client-errors` / `api-server-errors` | API Gateway の 4XX / 5XX。4xx は Alertmanager が再試行しないため、通知の欠落を意味します |
| `waf-blocked-requests` | WAF の BlockedRequests |
| `<service>-running-tasks` | ECS の RunningTaskCount が下限を下回った |

出力：`alarm_topic_arn`
