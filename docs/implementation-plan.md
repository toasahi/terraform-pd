# PagerDuty → Keep 置き換え フェーズ 1（東京 MVP）IaC 実装計画書

- 作成日: 2026-09-23
- 対象: `pagerduty_to_keep_architecture_review_v4.md`（v4 に対するレビュー、裁定「条件付き Go」）
- 対象範囲: **フェーズ 1（東京 MVP）の IaC**。大阪 DR（フェーズ 3）は「後から変えない前提」の担保のみを行う
- 方針
  - 推論ではなく一次情報源（公式ドキュメント、公式リポジトリのソースコード、パッケージレジストリ）で前提を裏取りする。
  - 裏取りできなかった項目は「未確認」として分ける。
  - Terraform は Google Cloud の [Terraform を使用するためのベスト プラクティス](https://docs.cloud.google.com/docs/terraform/best-practices/general-style-structure?hl=ja) に従って書く。

---

## 1. 目的と範囲

| 項目 | 内容 |
|---|---|
| 目的 | レビュー v4 の条件付き Go を受け、フェーズ 1（東京 MVP）の受信パイプラインと Keep 基盤を Terraform でコード化する。修正必須事項（REST API への変更など）をコードで担保する |
| 範囲内 | 次の要素を管理アカウント（ap-northeast-1）に作る <br>- 受信口（API Gateway REST + WAF + Lambda オーソライザ）<br>- Journal（DynamoDB）<br>- FIFO キュー<br>- Lambda 4 本（TypeScript + Effect / Node.js 24）<br>- critical 直送（SNS）<br>- Keep（ECS Fargate、RDS PostgreSQL、ElastiCache Valkey、internal ALB）<br>- ネットワーク（Regional NAT）<br>- 監視<br>- tfstate 基盤 |
| 範囲外 | 次の 3 つ <br>- 大阪 DR の実リソース（フェーズ 3）<br>- 送信元（本番 EKS と管理 EKS）の Alertmanager 設定そのもの（設定例は `docs/alertmanager-receiver.md`）<br>- Keep のワークフロー定義（YAML） |
| 前提 | アカウントは開発、ステージング、本番、管理の 4 つ。アラートの送信元は **本番 EKS と管理 EKS のみ**で、**管理アカウントの ECS（Keep）に集約**する |

## 2. 前提確認の結果

### 2.1 レビュー v4 の 14 項目

レビュー v4 の第 2 節で一次情報源と照合済みのため、本計画ではその結果をそのまま採用する。IaC に直接効くものは次のとおり。

| レビュー # | 内容 | IaC での反映箇所 |
|---|---|---|
| 5 | SQS FIFO の重複排除は 5 分 | `modules/alert_queues`。重複排除の本体は Journal の Conditional Put（`lambda/src/lib/journal.ts`） |
| 6 | Lambda/SQS のイベントソースは同一リージョンに限られる | 各リージョンの `alert-pipeline` ルートに、キューと Lambda を同居させる |
| 7 | Route 53 は CloudWatch アラーム型のヘルスチェックが使える | `modules/alert_ingress/domain.tf` のコメントで、フェーズ 3 の切り替え方式を固定している |
| 8 | Regional NAT Gateway | `modules/network`（`availability_mode = "regional"`） |
| 12 | DynamoDB Streams は `NEW_AND_OLD_IMAGES` にする | `modules/alert_journal`（テストで固定） |
| 14 | Keep の amazonsqs アクション | `keep_platform` の `sqs_send_queue_arns` で送信権限を付与する |

### 2.2 本計画で追加に裏取りした事実

| # | 事実 | 一次情報源 | 設計への反映 |
|---|---|---|---|
| A | Lambda の Node.js マネージドランタイムには `nodejs22.x`、`nodejs24.x`、`nodejs26.x` がある | botocore Lambda モデルの Runtime enum（`boto/botocore` `data/lambda/2015-03-31/service-2.json`）。aws provider 6.66.0 のバイナリ内の定義でも確認 | **`nodejs24.x` / arm64** を採用する（Node 24 は 2026-09 時点の Active LTS） |
| B | `effect` の安定版は 3.22.2。v4 は RC（`4.0.0-rc.117`） | npm レジストリの dist-tags、`Effect-TS/effect` の README | `effect@^3.22` を採用する。v4 は GA 後に移行を検討する |
| C | Keep の push API は `POST /alerts/event/{provider_type}` で 202 を返す。API キーは `X-API-KEY`、`?api_key=`、Basic のいずれかで渡す。**`Authorization: Bearer` は OAuth トークンとして扱われる** | `keephq/keep` の `keep/api/routes/alerts.py`、`keep/identitymanager/authverifierbase.py` | Dispatcher は `X-API-KEY` で送る |
| D | Keep の prometheus プロバイダは Alertmanager の `fingerprint` をそのまま使う。クエリの `?fingerprint=` が優先される | `keep/providers/prometheus_provider/prometheus_provider.py`、`alerts.py` | 送信元のスコープを付けた fingerprint（`<source>:<fp>`）を明示的に渡す |
| E | Alertmanager の webhook は **5xx のみ再試行し、429 を含む 4xx は再試行しない** | `prometheus/alertmanager` の `notify/util.go`（Retrier）、`notify/webhook/webhook.go` | Ingest の内部失敗は必ず 5xx で返す。WAF のレート制限とマネージドルールは COUNT を既定にする。4xx と WAF ブロックは即アラーム |
| F | SQS ESM の `scaling_config.maximum_concurrency` は SQS 専用で、最小 2・最大 1000。FIFO ではメッセージグループ数との小さい方で頭打ちになる。予約同時実行数はこの値以上にする必要がある | botocore Lambda モデル（ScalingConfig）、terraform-provider-aws のドキュメント。FIFO と予約同時実行数に関する文言は AWS 開発者ガイドの検索抜粋（本文は未取得） | Dispatcher の同時実行上限を ESM 側で持つ（既定 3、2〜5 を validation で強制）。予約同時実行数がこれ以上であることも validation で強制する |
| G | ECR プルスルーキャッシュの上流に Google Artifact Registry（`*.pkg.dev`）は含まれない | botocore ECR モデル（UpstreamRegistry の enum） | `helpers/mirror-keep-images.sh`（crane）でミラーし、digest で固定する |
| H | aws provider の Regional NAT 対応は v6.24.0 から。最新は v6.66.0 | `hashicorp/terraform-provider-aws` の CHANGELOG と `r/nat_gateway` のドキュメント | モジュールは `>= 6.24`、ルートは `~> 6.66` |
| I | S3 backend のネイティブロック（`use_lockfile`）は Terraform 1.10 で導入、1.11 で GA。DynamoDB ロックは非推奨 | `hashicorp/terraform` の CHANGELOG（v1.10 / v1.11） | `backend.hcl` で `use_lockfile = true`。CLI は 1.16.4 |
| J | WAF の関連付け先は REST API のステージのみ（HTTP API は不可） | terraform-provider-aws `r/wafv2_web_acl_association`、AWS の HTTP API と REST API の比較表 | `modules/alert_ingress` は REST（Regional）に固定 |
| K | 書き込み専用引数（`password_wo`、`secret_string_wo`）と ephemeral の `random_password` が使える | aws provider 6.66.0 と random 3.9.1 の provider schema（`terraform providers schema -json`） | 秘密値を plan や state に残さない（`keep_platform/secrets.tf`） |

**不採用の経緯**: 当初は Lambda ランタイムに Bun を検討したが、ユーザー判断により Node.js（マネージド）に変更した。なお、`oven-sh/bun` の `packages/bun-lambda` レイヤーには 2 つの問題があることをソース（`runtime.ts`）で確認している。非 HTTP イベントでは handler の例外を成功として扱い、SQS のメッセージが消える。また、REST の REQUEST オーソライザに応答できない。

## 3. アカウントとリージョンの構成

```
┌──────────────── 本番アカウント ────────────────┐   ┌─────────── 管理アカウント (ap-northeast-1) ───────────┐
│ EKS  ─ Alertmanager ─(NAT 固定 EIP)────────────┼──▶│ Route53 alerts.<zone> → API GW REST + WAF          │
└────────────────────────────────────────────────┘   │   → authorizer λ → ingest λ → Journal / alerts.fifo  │
┌──────────────── 管理アカウント ────────────────┐   │   → router λ ─┬→ SNS critical-direct（Keep 非依存）│
│ EKS  ─ Alertmanager ─(NAT 固定 EIP)────────────┼──▶│               └→ keep-delivery.fifo               │
└────────────────────────────────────────────────┘   │   → dispatcher λ(VPC) → internal ALB → Keep(ECS)    │
  開発 / ステージング: 送信しない                     │   Keep: RDS PostgreSQL / ElastiCache Valkey          │
                                                      └──────────────────────────────────────────────────────┘
```

- Keep、受信パイプライン、Route 53 ホストゾーン、フェーズ 3 の canary アラームは、すべて**管理アカウント**に置く。レビュー 3.4 の指摘どおり、Route 53 はクロスアカウントの CloudWatch アラームを扱えないため。
- 送信元の識別は URL のパス（`/v1/alerts/prod`、`/v1/alerts/management`）と送信元ごとのトークンで行う。ネットワーク上の制限として、WAF の IP セットとリソースポリシーに送信元 NAT の EIP を登録する。

## 4. 全体構成とデータフロー

```
Alertmanager --(HTTPS, Authorization: Bearer <送信元トークン>)-->
  alerts.<zone>（パブリックゾーン, API GW カスタムドメイン, TLS1.2+）
  → WAF（既定 BLOCK, 送信元 IP のみ ALLOW, マネージドルールとレート制限は COUNT）
  → リソースポリシー（NotIpAddress で Deny）
  → authorizer λ（REQUEST, sha256(token) を送信元ごとの digest と timingSafeEqual で比較, methodArn 限定の Allow）
  → ingest λ
      transition_id = sha256(source|fingerprint|status|startsAt)
      Journal に PutItem（attribute_not_exists）: state=RECEIVED
      alerts.fifo へ SendMessage（group=<source>:<fingerprint>, dedup=transition_id）→ state=QUEUED
      内部失敗は 500（Alertmanager が再送する。RECEIVED のまま残ったものは再送時に再キューイング）
  → router λ（alerts.fifo, ESM max 10）
      severity ∈ critical_severities → SNS critical-direct（メール、PagerDuty SNS 連携 URL など）
      全件を keep-delivery.fifo へ → state=ROUTED
  → dispatcher λ（keep-delivery.fifo, VPC 内, ESM max 3, 予約同時実行数 3）
      POST https://keep-api.<zone>/alerts/event/prometheus?fingerprint=<source>:<fp>（X-API-KEY）
      202 → state=KEEP_ACCEPTED（202 は「受付」であって永続化完了ではない。レビュー #2）
```

- **状態は前進のみ**: Journal の `state_rank` を条件付きで更新するため、並行実行や再配信でも状態は戻らない。
- **FIFO の部分失敗**: 最初に失敗したメッセージ以降はバッチ内をすべて失敗として返す（`ReportBatchItemFailures`）。これでメッセージグループ内の順序を保つ。
- **DLQ**: `maxReceiveCount` は 5。可視性タイムアウトは消費側 Lambda のタイムアウトの 6 倍。
- **再処理**: Journal の GSI `state-updated_at` で、`KEEP_ACCEPTED` 未満のまま一定時間が過ぎたものを抽出する。payload は Journal に保存してあるので keep-delivery.fifo に再投入できる。

## 5. Terraform の設計方針（ベストプラクティスとの対応）

| Google Cloud のベストプラクティス | 本リポジトリでの実装 |
|---|---|
| 標準モジュール構成（`main.tf`、`variables.tf`、`outputs.tf`、README） | 全モジュールに用意した。資源の多いモジュールは `waf.tf`、`domain.tf`、`services.tf`、`data_stores.tf`、`iam.tf` のように用途別のファイルに分けた |
| ルートモジュールは環境ディレクトリに置き、資源数を抑える | `envs/management/ap-northeast-1/{bootstrap,foundation,keep,alert-pipeline}` の 4 ルートに分けた。ライフサイクルと影響範囲で分割している |
| 命名：スネークケース、単数形、型名を繰り返さない、単独なら `main` | 例：`aws_lambda_function.main`、`aws_sqs_queue.dead_letter` |
| 変数：description と type は必須、数値には単位を付ける、真偽値は肯定形 | 例：`timeout_seconds`、`memory_size_mb`、`log_retention_days`、`enable_dedicated_scheduler`、`enable_waf_rate_limit_block` |
| 環境依存の値には default を置かない | `account_id`、`public_zone_name`、`alert_sources`、イメージの digest などは tfvars で必須 |
| 出力は入力を素通しせず、リソース属性から出す | 例：`keep_platform.api_url` は Route 53 レコードの fqdn から組み立てる |
| データソースは使う側の近くに置く | 例：`aws_route53_zone` は `ingress.tf` と `keep/main.tf` に置いた |
| 共有モジュールで provider を設定しない。バージョンは下限のみ | modules の `versions.tf` は `>=` のみ。ルートで `~> 6.66` に固定し、`.terraform.lock.hcl` をコミットする（ルートのみ） |
| ステートフルなリソースを保護する | Journal、RDS、tfstate バケットに `prevent_destroy` と削除保護を付けた |
| 秘密値を state に置かない | ephemeral の `random_password` と `*_wo` 引数を使う。Keep の API キーと送信元トークンは運用者が投入する |
| ルート間はリモートステートで連携する | `terraform_remote_state`（S3）で foundation → keep → alert-pipeline の順に参照する |
| ロック付きのバックエンド | S3 + `use_lockfile`（Terraform 1.11 以降。DynamoDB ロックは使わない） |
| `terraform fmt`、CI、plan を先行させる | CI で fmt、validate、`terraform test`（モック）、tflint（aws ruleset）、checkov を実行する |
| 呼び出さない補助スクリプトは `helpers/` に置く | `helpers/build-lambda.sh`、`helpers/mirror-keep-images.sh`（`--help` と引数検証あり） |
| 式を単純に保つ | 複雑な組み立ては `locals` に名前を付けて切り出した。例：`backend_services`、`managed_rule_groups` |

## 6. モジュールとルートの設計

### 6.1 モジュール（`modules/`）

| モジュール | 主なリソース | 要点 |
|---|---|---|
| `network` | VPC、private サブネット ×3、IGW、Regional NAT（AZ ごとに EIP を固定）、S3/DynamoDB ゲートウェイエンドポイント、フローログ | NAT の EIP を固定し、egress IP を安定させる（外部 SaaS の許可リストに登録するため） |
| `container_registry` | ECR（IMMUTABLE、KMS、スキャン、ライフサイクル） | Keep イメージのミラー先 |
| `alert_journal` | DynamoDB `AlertEventJournal` | 次の設定を最初から固定する（グローバルテーブル化の前提）<br>- `NEW_AND_OLD_IMAGES`<br>- オンデマンド<br>- PITR<br>- TTL<br>- 削除保護<br>- GSI `state-updated_at` |
| `alert_queues` | FIFO キュー + DLQ（キーごとに生成） | 高スループット FIFO（`perMessageGroupId`）、SSE-SQS、redrive allow policy |
| `nodejs_lambda_function` | Lambda（`nodejs24.x` / arm64）、IAM ロール、ロググループ（JSON） | 次の 3 点<br>- `NODE_OPTIONS=--enable-source-maps`<br>- パッケージが無い場合は precondition で plan 時にエラーにする<br>- `policy_json` は必須（count を未確定値に依存させないため） |
| `alert_ingress` | REST API（Regional、execute-api エンドポイントは無効）、REQUEST オーソライザ、プロキシ統合、ステージ（アクセスログ、X-Ray、スロットリング）、WAF、ACM、カスタムドメイン、Route 53 | WAF の COUNT 既定と `SizeRestrictions_BODY` の除外（後述）、リソースポリシーによる IP 制限 |
| `keep_platform` | ECS（API、UI、任意で scheduler）、internal ALB、ACM、RDS、Valkey、Secrets、SG、IAM | `enable_dedicated_scheduler` で scheduler を分離できる。分離時は scheduler の deployment を max 100% / min 0% にし、2 つ同時に動かない |
| `alert_monitoring` | SNS（CMK で暗号化）、CloudWatch アラーム | 監視対象：DLQ、キューの滞留時間、Lambda の Errors/Throttles、API の 4XX/5XX、WAF のブロック、ECS の稼働タスク数 |

### 6.2 ルート（`envs/management/ap-northeast-1/`）と適用順

| 順 | ルート | 内容 | 依存 |
|---|---|---|---|
| 0 | `bootstrap` | tfstate 用の S3 バケット。初回はローカル state で作り、その後 S3 に移行する | なし |
| 1 | `foundation` | `network`、`container_registry` | bootstrap |
| 2 | （手作業） | `helpers/mirror-keep-images.sh` で Keep イメージをミラーし、digest を控える | foundation |
| 3 | `keep` | `keep_platform` | foundation |
| 4 | （手作業） | Keep で API キーを発行し、`keep/api-key-dispatcher` に保存する | keep |
| 5 | `alert-pipeline` | Journal、キュー、Lambda ×4、ingress、SNS、監視 | foundation、keep、`lambda/dist/lambda.zip` |
| 6 | （手作業） | 送信元トークンの digest を `alert-pipeline/source-token-digests` に保存し、Alertmanager に receiver を追加する | alert-pipeline |

## 7. Lambda の設計（`lambda/`）

| 項目 | 内容 |
|---|---|
| 言語とライブラリ | TypeScript 6、**Effect 3.22**（Schema、Config、Context/Layer、Cache、ManagedRuntime、Logger.json） |
| ランタイム | **Node.js 24（`nodejs24.x`、arm64）**。Lambda のマネージドランタイム |
| パッケージ管理 | **pnpm 12.6.0**（`packageManager` で固定、corepack で有効化）。`pnpm-lock.yaml` をコミットし、`allowBuilds` でビルドスクリプトを esbuild だけに許可する |
| ビルド | esbuild で ESM バンドルを 1 つ作る（`dist/index.mjs`、約 1MB）。AWS SDK v3 も同梱し、ロックファイルでバージョンを固定する。zip は mtime を固定して再現可能にしてあり、コードが同じなら `source_code_hash` も変わらない |
| エントリ | `src/index.ts` が `authorizer`、`ingest`、`router`、`dispatcher` を export する（Lambda の handler は `index.<name>`） |
| ハンドララッパー | `src/runtime/handler.ts`：Layer から `ManagedRuntime` を初回呼び出し時に 1 回だけ作る。失敗はログに出してから reject し、Lambda の失敗として記録させる |
| サービス | `Journal`（DynamoDB、状態は前進のみ）、`Queue`（SQS FIFO）、`Notifier`（SNS）、`Secrets`（Cache TTL 5 分）、`KeepClient`（fetch、タイムアウト 10 秒）。いずれも `Context.Tag` + `Layer` で、テストではインメモリの Layer に差し替える |
| テスト | vitest 5。6 ファイル 25 件：transition_id、FIFO の部分失敗、オーソライザ、Ingest（再送、5xx、400、403）、Router と Dispatcher、ハンドララッパー |

## 8. Keep の設計（`keep_platform`）

| 項目 | 設定 | 根拠 |
|---|---|---|
| backend | ECS Fargate で 2 タスク、8080 番ポート。`SECRET_MANAGER_TYPE=AWS`、`REDIS=true`、`KEEP_USE_LIMITER=true`、`KEEP_LIMIT_CONCURRENCY=100/minute`、`KEEP_PULL_DATA_ENABLED=false`、`CONSUMER=true` | レビュー #1〜#3、3.3 |
| scheduler | 既定は API タスク内で動かす（`SCHEDULER=true`）。`enable_dedicated_scheduler=true` で「API は `SCHEDULER=false` で 2 タスク、scheduler は 1 タスク」に分離する | レビュー 3.2 と完了条件 6 |
| frontend | 1 タスク、3000 番ポート。`API_URL`、`NEXTAUTH_URL`、`NEXTAUTH_SECRET` を渡す | Keep の設定ドキュメント |
| 公開 | internal ALB（TLS1.3/1.2 ポリシー）。`keep.<zone>` は UI、`keep-api.<zone>` は API に振り分ける。アクセス元は VPC と運用者のネットワークのみ | UI と API を外部に公開しない |
| DB | RDS PostgreSQL 17、Multi-AZ、gp3 暗号化、`rds.force_ssl=1`、PI と拡張モニタリング、削除保護、`prevent_destroy`、最終スナップショット | フェーズ 3 でクロスリージョンレプリカの元になる |
| キュー | ElastiCache Valkey 8.0、2 ノード、自動フェイルオーバー、保存時の暗号化 | ARQ（レビュー #1） |
| 秘密値 | DB パスワード、接続文字列、JWT、NextAuth、管理者パスワードは write-only で生成する。`secret_version` を上げると一斉にローテーションされる | state に残さない |
| イメージ | ECR へのミラーを digest で固定する（`@sha256:` 以外は validation で拒否） | 再現性。ECR プルスルーキャッシュは GAR 非対応（事実 G） |

## 9. セキュリティ

- **受信口の多層防御**:
  1. WAF（既定 BLOCK、IP セットで ALLOW）
  2. リソースポリシー（NotIpAddress で Deny）
  3. REQUEST オーソライザ（送信元ごとのトークン。保存するのは digest のみ。ローテーション用に複数の digest を登録できる）
  4. パスの送信元とオーソライザの判定結果が一致するかを Ingest で再確認（403）
  5. execute-api のデフォルトエンドポイントは無効化
- **WAF の既定を COUNT にした理由**:
  - Alertmanager は 403 を再試行しないため、誤検知はそのまま通知の欠落になる（事実 E）。
  - 特に `AWSManagedRulesCommonRuleSet` の `SizeRestrictions_BODY`（8KB）は、グループ化された通常の webhook も遮断しうるので、常に COUNT にする。
  - IP の許可リストは常に強制する。
- **IAM**: 関数ごとに最小権限のインラインポリシー（`policy_json` は必須）。ECS の実行ロールは注入する secret だけを読める。
- **checkov の許容事項**（`.checkov.yaml` に理由付きで列挙）:
  - 設計上該当しないもの：API キャッシュ、Lambda の DLQ、HTTP ターゲットグループ（ALB で TLS 終端）など。
  - フェーズ 2 の強化項目：CMK によるログと Secrets の暗号化、ALB と S3 のアクセスログ、コード署名、ログの 1 年保持、WAF の Log4j ルールを BLOCK にする。
  - 未確認事項：Valkey の通信暗号化（§14）。

## 10. 監視（`alert_monitoring`：パイプライン自体の監視）

| 対象 | 条件 | 意味 |
|---|---|---|
| DLQ ×2 | 可視メッセージ > 0 | 配送不能。調査のうえ `StartMessageMoveTask` で redrive する |
| alerts.fifo / keep-delivery.fifo | 最古メッセージの経過時間 > 300 秒 / 900 秒 | 消費が停止している（Keep の停止など） |
| Lambda ×4 | Errors > 0 | ハンドラの失敗 |
| dispatcher | Throttles > 0 | 予約同時実行数の不足 |
| API Gateway | 4XX > 0、5XX > 0 | 4xx は**再試行されない欠落**、5xx は再試行中 |
| WAF | BlockedRequests > 0 | 許可リストの漏れ（送信元 NAT の IP 変更など） |
| ECS | RunningTaskCount < desired | Keep の縮退 |

## 11. 実装タスク（WBS）

| # | タスク | 成果物 | 状態 |
|---|---|---|---|
| 1 | 前提の裏取り（レビューの 14 項目 + A〜K） | 本書 §2 | 完了 |
| 2 | Terraform のモジュール 8 つとルート 4 つ | `modules/`、`envs/` | 完了（実 AWS への apply は未実施） |
| 3 | Lambda（Node.js + Effect + pnpm） | `lambda/` | 完了（ユニットテストとバンドルのスモークテスト済み） |
| 4 | CI（fmt、validate、test、tflint、checkov、Lambda） | `.github/workflows/ci.yml` | 完了 |
| 5 | bootstrap の apply と state 移行 | tfstate バケット | 未着手（実環境） |
| 6 | foundation の apply、イメージのミラー、keep の apply | VPC、ECR、Keep | 未着手（実環境） |
| 7 | Keep の初期設定（管理者、API キー、prometheus プロバイダ、heartbeat ワークフロー） | Keep | 未着手（実環境） |
| 8 | alert-pipeline の apply、トークン digest の投入 | 受信口 | 未着手（実環境） |
| 9 | 本番 EKS と管理 EKS の Alertmanager に receiver を追加（PagerDuty との並行運用） | `docs/alertmanager-receiver.md` | 未着手（実環境） |
| 10 | CI への plan ジョブ追加（GitHub OIDC → 管理アカウントの plan 専用ロール） | CI | 未着手 |
| 11 | フェーズ 1 の完了条件の検証と GameDay（§12） | 検証記録 | 未着手 |

## 12. フェーズ 1 の完了条件と GameDay

v4 の完了条件 1〜5（v4 本文 9.1）に、レビューで追加された 6・7 と IaC 固有の条件を加える。

| # | 条件 | 検証手順 |
|---|---|---|
| 6 | Keep API を 2 タスクで動かし、interval ワークフロー（Keep processing heartbeat）が 1 周期に 1 回だけ実行される | 24 時間分の実行履歴を数える。2 回実行されていたら `enable_dedicated_scheduler = true` にして apply し、再度数える |
| 7 | Keep を停止して keep-delivery.fifo に 1,000 件以上溜めてから復旧しても、Dispatcher の同時実行上限が効き、Keep の DB 接続エラーが出ない | keep の API サービスの desired を 0 にする → テスト送信を 1,000 件以上 → desired を 2 に戻す。確認項目は 3 つ：Dispatcher の ConcurrentExecutions ≤ 3、Keep のログに接続プール枯渇のエラーがない、DLQ = 0 |
| 8 | critical が Keep の停止中も SNS に直送される | Keep を停止した状態で severity=critical のアラートを送り、SNS の購読先に届くことを確認する |
| 9 | 送信元が許可リストに無い場合とトークン不正の場合に、アラームが上がる | 許可されていない IP から送って WAF のアラームを確認する。不正トークンで送って 4XX のアラームを確認する |
| 10 | Journal からの再処理 | `KEEP_ACCEPTED` 未満の項目を GSI で抽出し、keep-delivery.fifo へ再投入して Keep に反映されることを確認する |
| 11 | IaC の再現性 | 変更なしで `terraform plan` の差分が 0 になる（Lambda の zip は再現可能） |

## 13. フェーズ 2/3 への引き継ぎ（後から変えない前提の担保状況）

| 前提（レビュー 9.4） | 担保 |
|---|---|
| 受信口は REST API（Regional）と WAF | `alert_ingress` で固定。テストで Regional と既定 BLOCK を検証している |
| Journal は `NEW_AND_OLD_IMAGES` | `alert_journal` で固定。テストで検証している |
| 受信 URL を変えない | カスタムドメイン `alerts.<zone>` を最初から使い、execute-api エンドポイントは無効にしている |
| 大阪への展開は純粋な追加作業 | `envs/management/ap-northeast-3/` に同じモジュールを置く。Journal は `replica` を追加。RDS はクロスリージョンリードレプリカ。Route 53 は `aws_route53_record.main` を PRIMARY/SECONDARY のフェイルオーバーレコードに置き換え、CLOUDWATCH_METRIC ヘルスチェックを使う（canary アラームは管理アカウント） |

## 14. リスクと未確認事項

| # | 項目 | 影響 | 対応 |
|---|---|---|---|
| U1 | Keep の Redis クライアントが TLS に対応しているか | 未対応なら Valkey の通信暗号化を有効にできない（現状は無効で、SG で制限） | フェーズ 1 で検証し、対応していれば `transit_encryption_enabled` を有効にする |
| U2 | `KEEP_DEFAULT_USERNAME` / `KEEP_DEFAULT_PASSWORD`（AUTH_TYPE=DB の初期管理者） | 変数名が違えば初期管理者が既定値のままになる | 初回起動時に確認する。違っていれば `api_extra_environment` で修正する |
| U3 | Keep backend のヘルスチェックパス（`/healthcheck`） | 違っていれば ALB がタスクを unhealthy と判定し続ける | `api_health_check_path` で変更できる |
| U4 | Keep が AWS Secrets Manager に作るシークレットの名前プレフィックス | IAM の `secret:keep*` に一致しなければプロバイダの保存が失敗する | 初回にプロバイダを登録するときに確認する |
| U5 | Keep の arm64 イメージ（レビューの未確認事項） | Fargate の Graviton 化によるコスト削減が可否に左右される | `cpu_architecture` は変数化してある（既定 X86_64） |
| U6 | ElastiCache の Valkey 8.0 が東京で使えるか | apply が失敗する | `cache_engine_version` で変更できる |
| U7 | Regional NAT の手動モード（`availability_zone_address`）の挙動と単価 | EIP の固定とコスト表（レビュー 18 番） | 最初の apply で確認する |
| U8 | Keep の 202 の意味（レビュー 17 番） | 設計上は 202 を信用しないため影響はない | Journal の状態は `KEEP_ACCEPTED`（受付）と呼んで区別している |
| R1 | Alertmanager は 4xx を再試行しない | 誤ったブロックや設定ミスでの欠落 | WAF を COUNT にし、4XX と WAF ブロックのアラームを置き、Ingest は 5xx を返す |
| R2 | 実 AWS での plan/apply は未実施 | provider の実際の挙動差（例：ACM の検証レコード） | タスク 5〜8 で段階的に apply する。モックによる `terraform test` で配線は検証済み |

## 15. 最終裁定

**裁定: フェーズ 1 の IaC は「条件付き Go」とする。** このコードで東京 MVP の構築に着手してよい。

**条件**
1. Keep のイメージは ECR にミラーし、digest で固定したうえで適用する（`helpers/mirror-keep-images.sh`）。
2. 送信元 EKS の NAT の egress IP を固定し、`alert_sources` に登録してから Alertmanager の receiver を追加する。WAF と 4XX のアラームを先に有効にしておく。
3. 完了条件 6（scheduler の二重実行）と 7（復旧時のバースト）を §12 の手順で検証し、結果に応じて `enable_dedicated_scheduler` と `dispatcher_maximum_concurrency` を確定する。
4. §14 の U1〜U4 を初回構築時に確認し、必要なら変数で是正する。

**なぜこの裁定に至るのか（so that ×3）**

- **so that ①：レビューの修正必須事項がコードで固定されるため。**
  - REST API + WAF、`NEW_AND_OLD_IMAGES`、Dispatcher の同時実行上限、scheduler 分離の切り替えは、すべてモジュールの既定値や validation として実装し、`terraform test` で検証している。
  - 人の注意ではなくコードで担保されるので、「後から変えない前提」（レビュー 9.4）がフェーズ 3 まで崩れない。
- **so that ②：裏取りで見つかった新しい危険が設計に吸収されているため。**
  - Alertmanager が 4xx を再試行しない点（事実 E）に対して、WAF を COUNT にし、4XX と WAF のアラームを置き、Ingest は 5xx を返す。
  - Keep の API キーの渡し方（事実 C）、GAR がプルスルーキャッシュの対象外である点（事実 G）、ESM の同時実行制御（事実 F）は、いずれも推論ではなくソースコードとサービスモデルで確認し、実装に反映した。
  - 残るリスクは Keep 側の未確認挙動（U1〜U4）に集中し、どれも変数の変更で是正できる。
- **so that ③：残る不確実性は、実環境の apply と GameDay で閉じられる範囲にあるため。**
  - 実 AWS での plan/apply はまだ行っていない。ただし、静的検証（fmt、validate、tflint、checkov）とモックによる plan テストでモジュール間の配線は確かめてある。未確認事項はフェーズ 1 のタスク 5〜11 の中で検証できる。
  - 結果が悪くても、critical は Keep を通らない直送経路があり、Journal から再処理できる。そのため critical の配送には影響しない。
  - 以上から、着手を止める理由はなく、条件付き Go とする。

**付記**: PagerDuty の解約はフェーズ 3 の完了後とする（v4 の裁定を維持）。フェーズ 1 の間は、critical-direct の SNS から PagerDuty の Amazon SNS 連携 URL へ並行して配送できる（`critical_https_endpoints`）。

---

### 付録 A: 検証の実施記録（本リポジトリ）

| 検証 | 結果 |
|---|---|
| `pnpm typecheck` / `pnpm test`（vitest） | OK / 6 ファイル 25 件すべて pass |
| `pnpm build`（esbuild） | `index.mjs` は 0.99MiB、`lambda.zip` は 1.61MiB。2 回ビルドして zip の SHA256 が一致（再現可能） |
| バンドルのスモークテスト（node で import） | 4 つの handler の export を確認。オーソライザはトークンなしで Deny、不正なイベントで reject、Ingest は不正な payload で 400 |
| `terraform fmt -check -recursive` | OK |
| `terraform validate`（モジュール 8 つ、ルート 4 つ） | すべて OK |
| `terraform test`（モックプロバイダ） | 7 ディレクトリ 17 件すべて pass |
| tflint 0.64 + aws ruleset 0.47.0 | 指摘 0 件 |
| checkov 3.3.19（`.checkov.yaml`） | 0 件 fail |
| 実 AWS への plan/apply | **未実施**（資格情報なし） |

### 付録 B: 参照した一次情報源

- Google Cloud: Terraform ベストプラクティス（全般的なスタイルと構造、ルートモジュール、再利用可能なモジュール、セキュリティ、オペレーション）— https://docs.cloud.google.com/docs/terraform/best-practices/general-style-structure?hl=ja
- botocore サービスモデル（Lambda の Runtime / ScalingConfig、ECR の UpstreamRegistry）— https://github.com/boto/botocore/tree/develop/botocore/data
- hashicorp/terraform-provider-aws（CHANGELOG 6.24.0、`r/nat_gateway`、`r/wafv2_web_acl_association`、`r/lambda_event_source_mapping`、`r/dynamodb_table`）— https://github.com/hashicorp/terraform-provider-aws
- hashicorp/terraform CHANGELOG v1.10 / v1.11（S3 のネイティブロック）— https://github.com/hashicorp/terraform
- keephq/keep（`keep/api/routes/alerts.py`、`keep/identitymanager/authverifierbase.py`、`keep/providers/prometheus_provider/prometheus_provider.py`、`docs/deployment/configuration.mdx`）— https://github.com/keephq/keep
- prometheus/alertmanager（`notify/util.go`、`notify/webhook/webhook.go`、`docs/configuration.md`）— https://github.com/prometheus/alertmanager
- Effect（npm の `effect` の dist-tags、Effect-TS/effect の README）— https://github.com/Effect-TS/effect
- oven-sh/bun `packages/bun-lambda/runtime.ts`（不採用の根拠）— https://github.com/oven-sh/bun/tree/main/packages/bun-lambda
- AWS Lambda 開発者ガイド「Configuring scaling behavior for SQS event source mappings」（検索抜粋のみ、本文は未取得）
