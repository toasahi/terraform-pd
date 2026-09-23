# alert_ingress

アラートの受信口です：`POST https://<domain_name>/v1/alerts/{source}`

- **API Gateway REST API（Regional）** を使います。WAF を関連付けられるのは REST のステージだけです（HTTP API は不可）。
- execute-api のデフォルトエンドポイントは無効にし、カスタムドメインだけで受けます（受信 URL を不変にするため）。
- REQUEST オーソライザは `Authorization` ヘッダで判定し、ポリシーを methodArn に限定して返します。Lambda プロキシ統合で ingest に渡します。
- ステージにはアクセスログ（JSON）、X-Ray、スロットリングを設定します。
- 多層の防御：
  - WAF：既定は BLOCK で、許可リストの IP だけを ALLOW します。
  - リソースポリシー：`NotIpAddress` で Deny します。
- **Alertmanager は 4xx（403 と 429 を含む）を再試行しません。** そのため、誤検知しうるルールは既定で COUNT にしてあります。
  - `enable_waf_managed_rules_block` と `enable_waf_rate_limit_block` を true にすると BLOCK になります。
  - `AWSManagedRulesCommonRuleSet` の `SizeRestrictions_BODY`（8KB）は、グループ化された通常の webhook を遮断しうるため、常に COUNT です。
- ACM 証明書（DNS 検証）と Route 53 の A レコード（エイリアス）も作ります。フェーズ 3 ではこれをフェイルオーバーレコードに置き換えます。

API Gateway の CloudWatch Logs 用アカウント設定（`aws_api_gateway_account`）は、アカウントとリージョンで 1 つしか持てないため、ルートモジュール側で管理します。

出力：`endpoint_url`、`rest_api_id`、`rest_api_name`、`stage_name`、`stage_arn`、`web_acl_name`、`web_acl_arn`、`regional_domain_name`、`regional_zone_id`
