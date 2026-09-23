# nodejs_lambda_function

Node.js マネージドランタイム（既定は `nodejs24.x` / arm64）の Lambda 関数です。IAM ロール、ロググループ（JSON 形式）、X-Ray も作ります。

- `package_path` には `helpers/build-lambda.sh` が作る `lambda/dist/lambda.zip` を指定します。esbuild のバンドルで、zip は再現可能です。
  - 4 つの関数で同じ zip を使い、`handler`（`index.authorizer` など）で呼び分けます。
  - パッケージが無いと、plan の時点で precondition エラーになります。
- `policy_json` は必須です。関数固有の最小権限を渡してください。値は通常 apply 時まで決まらないため、count の条件には使いません。
- `vpc_config` を指定すると、VPC アクセス用のマネージドポリシーに切り替わります。
- `NODE_OPTIONS=--enable-source-maps` を自動で付けます。

```hcl
module "ingest" {
  source          = "../../../../modules/nodejs_lambda_function"
  function_name   = "alert-pipeline-ingest"
  handler         = "index.ingest"
  package_path    = "${path.module}/../../../../lambda/dist/lambda.zip"
  timeout_seconds = 29
  policy_json     = data.aws_iam_policy_document.ingest.json
}
```

出力：`function_name`、`function_arn`、`invoke_arn`、`role_name`、`role_arn`、`log_group_name`
