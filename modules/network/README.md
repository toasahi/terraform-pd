# network

Keep と Dispatcher Lambda を置く VPC です。

- private サブネット（AZ ごと）と、**Regional NAT Gateway**（`availability_mode = "regional"`。aws provider 6.24 以降）で構成します。
- NAT の EIP は AZ ごとに固定するので（手動モード）、egress IP が変わらず、外部サービスの許可リストに登録できます。
- S3 と DynamoDB のゲートウェイエンドポイント（無料）を private ルートテーブルに付けます。
- VPC フローログは CloudWatch Logs に送ります（`enable_flow_logs`）。
- デフォルトのセキュリティグループはルールを空にします（全拒否）。

```hcl
module "network" {
  source          = "../../../../modules/network"
  name            = "alert-platform"
  cidr_block      = "10.40.0.0/20"
  private_subnets = { "ap-northeast-1a" = "10.40.0.0/22", "ap-northeast-1c" = "10.40.4.0/22" }
}
```

出力：`vpc_id`、`vpc_cidr_block`、`private_subnet_ids`、`private_route_table_id`、`nat_gateway_id`、`nat_public_ips`
