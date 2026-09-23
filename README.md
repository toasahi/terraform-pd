# terraform-pd

PagerDuty から Keep への置き換えのうち、**フェーズ 1（東京 MVP）** の IaC です。管理アカウント（ap-northeast-1）に次の 2 つを構築します。

- 受信パイプライン：API Gateway REST + WAF → Lambda → DynamoDB Journal / SQS FIFO → Keep
- Keep 基盤：ECS Fargate、RDS PostgreSQL、ElastiCache Valkey

- 計画書・前提確認・最終裁定：[`docs/implementation-plan.md`](docs/implementation-plan.md)
- 送信元（本番 / 管理 EKS）の設定：[`docs/alertmanager-receiver.md`](docs/alertmanager-receiver.md)
- critical アラートの直送（内製ツール / SNS）の契約：[`docs/critical-notification-contract.md`](docs/critical-notification-contract.md)

## 構成

```
modules/                       再利用モジュール（provider は設定しない。バージョンは下限のみ）
  network/                     VPC、private サブネット、Regional NAT（EIP 固定）、ゲートウェイエンドポイント、フローログ
  container_registry/          ECR（Keep イメージのミラー先）
  alert_journal/               DynamoDB AlertEventJournal（NEW_AND_OLD_IMAGES、削除保護）
  alert_queues/                SQS FIFO + DLQ
  nodejs_lambda_function/      Lambda（nodejs24.x / arm64）、IAM、ロググループ
  alert_ingress/               API Gateway REST（Regional）、REQUEST オーソライザ、WAF、カスタムドメイン
  keep_platform/               Keep（ECS、internal ALB、RDS、Valkey、Secrets）
  alert_monitoring/            パイプライン自体のアラーム
envs/management/ap-northeast-1/ ルートモジュール（provider とバージョン固定、ロックファイル）
  backend.hcl                  S3 backend の共通設定（use_lockfile）
  bootstrap/                   tfstate 用 S3 バケット
  foundation/                  network + container_registry
  keep/                        keep_platform
  alert-pipeline/              Journal、キュー（内製ツール用を含む）、Lambda ×4、ingress、SNS、監視
lambda/                        TypeScript + Effect（Node.js 24、pnpm、esbuild、vitest）
helpers/                       build-lambda.sh、mirror-keep-images.sh
```

## 必要なツール

| ツール | バージョン |
|---|---|
| Terraform | >= 1.16（CI は 1.16.4） |
| hashicorp/aws | ~> 6.66（ロック済み） |
| Node.js | 24（Lambda ランタイムは `nodejs24.x`） |
| pnpm | 12.6.0（`corepack enable` で `package.json` の `packageManager` を使う） |
| crane、aws CLI | イメージのミラーに使う |

## 適用手順（初回）

各ルートでは `terraform init -backend-config=../backend.hcl` を実行します。bootstrap の初回だけは例外です。値は各ルートの `terraform.tfvars`（プレースホルダ）を実環境の値に置き換えてください。

1. **bootstrap**（tfstate バケット）

   ```bash
   cd envs/management/ap-northeast-1/bootstrap
   mv backend.tf backend.tf.off && terraform init && terraform apply   # 初回はローカル state で作る
   mv backend.tf.off backend.tf && terraform init -backend-config=../backend.hcl -migrate-state
   ```

2. **foundation**：`terraform apply`。出力の `nat_public_ips` は Keep の egress IP です。
3. **Keep イメージのミラー**：`helpers/mirror-keep-images.sh --version <tag> --account <id>` を実行し、表示された digest を `keep/terraform.tfvars` に設定します。
4. **keep**：`terraform apply`。
5. **Keep API キー**：Keep の UI で発行し、`aws secretsmanager put-secret-value --secret-id keep/api-key-dispatcher --secret-string <key>` で保存します。
6. **Lambda のビルド**：`helpers/build-lambda.sh` で `lambda/dist/lambda.zip` を作ります（未ビルドのまま plan すると precondition でエラーになります）。
7. **alert-pipeline**：`terraform apply`。
8. **内製ツールの接続**：出力 `inhouse_notifier_queue_arn` を内製ツール Lambda のイベントソースに設定します（[`docs/critical-notification-contract.md`](docs/critical-notification-contract.md)）。
9. **送信元の登録**：[`docs/alertmanager-receiver.md`](docs/alertmanager-receiver.md) の手順で、トークンの digest 登録と Alertmanager の receiver 追加を行います。

## 開発と検証

```bash
# Lambda
cd lambda && corepack enable && pnpm install && pnpm typecheck && pnpm test && pnpm build

# Terraform（リポジトリのルートで実行）
terraform fmt -check -recursive
for d in modules/* envs/*/*/*/; do terraform -chdir="$d" init -backend=false && terraform -chdir="$d" validate; done
terraform -chdir=modules/alert_ingress test          # tests/ があるディレクトリ（モックプロバイダ、AWS 資格情報は不要）
tflint --init && tflint --recursive --config "$PWD/.tflint.hcl"
checkov -d . --config-file .checkov.yaml
```

CI（`.github/workflows/ci.yml`）では、上記に加えて Lambda のビルド成果物（`lambda.zip`）をアップロードします。
