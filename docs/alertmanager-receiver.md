# 送信元（本番 EKS / 管理 EKS）の Alertmanager 設定手順

受信口 `https://alerts.<zone>/v1/alerts/<source>` にアラートを送るための、送信側の設定です。対象の送信元は `prod`（本番アカウントの EKS）と `management`（管理アカウントの EKS）の 2 つだけです。

## 1. 送信元の egress IP を固定し、登録する

WAF の IP セットとリソースポリシーは、送信元の NAT の egress IP だけを許可します。

1. 各 EKS VPC の NAT Gateway に**固定の EIP**を割り当てます。Regional NAT の自動モードではアドレスが増えることがあるため、手動モード（`availability_zone_address`）にするか、ゾーナル NAT を使います。
2. `envs/management/ap-northeast-1/alert-pipeline/terraform.tfvars` の `alert_sources.<source>.egress_cidrs` に `/32` で登録し、apply します。

> 許可リストから漏れると WAF が 403 を返します。**Alertmanager は 4xx を再試行しない**ため、その通知は欠落します。`alert-pipeline-waf-blocked-requests` アラームで検知します。

## 2. 送信元トークンを発行し、digest を登録する

トークン本体は送信元側だけが持ちます。受信側の Secrets Manager には sha256 の digest だけを保存します。

```bash
# 送信元ごとにトークンを生成する（例: prod）
TOKEN=$(openssl rand -hex 32)
DIGEST=$(printf '%s' "$TOKEN" | sha256sum | cut -d' ' -f1)

# 1) トークン本体を送信元アカウントの秘密ストアに保存する（例: 本番アカウントの Secrets Manager。External Secrets で Alertmanager に配る）
aws secretsmanager create-secret --name alertmanager/keep-ingest-token --secret-string "$TOKEN" --profile prod

# 2) digest を管理アカウントの受信側シークレットに登録する（全送信元をまとめた JSON）
aws secretsmanager put-secret-value --profile management \
  --secret-id alert-pipeline/source-token-digests \
  --secret-string "{\"prod\":[\"$DIGEST\"],\"management\":[\"<management の digest>\"]}"
```

- **ローテーション**：新旧の digest を配列で併記して登録し、送信元のトークンを切り替えた後に旧 digest を外します。オーソライザはシークレットを 5 分、判定結果を 5 分（API Gateway 側）キャッシュします。
- オーソライザはポリシーを呼び出し先の methodArn に限定して返すため、`prod` のトークンで `/v1/alerts/management` は呼べません。

## 3. Alertmanager の receiver を追加する（PagerDuty との並行運用）

```yaml
# alertmanager.yaml（kube-prometheus-stack などの values に合わせて書き換える）
route:
  receiver: pagerduty            # フェーズ 1 の間は既存の PagerDuty ルートを残す
  routes:
    - receiver: keep-pipeline
      matchers: []               # 全アラートを Keep パイプラインにも送る
      continue: true
receivers:
  - name: keep-pipeline
    webhook_configs:
      - url: https://alerts.mgmt.example.com/v1/alerts/prod   # 管理 EKS では .../management
        send_resolved: true
        max_alerts: 0
        http_config:
          authorization:
            type: Bearer
            credentials_file: /etc/alertmanager/secrets/keep-ingest-token/token
```

- `send_resolved: true` にします。resolved は別の transition_id として記録されます。
- ラベル `severity` の値が `critical_severities`（既定は `critical`）に含まれるアラートは、Keep を経由せず SNS の critical-direct にも送られます。
- 受信側は webhook ペイロード v4 を Schema で検証します。形式が不正なら 400 を返します（再試行されません）。`alert-pipeline-api-client-errors` アラームで検知します。

## 4. 疎通確認

```bash
curl -sS -X POST "https://alerts.mgmt.example.com/v1/alerts/prod" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"version":"4","groupKey":"test","status":"firing","receiver":"keep-pipeline","alerts":[{"status":"firing","labels":{"alertname":"PipelineSmokeTest","severity":"info"},"startsAt":"2026-09-23T00:00:00Z","fingerprint":"smoke0001"}]}'
# => {"source":"prod","accepted":1,"requeued":0,"duplicates":0}
```

もう一度同じリクエストを送ると `duplicates: 1` になります（Journal による冪等性）。
