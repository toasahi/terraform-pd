# keep_platform

Keep（backend / frontend）を ECS Fargate で動かします。internal ALB、RDS PostgreSQL、ElastiCache Valkey（ARQ）、Secrets Manager も含みます。

| 項目 | 内容 |
|---|---|
| backend | `api_desired_count` 個のタスク（既定 2）。`SECRET_MANAGER_TYPE=AWS`、`REDIS=true`、`KEEP_USE_LIMITER=true`、`KEEP_PULL_DATA_ENABLED=false` |
| scheduler | `enable_dedicated_scheduler = true` にすると、API タスクは `SCHEDULER=false` になり、1 タスクの scheduler サービスが別に立ちます。deployment は max 100% / min 0% なので、scheduler が 2 つ同時に動くことはありません |
| frontend | 1 タスク。`API_URL`、`NEXTAUTH_URL`、`NEXTAUTH_SECRET` を渡します |
| ALB | internal、HTTPS（TLS 1.3/1.2）。`ui_domain_name` は UI、`api_domain_name` は API に振り分けます。アクセス元は `alb_ingress_cidrs` のみです |
| RDS | PostgreSQL（既定 17）、Multi-AZ、gp3 暗号化、`rds.force_ssl=1`、PI と拡張モニタリング、削除保護、`prevent_destroy` |
| Valkey | 2 ノード、自動フェイルオーバー、保存時の暗号化。通信の暗号化は Keep 側の対応が未確認のため無効にしています（計画書 U1） |
| 秘密値 | DB パスワード、接続文字列、JWT、NextAuth、管理者パスワードは、ephemeral の `random_password` と `*_wo` 引数で生成します。state には残りません。`secret_version` を上げるとローテーションされます |
| API キー | `api_key_secret_arn` のシークレットに、Keep の UI で発行したキーを運用者が格納します（Dispatcher が使用） |
| イメージ | `api_image` と `ui_image` は `@sha256:` での固定が必須です（validation あり） |

未確認事項（計画書 §14）は変数で是正できます：`api_health_check_path`、`api_extra_environment`、`cpu_architecture`、`cache_engine_version`。
