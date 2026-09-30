# network

Keep と Dispatcher Lambda を置く VPC です。

- private サブネット（AZ ごと）の既定ルート（`0.0.0.0/0`）は、**共有 Transit Gateway**（`transit_gateway_id`）に向けます。IGW、NAT Gateway、EIP は持ちません。
- VPC のアタッチメントと Transit Gateway 側のルートはネットワーク側が作ります。`transit_gateway_id = null` の間は既定ルートを作りません。設定した後は、この VPC のアタッチメントが `available` であることを precondition で確かめてからルートを作ります。
- S3 と DynamoDB のゲートウェイエンドポイント（無料）を private ルートテーブルに付けます。
- VPC フローログは CloudWatch Logs に送ります（`enable_flow_logs`）。
- デフォルトのセキュリティグループはルールを空にします（全拒否）。

```hcl
module "network" {
  source          = "../../../../modules/network"
  name            = "alert-platform"
  cidr_block      = "10.40.0.0/20"
  private_subnets = { "ap-northeast-1a" = "10.40.0.0/22", "ap-northeast-1c" = "10.40.4.0/22" }

  transit_gateway_id = "tgw-..."
}
```

出力：`vpc_id`、`vpc_cidr_block`、`private_subnet_ids`、`private_route_table_id`
