# PagerDuty → Keep 置き換え フェーズ 1（東京 MVP）IaC 実装計画書

- 作成日: 2026-09-23
- 更新: 2026-09-30 外向き通信を共有 Transit Gateway 経由に変更（§6.1、§14 U7・U16・R6・R7）
- 対象: `pagerduty_to_keep_architecture_review_v4.md`（v4 に対するレビュー、裁定「条件付き Go」）
  - v4 本文（`pagerduty_to_keep_architecture_summary_v4.md`）は未入手。v4 の節番号はレビューに書かれている引用に基づく（§14 U9）
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
| 範囲内 | 次の要素を管理アカウント（ap-northeast-1）に作る <br>- 受信口（API Gateway REST + WAF + Lambda オーソライザ）<br>- Journal（DynamoDB）<br>- FIFO キュー<br>- Lambda 4 本（TypeScript + Effect / Node.js 24）<br>- critical 直送（SNS）<br>- Keep（ECS Fargate、RDS PostgreSQL、ElastiCache Valkey、internal ALB）<br>- ネットワーク（private サブネットの既定ルートを共有 Transit Gateway に向ける。アタッチメントはネットワーク側）<br>- 監視<br>- tfstate 基盤 |
| 範囲外 | 次の 3 つ（3 つ目には例外あり） <br>- 大阪 DR の実リソース（フェーズ 3）<br>- 送信元（本番 EKS と管理 EKS）の Alertmanager 設定そのもの（設定例は `docs/alertmanager-receiver.md`）<br>- Keep のワークフロー定義（YAML）。ただし non-critical を内製ツールへ送る 1 本（`keep-workflows/non-critical-to-inhouse.yaml`）だけは範囲内とする（Keep への反映は人が行う。§4.2） |
| 前提 | アカウントは開発、ステージング、本番、管理の 4 つ。アラートの送信元は **本番 EKS と管理 EKS のみ**で、**管理アカウントの ECS（Keep）に集約**する |

## 2. 前提確認の結果

### 2.1 レビュー v4 の 14 項目

レビュー v4 の第 2 節で一次情報源と照合済みのため、本計画ではその結果をそのまま採用する。IaC に直接効くものは次のとおり。

| レビュー # | 内容 | IaC での反映箇所 |
|---|---|---|
| 5 | SQS FIFO の重複排除は 5 分 | `modules/alert_queues`。重複排除の本体は Journal の Conditional Put（`lambda/src/lib/journal.ts`） |
| 6 | Lambda/SQS のイベントソースは同一リージョンに限られる | 各リージョンの `alert-pipeline` ルートに、キューと Lambda を同居させる |
| 7 | Route 53 は CloudWatch アラーム型のヘルスチェックが使える | `modules/alert_ingress/domain.tf` のコメントで、フェーズ 3 の切り替え方式を固定している |
| 8 | Regional NAT Gateway | 採用しない。外向き通信は共有 Transit Gateway 経由（§6.1） |
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
| H | aws provider の Regional NAT 対応は v6.24.0 から。最新は v6.66.0 | `hashicorp/terraform-provider-aws` の CHANGELOG と `r/nat_gateway` のドキュメント | Regional NAT は採用をやめた（§6.1）。モジュールは `>= 6.0`、ルートは `~> 6.66` |
| I | S3 backend のネイティブロック（`use_lockfile`）は Terraform 1.10 で導入、1.11 で GA。DynamoDB ロックは非推奨 | `hashicorp/terraform` の CHANGELOG（v1.10 / v1.11） | `backend.hcl` で `use_lockfile = true`。CLI は 1.16.4 |
| J | WAF の関連付け先は REST API のステージのみ（HTTP API は不可） | terraform-provider-aws `r/wafv2_web_acl_association`、AWS の HTTP API と REST API の比較表 | `modules/alert_ingress` は REST（Regional）に固定 |
| K | 書き込み専用引数（`password_wo`、`secret_string_wo`）と ephemeral の `random_password` が使える | aws provider 6.66.0 と random 3.9.1 の provider schema（`terraform providers schema -json`） | 秘密値を plan や state に残さない（`keep_platform/secrets.tf`） |
| L | `aws_route` の `transit_gateway_id` は任意の文字列引数である。ターゲットの変更は `ReplaceRoute` でその場で行い、ForceNew ではない。`CreateRoute` は `InvalidTransitGatewayID.NotFound` のとき、create のタイムアウト（既定 5 分）まで再試行する。EC2 の `CreateTransitGatewayVpcAttachment` は「To send VPC traffic to an attached transit gateway, add a route to the VPC route table using CreateRoute」とし、サブネットは AZ ごとに 1 つまでである。`DescribeTransitGatewayVpcAttachments` は `vpc-id`、`transit-gateway-id`、`state` のフィルタを持ち、`aws_ec2_transit_gateway_vpc_attachments` は一致が無いときエラーではなく空の `ids` を返す | hashicorp/terraform-provider-aws v6.66.0 の `internal/service/ec2/vpc_route.go`、`d/ec2_transit_gateway_vpc_attachments` のドキュメントとソース（`transitgateway_vpc_attachments_data_source.go`、`find.go`）、aws provider 6.66.0 の provider schema、botocore 1.38.9 の EC2 モデル。アタッチメントの前の `CreateRoute` の挙動は未確認（U16） | `transit_gateway_id` を null 許容にし（null の間は既定ルートを作らない）、既定ルートには `available` のアタッチメントを求める precondition を付ける（`modules/network`） |

