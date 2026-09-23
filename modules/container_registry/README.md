# container_registry

プライベート ECR リポジトリです。タグは IMMUTABLE で、KMS 暗号化、push 時のスキャン、世代数による期限切れを設定します。

Keep のイメージは Google Artifact Registry（`us-central1-docker.pkg.dev/keephq/keep/*`）で配布されています。ECR のプルスルーキャッシュは GAR に対応していないため、`helpers/mirror-keep-images.sh` でミラーし、digest で固定して参照してください。

出力：`repository_urls`、`repository_arns`（リポジトリ名がキー）