**不採用の経緯**: 当初は Lambda ランタイムに Bun を検討したが、ユーザー判断により Node.js（マネージド）に変更した。なお、`oven-sh/bun` の `packages/bun-lambda` レイヤーには 2 つの問題があることをソース（`runtime.ts`）で確認している。非 HTTP イベントでは handler の例外を成功として扱い、SQS のメッセージが消える。また、REST の REQUEST オーソライザに応答できない。

## 3. アカウントとリージョンの構成

```
┌──────────────── 本番アカウント ────────────────┐   ┌─────────── 管理アカウント (ap-northeast-1) ───────────┐
│ EKS  ─ Alertmanager ─(TGW 集約出口)────────────┼──▶│ Route53 alerts.<zone> → API GW REST + WAF          │
└────────────────────────────────────────────────┘   │   → authorizer λ → ingest λ → Journal / alerts.fifo  │
┌──────────────── 管理アカウント ────────────────┐   │   → router λ ─┬→ 内製ツール用 SQS → 内製ツール λ  │
│ EKS  ─ Alertmanager ─(TGW 集約出口)────────────┼──▶│               ├→ SNS critical-direct（メール等） │
└────────────────────────────────────────────────┘   │               └→ keep-delivery.fifo               │
  開発 / ステージング: 送信しない                     │   → dispatcher λ(VPC) → internal ALB → Keep(ECS)    │
                                                      │   Keep: RDS PostgreSQL / ElastiCache Valkey          │
                                                      │   Keep workflow(critical 以外)                       │
                                                      │     → keep-non-critical-inhouse.fifo → 内製ツール λ  │
                                                      └──────────────────────────────────────────────────────┘
```

- Keep、受信パイプライン、Route 53 ホストゾーン、フェーズ 3 の canary アラームは、すべて**管理アカウント**に置く。レビュー 3.4 の指摘どおり、Route 53 はクロスアカウントの CloudWatch アラームを扱えないため。
- 送信元の識別は URL のパス（`/v1/alerts/prod`、`/v1/alerts/management`）と送信元ごとのトークンで行う。ネットワーク上の制限として、WAF の IP セットとリソースポリシーに、送信元が通る集約出口（共有 Transit Gateway の先）のパブリック IP を登録する。本番と管理は同じ集約出口を通るので IP では区別できず、その背後のほかのワークロード（開発、ステージングを含む）も IP の層を通過する。送信元の識別と実質の制御は、パスと送信元ごとのトークンである（§14 R6）。

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
      severity ∈ critical_severities → Keep 非依存の 2 経路に常時並行で送る（§4.1）
        ① 内製ツール用 SQS（既定 critical-inhouse.fifo, group=fingerprint, dedup=transition_id）→ 内製ツール λ
        ② SNS critical-direct（メール購読。Slack 連携なども後から購読追加できる）
        経路ごとに成功を Journal の delivered_channels に記録し、再試行では未送信の経路だけを送る
      全件を keep-delivery.fifo へ → state=ROUTED
  → dispatcher λ（keep-delivery.fifo, VPC 内, ESM max 3, 予約同時実行数 3）
      POST https://keep-api.<zone>/alerts/event/prometheus?fingerprint=<source>:<fp>（X-API-KEY）
      202 → state=KEEP_ACCEPTED（202 は「受付」であって永続化完了ではない。レビュー #2）
  → Keep ワークフロー non-critical-to-inhouse（CEL: severity != "critical"、§4.2）
      amazonsqs → keep-non-critical-inhouse.fifo（group=fingerprint, dedup=<fingerprint>:<status>:<lastReceived>）
      → 内製ツール λ（labels.system で通知ルームを決める。対応表は内製ツール側で critical と共通）
```

- **状態は前進のみ**: Journal の `state_rank` を条件付きで更新するため、並行実行や再配信でも状態は戻らない。
- **FIFO の部分失敗**: 最初に失敗したメッセージ以降はバッチ内をすべて失敗として返す（`ReportBatchItemFailures`）。これでメッセージグループ内の順序を保つ。
- **DLQ**: `maxReceiveCount` は 5。可視性タイムアウトは消費側 Lambda のタイムアウトの 6 倍。
- **再処理**: Journal の GSI `state-updated_at` で、`KEEP_ACCEPTED` 未満のまま一定時間が過ぎたものを抽出する。payload は Journal に保存してあるので keep-delivery.fifo に再投入できる。

### 4.1 critical アラートの直送経路（内製ツールと SNS）

前提：内製ツールは管理アカウントの Lambda で、監視している SQS にメッセージが入ると起動する。PagerDuty の SNS 連携は選択肢にない。SNS と内製ツールの両方に常時送る。

| 案 | 構成 | 評価 |
|---|---|---|
| **A（採用）** | router が内製ツール用 SQS への SendMessage と SNS への Publish を**別々に**行う。経路ごとの成功を Journal に記録する | 2 経路が互いに独立する（SNS が落ちても内製ツールには届き、その逆も同じ）<br>内製ツールのキューを FIFO にでき、アラート単位の順序（firing → resolved）を保てる<br>再試行時は失敗した経路だけを送り直す |
| B | router は SNS に 1 回だけ Publish し、SNS から内製ツールの SQS（raw 配信）とメールへファンアウトする | 呼び出しは 1 回で済むが、両経路が SNS に依存し「並行経路」にならない<br>SNS FIFO トピックはメールに配信できないため、標準トピックになりアラート単位の順序が失われる |
| C | Keep のワークフロー（amazonsqs アクション）から内製ツールのキューに送る | critical 配送が Keep に依存する。レビュー 3.6 の「critical 直送」の原則に反する |
| D | EventBridge API Destination | 内製ツールは HTTP ではなく SQS で起動するため当てはまらない |

- 配送は各経路とも at-least-once で、受け手は `transitionId` で重複を除く。送信成功から Journal への記録までの間に障害が起きると再送されるが、取りこぼしよりは重複を選ぶ。
- 契約（JSON スキーマ、内製ツール側の ESM と IAM の設定）は [`critical-notification-contract.md`](critical-notification-contract.md) にまとめた。
- 内製ツール用キューは既定で本リポジトリが作る（FIFO + DLQ）。ツールがすでに監視しているキューがあれば、`inhouse_notifier_existing_queue_arn` でそちらに送る。標準キューと FIFO キューの両方に対応し、SSE-KMS なら `inhouse_notifier_kms_key_arn` も渡す。

### 4.2 non-critical アラートの経路（Keep → SQS FIFO → 内製ツール）

前提：100 以上のシステムと 100 以上の通知ルームがある。critical 以外のアラートも内製ツールで各ルームに届けたい。Keep は重複除去や抑制で「通知するかどうか」を決める。

**裁定：Keep のワークフロー 1 本（`keep-workflows/non-critical-to-inhouse.yaml`）で、critical 以外の全アラートを `keep-non-critical-inhouse.fifo` に送る。ルームへの振り分けは内製ツールの対応表（システム名 `labels.system` → ルーム、YAML を Git 管理、critical と共通）で行う。キューは `keep` ルートに置く。**

- **so that ①：振り分けを 1 か所で持つため。** 100 × 100 の振り分けを Keep のワークフローに書くと、ワークフローの数と変更の手間が増え、critical 側と二重管理になる。内製ツールの対応表 1 つにまとめれば、critical と non-critical で同じ表を使える。ラベルが無いアラートや対応表に無いシステム名は、内製ツールがフォールバックのルームに送る。そのためワークフローは `labels.system` を参照しない（キーが無いとレンダリングに失敗して送信自体が落ちる。keephq/keep v0.54.3 `keep/iohandler/iohandler.py`）。
- **so that ②：アラート単位の順序を保つため（FIFO）。** Keep の amazonsqs プロバイダは、キュー URL が `.fifo` なら `group_id` と `dedup_id` を `MessageGroupId` / `MessageDeduplicationId` として送る（keephq/keep v0.54.3 `keep/providers/amazonsqs_provider/amazonsqs_provider.py`）。group を fingerprint にすれば、critical と同じくアラートごとに firing → resolved の順で届く。キューの設定は `alert_queues` の既定（SSE-SQS、`maxReceiveCount` 5、高スループット FIFO、redrive allow policy）をそのまま使う。
- **so that ③：ルート間の依存方向を崩さないため（keep ルートに置く）。** alert-pipeline はすでに keep の state を読んでいる。キューを alert-pipeline に置くと、送信権限を付ける keep ルートが alert-pipeline の state を読むことになり循環する（§6.2 の適用順にも反する）。送信側の Keep と同じ keep ルートに置けば、ARN を `keep_platform` の `sqs_send_queue_arns` に直接渡せる。アラームは alert-pipeline の `alert_monitoring` が keep の出力（キュー名）を読んで作る。

- ワークフローの不変条件（`group_id` と `dedup_id` があること）は、keep ルートの `check` ブロックとテストで確かめる。Keep への反映自体は人が行う。
- Keep のタスクロールには送信権限だけを付け、受信権限は付けない。Keep は `CONSUMER=true` で動き、amazonsqs プロバイダは消費もできるため、受信権限があると内製ツール宛てのメッセージを横取りしてループになる（keephq/keep v0.54.3 `keep/event_subscriber/event_subscriber.py`）。
- 契約（本文、重複排除キー、内製ツール側の設定、Keep 側の手作業）は [`non-critical-notification-contract.md`](non-critical-notification-contract.md) にまとめた。

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
| `network` | VPC、private サブネット ×3、既定ルート（0.0.0.0/0 → 共有 Transit Gateway）、S3/DynamoDB ゲートウェイエンドポイント、フローログ | IGW、NAT、EIP は持たない。VPC のアタッチメントと Transit Gateway 側のルートはネットワーク側が作る。既定ルートは `transit_gateway_id` を設定し、アタッチメントが `available` のときだけ作る（precondition、事実 L）。外向きの IP は集約出口のもので、ネットワーク側が管理する。運用者のネットワーク（`alb_ingress_cidrs`）への戻りの通信も 0.0.0.0/0 → Transit Gateway に従うので、internal ALB への到達は Transit Gateway 側のルートに依存する。NAT のときと違い、VPC の外の私設アドレス宛ての通信もインターネットで捨てられず、Transit Gateway 側のルートテーブルにある宛先（ほかの VPC やオンプレミス）に届きうる。逆向きにそれらからこの VPC にも届く（受け口は SG で制限される）。到達範囲は未確認（§14 R7） |
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
| 1a | （ネットワーク側） | VPC アタッチメントと Transit Gateway 側のルート（サブネットは出力 `private_subnet_ids`） | foundation |
| 1b | `foundation` | `transit_gateway_id` を設定して再 apply（既定ルートを作る） | 1a |
| 2 | （手作業） | `helpers/mirror-keep-images.sh` で Keep イメージをミラーし、digest を控える | foundation |
| 3 | `keep` | `keep_platform`、non-critical 用キュー `keep-non-critical-inhouse.fifo`（+ DLQ） | 1b |
| 4 | （手作業） | Keep で API キーを発行し、`keep/api-key-dispatcher` に保存する | keep |
| 4a | （手作業） | Keep に amazonsqs プロバイダ `inhouse-non-critical`（`sqs_queue_url` は出力 `non_critical_inhouse_queue_url`、アクセスキーは空欄）を登録し、`keep-workflows/non-critical-to-inhouse.yaml` を反映する | keep |
| 5 | `alert-pipeline` | Journal、キュー（内製ツール用を含む）、Lambda ×4、ingress、SNS、監視（keep ルートの non-critical キューのアラームを含む） | foundation、keep、`lambda/dist/lambda.zip` |
| 5a | （内製ツール側） | alert-pipeline の出力 `inhouse_notifier_queue_arn`（critical）と keep の出力 `non_critical_inhouse_queue_arn`（non-critical）を内製ツール Lambda のイベントソースに設定し、実行ロールに受信権限を付ける | alert-pipeline、keep |
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
| サービス | `Journal`（DynamoDB、状態は前進のみ）、`Queue`（SQS。FIFO なら group と dedup を付ける）、`Notifier`（SNS）、`criticalNotification`（内製ツールと SNS 向けの契約 JSON、`schemaVersion: 1`）、`Secrets`（Cache TTL 5 分）、`KeepClient`（fetch、タイムアウト 10 秒）。いずれも `Context.Tag` + `Layer` で、テストではインメモリの Layer に差し替える |
| テスト | vitest 5。7 ファイル 29 件：transition_id、FIFO の部分失敗、オーソライザ、Ingest（再送、5xx、400、403）、Router（内製ツールと SNS の 2 経路、失敗した経路だけを再送）、Dispatcher、critical 通知の契約、ハンドララッパー |

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
  1. WAF（既定 BLOCK、IP セットで ALLOW）。IP は集約出口のもので、背後の全ワークロードが通過する。送信元の区別はトークンで行う
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
| DLQ ×4（alerts / keep-delivery / critical-inhouse / non-critical-inhouse） | 可視メッセージ > 0 | 配送不能。調査のうえ `StartMessageMoveTask` で redrive する（critical-inhouse と non-critical-inhouse の DLQ は内製ツール側の処理失敗） |
| critical-inhouse キュー | 最古メッセージの経過時間 > 120 秒 | 内製ツールが消費していない。この間 critical は SNS 経路だけで届いている |
| non-critical-inhouse キュー（keep ルート） | 最古メッセージの経過時間 > 300 秒 | 内製ツールが non-critical を消費していない |
| alerts.fifo / keep-delivery.fifo | 最古メッセージの経過時間 > 300 秒 / 900 秒 | 消費が停止している（Keep の停止など） |
| Lambda ×4 | Errors > 0 | ハンドラの失敗 |
| dispatcher | Throttles > 0 | 予約同時実行数の不足 |
| API Gateway | 4XX > 0、5XX > 0 | 4xx は**再試行されない欠落**、5xx は再試行中 |
| WAF | BlockedRequests > 0 | 許可リストの漏れ（集約出口の IP 変更など） |
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
| 8a | 内製ツール Lambda に critical キューのイベントソースと IAM を設定し、`transitionId` で重複を除く | `docs/critical-notification-contract.md` | 未着手（内製ツール側） |
| 8b | Keep に amazonsqs プロバイダを登録してワークフローを反映し、内製ツール Lambda に non-critical キューのイベントソースと IAM を設定する（対応表は critical と共通） | `keep-workflows/non-critical-to-inhouse.yaml`、`docs/non-critical-notification-contract.md` | 未着手（実環境、内製ツール側） |
| 9 | 本番 EKS と管理 EKS の Alertmanager に receiver を追加（PagerDuty との並行運用） | `docs/alertmanager-receiver.md` | 未着手（実環境） |
| 10 | CI への plan ジョブ追加（GitHub OIDC → 管理アカウントの plan 専用ロール） | CI | 未着手 |
| 11 | フェーズ 1 の完了条件の検証と GameDay（§12） | 検証記録 | 未着手 |

## 12. フェーズ 1 の完了条件と GameDay

v4 の完了条件 1〜5（v4 本文 9.1）に、レビューで追加された 6・7 と IaC 固有の条件を加える。

| # | 条件 | 検証手順 |
|---|---|---|
| 6 | Keep API を 2 タスクで動かし、interval ワークフロー（Keep processing heartbeat）が 1 周期に 1 回だけ実行される | 24 時間分の実行履歴を数える。2 回実行されていたら `enable_dedicated_scheduler = true` にして apply し、再度数える |
| 7 | Keep を停止して keep-delivery.fifo に 1,000 件以上溜めてから復旧しても、Dispatcher の同時実行上限が効き、Keep の DB 接続エラーが出ない | keep の API サービスの desired を 0 にする → テスト送信を 1,000 件以上 → desired を 2 に戻す。確認項目は 3 つ：Dispatcher の ConcurrentExecutions ≤ 3、Keep のログに接続プール枯渇のエラーがない、DLQ = 0 |
| 8 | critical が Keep の停止中も内製ツールと SNS の両方に届き、片方の経路が止まっても、もう片方には届く | (a) Keep を停止した状態で severity=critical を送り、内製ツールと SNS の購読先の両方に届くことを確認する。(b) 内製ツールのイベントソースを無効にして送り、SNS に届くこと、`critical_inhouse-oldest-message-age` アラームが鳴ること、有効に戻すと内製ツールに届くことを確認する。(c) router ロールから `sns:Publish` を外して送り、内製ツールには 1 回だけ届き、権限を戻した後の再試行で SNS に届くことを確認する（経路ごとの記録） |
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
| U1 | Keep の Redis クライアントが TLS に対応しているか | 未対応なら Valkey の通信暗号化を有効にできない（現状は無効で、SG で制限） | **一部解消**：Keep は `REDIS_SSL=true` で TLS 接続できる（`keep/keep/api/redis_settings.py:33`）。ElastiCache の証明書をイメージの CA ストアで検証できるかは未確認のため、初回構築時に `transit_encryption_enabled` と合わせて確かめる（[`architecture-services-and-flow.md`](architecture-services-and-flow.md) §5.2） |
| U2 | `KEEP_DEFAULT_USERNAME` / `KEEP_DEFAULT_PASSWORD`（AUTH_TYPE=DB の初期管理者） | 変数名が違えば初期管理者が既定値のままになる | **解消**：変数名は正しい（`keep/keep/api/core/db_on_start.py:48-49`）（[`architecture-services-and-flow.md`](architecture-services-and-flow.md) §5.2） |
| U3 | Keep backend のヘルスチェックパス（`/healthcheck`） | 違っていれば ALB がタスクを unhealthy と判定し続ける | **解消**：`GET /healthcheck` は認証なしで 200 を返す（`keep/keep/api/routes/healthcheck.py:6-14`、`keep/keep/api/api.py:294`）。UI 側は G9（[`architecture-services-and-flow.md`](architecture-services-and-flow.md) §5.2、§6） |
| U4 | Keep が AWS Secrets Manager に作るシークレットの名前プレフィックス | IAM の `secret:keep*` に一致しなければプロバイダの保存が失敗する | **解消**：Keep が作る名前は `keep_*` と `keep-*` で `secret:keep*` に一致する。ただし IaC 自身の `keep/*` にも一致する（G5）。`AWS_KMS_KEY_ID` が未設定だと新規作成が失敗する（G11）（[`architecture-services-and-flow.md`](architecture-services-and-flow.md) §5.2、§6） |
| U5 | Keep の arm64 イメージ（レビューの未確認事項） | Fargate の Graviton 化によるコスト削減が可否に左右される | `cpu_architecture` は変数化してある（既定 X86_64） |
| U6 | ElastiCache の Valkey 8.0 が東京で使えるか | apply が失敗する | `cache_engine_version` で変更できる |
| U7 | Regional NAT の手動モード（`availability_zone_address`）の挙動と単価 | EIP の固定とコスト表（レビュー 18 番） | **対象外**：Regional NAT を使わなくなった（§6.1） |
| U8 | Keep の 202 の意味（レビュー 17 番） | 設計上は 202 を信用しないため影響はない | **解消**：`REDIS=true` では 202 は ARQ のジョブとして Valkey に積んだことを表す（`keep/keep/api/routes/alerts.py:748-781`）。`KEEP_ACCEPTED` はこの意味で使う（[`architecture-services-and-flow.md`](architecture-services-and-flow.md) §4.2） |
| R1 | Alertmanager は 4xx を再試行しない | 誤ったブロックや設定ミスでの欠落 | WAF を COUNT にし、4XX と WAF ブロックのアラームを置き、Ingest は 5xx を返す |
| U9 | v4 本文（`pagerduty_to_keep_architecture_summary_v4.md`）が未入手 | v4 の完了条件 1〜5 や critical 直送の要件（v4 7.x）との差異を突き合わせられていない | v4 を入手したら §4.1 と §12 を照合する |
| U10 | 内製ツールの冪等性、キューの種類、タイムアウト | 重複通知や、可視性タイムアウト不足による二重処理 | 契約で `transitionId` による重複排除を求める。既定キューは FIFO で可視性タイムアウト 900 秒（変数で調整） |
| U11 | Keep ワークフローの `{{ alert }}` が実行時に正しい JSON になるか（chevron の HTML エスケープ → Keep の `html.unescape`。値に実体参照や `keep.xxx(` を含むと変形や関数評価エラーの可能性） | non-critical の本文が壊れ、内製ツールが解釈できない | **範囲を縮小**：`keep.` と括弧を含む値による関数評価の失敗は `raw_render_without_execution(...)` で避けられる（G4、別タスク）。実体参照や `{{` を含む値の変形は残るので初回構築時の確認は続ける（[`architecture-services-and-flow.md`](architecture-services-and-flow.md) §6） |
| U12 | Keep が重複として扱うイベント（Alertmanager の repeat による再送）でワークフローが起動するか | 起動すると non-critical の通知量が増える | **解消**：同じ `startsAt` の firing の再送は ingest が重複として落とすため Keep に届かず、Keep 側でも完全な重複はワークフローの前で除かれる。`only_on_change` は不要（[`architecture-services-and-flow.md`](architecture-services-and-flow.md) §4.3、§5.1 C9） |
| U13 | amazonsqs プロバイダのスコープ検証メッセージ（`KEEP_SCOPE_TEST_MSG_PLEASE_IGNORE`）が送られる時機（登録時のみか、定期的か） | 内製ツールが破棄しないと誤通知になる | **解消**：送られるのは登録、更新、手動の再検証、OAuth2 での登録のときだけで、定期的には送られない（[`architecture-services-and-flow.md`](architecture-services-and-flow.md) §5.1 C10）。内製ツールでの破棄は引き続き必要 |
| U14 | SQS の `MessageGroupId` / `MessageDeduplicationId` の制約（長さ、文字種）とメッセージサイズの上限（AWS の一次情報源を未取得） | 制約を超えると送信が失敗する | **解消**：AWS のサービスモデル（botocore 1.38.9）では両 ID は 128 文字以内の英数字と記号、本文は 256 KiB 以内。`dedup_id` は `<source>` の長さ + 55 文字以内（[`architecture-services-and-flow.md`](architecture-services-and-flow.md) §5.1 C14） |
| U15 | 配備する Keep のタグが、参照したソース（v0.54.3）と同じ挙動か | amazonsqs プロバイダ、AlertDto、CEL の前処理が変わると契約が崩れる | イメージのミラー時にソースの差分を確認する |
| R4 | `critical_severities` を既定の `["critical"]` から広げると、Keep の severity（`labels.severity == "critical"` のときだけ critical）とずれる | そのアラートが critical 経路と non-critical 経路の両方に届く | 変数の description と契約に明記した。変えるときはワークフローの CEL も合わせる |
| R3 | critical 経路で送信に失敗すると、そのレコードは Keep にも送られず再試行になる | 片方の経路が恒常的に落ちていると、そのアラートの Keep 反映が遅れる（critical はもう片方の経路で届く） | critical 配送を優先する設計判断。`router-errors` アラームで検知し、DLQ 行きになる前に対処する。ただし送信失敗はバッチ内の失敗として返すため `router-errors` では検知できない見込み。キューの滞留と DLQ のアラームで検知する（[`architecture-services-and-flow.md`](architecture-services-and-flow.md) §6 G12） |
| R2 | 実 AWS での plan/apply は未実施 | provider の実際の挙動差（例：ACM の検証レコード） | タスク 5〜8 で段階的に apply する。モックによる `terraform test` で配線は検証済み |
| R5 | Keep v0.54.3 のソースと Keep の設定・監視の食い違い（G1〜G12）、critical の 2 経路の送信順（G13） | G1〜G12 は、そのままでは non-critical の取りこぼしや遅延、初期設定の失敗が起きる（critical の配送には影響しない）。G13 では、内製ツール用キューへの送信が失敗すると SNS にも送られず、critical がどちらの経路にも届かない（R3 の「critical はもう片方の経路で届く」は、この向きでは成り立たない） | [`architecture-services-and-flow.md`](architecture-services-and-flow.md) §6 の是正タスクを、承認を得て別途行う。G13 は Alertmanager の receiver の追加前に行う |
| U16 | 共有 Transit Gateway 経由の外向き通信（事実 L）：(a) アタッチメントの前の `CreateRoute` の挙動（エラーになるか、ブラックホールのルートを受け付けるか）、(b) ネットワーク側が作ったアタッチメントが、管理アカウントの `DescribeTransitGatewayVpcAttachments` で見えるか（どのアカウントから作るか）、(c) S3 / DynamoDB のゲートウェイエンドポイントのルート（プレフィックスリスト）が 0.0.0.0/0 → Transit Gateway より優先されるか（`CreateRoute` の説明は「most specific match」。プレフィックスリストの優先順位の記述は VPC ユーザーガイドで未確認）、(d) 集約出口の IP の数、安定性、変更の通知と、Transit Gateway のアタッチメントとデータ処理の単価と負担区分 | (a) precondition があるので、設計は答えに依存しない。(b) 見えないと precondition で既定ルートを作れない。(c) 優先されないと、S3 と DynamoDB の通信も Transit Gateway を通り、データ処理の料金がかかる。(d) IP が変わると許可リストから漏れ、通知が 403 で欠落する（R1） | (a) VPC / Transit Gateway のユーザーガイドを参照できたら確かめる。できなければ最初の apply で観察する。(b) 2 回目の apply（§6.2 の 1b）の前に、読み取りの `aws ec2 describe-transit-gateway-vpc-attachments --filters Name=vpc-id,Values=<vpc>` で確かめる。見えなければ対応をユーザーが決める。(c) apply の後にフローログで確かめる。(d) ネットワーク側に確認する |
| R6 | IP の許可リスト（WAF、リソースポリシー）は、集約出口の背後の全ワークロードに共通になる。本番と管理も IP では区別できない | 漏れたトークンは、集約出口の背後のどこからでも使える（防御の層が 1 つ減る） | 送信元ごとのトークン（オーソライザが sha256 の digest で照合する）と、Ingest でのパスとオーソライザの判定の再確認（§9 の 4）で送信元を区別する。トークンをローテーションする。WAF と 4XX のアラームは残す |
| R7 | 0.0.0.0/0 → 共有 Transit Gateway で届く範囲は、このアタッチメントに関連付けた Transit Gateway のルートテーブル（ネットワーク側の管理）で決まり、**未確認**である。NAT のときは、VPC の外の私設アドレス宛ての通信はインターネットに出て届かなかった。今は、そのルートテーブルにある宛先（ほかのアカウントの VPC、オンプレミスなど）すべてに届きうる。逆向きに、それらのネットワークからこの VPC にも届く | Keep のタスクと dispatcher の SG は tcp/443 を 0.0.0.0/0 に許可する（`modules/keep_platform/security_groups.tf:61-68`、`envs/management/ap-northeast-1/alert-pipeline/functions.tf:147-154`）。侵害された、または設定を誤った Keep（ワークフローの HTTP / webhook の送信、テレメトリ（[`architecture-services-and-flow.md`](architecture-services-and-flow.md) §6 G7））から、ほかのネットワークの内部の HTTPS エンドポイント（EKS の API サーバーなど）に接続できうる。逆向きの受け口は SG で制限される（ALB は VPC の CIDR と `operator_cidrs` の 443 だけ、タスク、RDS、Valkey は SG の参照だけ） | ネットワーク側に、このアタッチメント専用の Transit Gateway ルートテーブルを依頼する。ただし専用のルートテーブルだけでは足りない。そこに無い私設アドレス宛ても既定ルートで集約出口の VPC に入り、集約出口の VPC が各 VPC の CIDR を Transit Gateway に戻す構成（AWS の Transit Gateway ガイドの集約出口の例。ガイドは VPC ごとのブラックホールルートで VPC 間の通信を止められるとする）なら、そこから Transit Gateway を折り返してほかの VPC に届きうる。集約出口の構成は未確認である。そこでルートテーブルの中身は、(1) 集約出口への既定ルート 0.0.0.0/0、(2) `operator_cidrs` への戻りのルート、(3) 私設アドレス 10.0.0.0/8、172.16.0.0/12、192.168.0.0/16（組織が使っていれば 100.64.0.0/10 も）のブラックホールルート、だけとし、ワークロード VPC からの伝播（propagation）は受けない、と依頼する。Transit Gateway は最も長く一致するルートを選ぶので、(2) が (3) より狭ければ (2) が勝つ。`operator_cidrs` に (3) と同じか広い CIDR があれば、対応をユーザーが決める。(3) の代わりに、集約出口の VPC かファイアウォールが私設アドレス宛てを落とす、でもよい。ただしその場合は、落とすことをネットワーク側に確かめる（未確認）。§6.2 の 1b の前に、読み取りで確かめる：`aws ec2 describe-transit-gateway-attachments --filters Name=resource-id,Values=<vpc>` で関連付けたルートテーブルを見る。`aws ec2 get-transit-gateway-route-table-propagations --transit-gateway-route-table-id <rtb>` でワークロード VPC からの伝播が無いことを見る。`aws ec2 search-transit-gateway-routes --transit-gateway-route-table-id <rtb> --filters Name=state,Values=active,blackhole` で、ルートがちょうど (1)〜(3) であることを見る（`active` だけではブラックホールルートが表示されない）。この API はページ分割しない（既定で最大 1000 件）ので、`AdditionalRoutesAvailable` が `true` なら一覧が切れている。管理アカウントから見えるかは U16 (b) と同じく未確認。見えないか、中身が (1)〜(3) と違えば、対応をユーザーが決める。Keep のタスクと dispatcher の SG の外向きを絞るのは任意 |

## 15. 最終裁定

**裁定: フェーズ 1 の IaC は「条件付き Go」とする。** このコードで東京 MVP の構築に着手してよい。

**条件**
1. Keep のイメージは ECR にミラーし、digest で固定したうえで適用する（`helpers/mirror-keep-images.sh`）。
2. 送信元 EKS が通る集約出口のパブリック IP（ネットワーク側から入手する）を、`alert_sources` の両方の送信元に登録してから Alertmanager の receiver を追加する。WAF と 4XX のアラームを先に有効にしておく。
3. 完了条件 6（scheduler の二重実行）と 7（復旧時のバースト）を §12 の手順で検証し、結果に応じて `enable_dedicated_scheduler` と `dispatcher_maximum_concurrency` を確定する。
4. §14 の U1〜U4 を初回構築時に確認し、必要なら変数で是正する。
5. 内製ツール側でイベントソース、IAM、`transitionId` による重複排除を実装し、完了条件 8（片方の経路が止まってももう片方に届く）を GameDay で確認する（U10）。

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
  - 結果が悪くても、critical は Keep を通らない 2 経路（内製ツールと SNS）で並行して届き、Journal から再処理もできる。そのため critical の配送には影響しない。
  - 以上から、着手を止める理由はなく、条件付き Go とする。

**付記**: PagerDuty の解約はフェーズ 3 の完了後とする（v4 の裁定を維持）。PagerDuty の SNS 連携は選択肢に入れない。フェーズ 1 の間、PagerDuty へは Alertmanager の既存 receiver から従来どおり送り、critical の直送は内製ツールと SNS の 2 経路で行う（§4.1）。

---

### 付録 A: 検証の実施記録（本リポジトリ）

| 検証 | 結果 |
|---|---|
| `pnpm typecheck` / `pnpm test`（vitest） | OK / 7 ファイル 29 件すべて pass |
| `pnpm build`（esbuild） | `index.mjs` は 0.99MiB、`lambda.zip` は 1.62MiB。2 回ビルドして zip の SHA256 が一致（再現可能） |
| バンドルのスモークテスト（node で import） | 4 つの handler の export を確認。オーソライザはトークンなしで Deny、不正なイベントで reject、Ingest は不正な payload で 400 |
| `terraform fmt -check -recursive` | OK |
| `terraform validate`（モジュール 8 つ、ルート 4 つ） | すべて OK |
| `terraform test`（モックプロバイダ） | 7 ディレクトリ 20 件すべて pass（内製ツール用キューの新規作成、既存キューの指定、不正な ARN の拒否を含む） |
| tflint 0.64 + aws ruleset 0.47.0 | 指摘 0 件 |
| checkov 3.3.19（`.checkov.yaml`） | 0 件 fail |
| 実 AWS への plan/apply | **未実施**（資格情報なし） |

### 付録 B: 参照した一次情報源

- Google Cloud: Terraform ベストプラクティス（全般的なスタイルと構造、ルートモジュール、再利用可能なモジュール、セキュリティ、オペレーション）— https://docs.cloud.google.com/docs/terraform/best-practices/general-style-structure?hl=ja
- botocore サービスモデル（Lambda の Runtime / ScalingConfig、ECR の UpstreamRegistry）— https://github.com/boto/botocore/tree/develop/botocore/data
- hashicorp/terraform-provider-aws（CHANGELOG 6.24.0、`r/nat_gateway`、`r/wafv2_web_acl_association`、`r/lambda_event_source_mapping`、`r/dynamodb_table`）— https://github.com/hashicorp/terraform-provider-aws
- hashicorp/terraform-provider-aws v6.66.0（事実 L）：`internal/service/ec2/vpc_route.go`、`internal/service/ec2/transitgateway_vpc_attachments_data_source.go`、`internal/service/ec2/find.go`、`website/docs/d/ec2_transit_gateway_vpc_attachments.html.markdown`。aws provider 6.66.0 の provider schema（`terraform providers schema -json`）— https://github.com/hashicorp/terraform-provider-aws/tree/v6.66.0
- botocore 1.38.9 の EC2 モデル（事実 L）：`CreateRoute`、`CreateTransitGatewayVpcAttachment`、`DescribeTransitGatewayVpcAttachments`、R7 の確認手順：`DescribeTransitGatewayAttachments`、`GetTransitGatewayRouteTablePropagations`、`SearchTransitGatewayRoutes`（`state` フィルタの `active` / `blackhole`、`MaxResults` の既定 1000、`NextToken` が無く結果に `AdditionalRoutesAvailable` があること）（`botocore/data/ec2/2016-11-15/service-2.json`）— https://github.com/boto/botocore/tree/1.38.9
- AWS Transit Gateway ガイド（R7）：「Example: Centralized outbound routing to the internet」（`doc_source/transit-gateway-nat-igw.md`。集約出口の VPC が各 VPC の CIDR を Transit Gateway に戻すこと、VPC ごとのブラックホールルートで VPC 間の通信を止められること）、「Route evaluation order」（`doc_source/how-transit-gateways-work.md`。最も長く一致するルートが優先）— https://github.com/awsdocs/aws-transit-gateway-guide/tree/master/doc_source
- hashicorp/terraform CHANGELOG v1.10 / v1.11（S3 のネイティブロック）— https://github.com/hashicorp/terraform
- keephq/keep（`keep/api/routes/alerts.py`、`keep/identitymanager/authverifierbase.py`、`keep/providers/prometheus_provider/prometheus_provider.py`、`docs/deployment/configuration.mdx`）— https://github.com/keephq/keep
- keephq/keep v0.54.3（non-critical 経路、§4.2）：`keep/providers/amazonsqs_provider/amazonsqs_provider.py`（`_notify`、`validate_scopes`、`start_consume`）、`keep/api/models/alert.py`（`AlertDto.__str__`）、`keep/iohandler/iohandler.py`（`render_context`、`_render`）、`keep/api/utils/cel_utils.py`、`keep/event_subscriber/event_subscriber.py`、`docs/workflows/syntax/triggers.mdx`、`docs/providers/documentation/amazonsqs-provider.mdx`— https://github.com/keephq/keep/tree/v0.54.3
- prometheus/alertmanager（`notify/util.go`、`notify/webhook/webhook.go`、`docs/configuration.md`）— https://github.com/prometheus/alertmanager
- Effect（npm の `effect` の dist-tags、Effect-TS/effect の README）— https://github.com/Effect-TS/effect
- oven-sh/bun `packages/bun-lambda/runtime.ts`（不採用の根拠）— https://github.com/oven-sh/bun/tree/main/packages/bun-lambda
- AWS Lambda 開発者ガイド「Configuring scaling behavior for SQS event source mappings」（検索抜粋のみ、本文は未取得）
