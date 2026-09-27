# フェーズ 1（東京 MVP）ランニングコスト試算とリソース割当量

- 作成日: 2026-09-27
- 対象: 本リポジトリの 4 ルート（`bootstrap`、`foundation`、`keep`、`alert-pipeline`）を、tfvars と変数の既定値のまま ap-northeast-1 に apply し、365 日 24 時間動かした場合
- 単価の一次情報源: AWS Price List Bulk API（`https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/<service>/current/ap-northeast-1/index.json`）。2026-09-27 に取得。各ファイルの公開日は 2026-09-11〜2026-09-26
- 実環境には未 apply。そのため請求実績ではなく、**コードの定義 × 公開単価 × 利用量の仮定**による試算である

---

## 1. 前提

| 項目 | 前提 |
|---|---|
| 期間 | 365 日 × 24 時間 = 8,760 時間/年（月額は 730 時間で計算。年額 = 月額 × 12） |
| 通貨 | USD、税抜き。円換算は **1 USD = 150 円**（仮定。140〜160 円なら年額は約 94〜107 万円） |
| 料金体系 | オンデマンド。**無料枠は含めない**（管理アカウントでは他のワークロードが無料枠を使っている可能性が高いため、保守的に見積もる）。ただし Price List が単価表の段階として持つ無料分（DynamoDB のストレージ 25 GB、SNS の最初の 100 万 API リクエストとメール 1,000 通）はそのまま適用した |
| 構成 | 変数の既定値のまま。`enable_dedicated_scheduler = false`、`cpu_architecture = X86_64`、`inhouse_notifier_existing_queue_arn = null`（critical 用キューを本リポジトリで作る） |
| アラート量（基準） | Alertmanager の webhook が **月 10 万件**（平均 2.3 件/分）。そのうち critical は 10%。感度分析として月 100 万件も計算した（§5） |
| 範囲外 | 大阪 DR（フェーズ 3）、内製ツール側の Lambda と ESM、Route 53 ホストゾーン（既存のものを使い、本リポジトリでは作らない）、送信元 EKS 側の NAT、サポートプラン、運用の人件費 |

## 2. 結果（合計）

| | 月額 | 年額（365 日 24 時間） |
|---|---:|---:|
| **基準（10 万件/月）** | **約 558 USD** | **約 6,700 USD（約 100 万円）** |
| 高負荷（100 万件/月） | 約 614 USD | 約 7,370 USD（約 111 万円） |

- 費用の約 **98% は時間課金の固定費**（RDS、NAT、Fargate、ElastiCache、ALB、WAF、パブリック IPv4、CloudWatch）。アラート量を 10 倍にしても、年額は約 10% しか増えない。
- 上位 3 つ（RDS、NAT Gateway、Fargate）で全体の約 74% を占める。

## 3. サービスごとのランニングコスト（基準：10 万件/月）

| # | サービス | 月額 (USD) | 年額 (USD) | 構成比 | 算定式（Tokyo 単価） |
|---|---|---:|---:|---:|---|
| 1 | RDS for PostgreSQL | 161.26 | 1,935.12 | 28.9% | db.t4g.medium Multi-AZ $0.202/h × 730 h + gp3 Multi-AZ $0.276/GB-月 × 50 GB。バックアップは 7 日保持で、プロビジョニング容量（50 GB）までは無料の範囲に収まる想定 |
| 2 | NAT Gateway（Regional） | 137.08 | 1,644.98 | 24.6% | $0.062/h × 3 AZ × 730 h + データ処理 $0.062/GB × 約 21 GB |
| 3 | ECS Fargate（x86_64） | 112.46 | 1,349.48 | 20.1% | vCPU $0.05056/h、メモリ $0.00553/GB-h。API（1 vCPU / 2 GB）× 2 + UI（0.5 vCPU / 1 GB）× 1 |
| 4 | ElastiCache for Valkey | 57.23 | 686.78 | 10.3% | cache.t4g.small $0.0392/h × 2 ノード × 730 h。スナップショット 1 世代は無料 |
| 5 | CloudWatch | 33.25 | 398.98 | 6.0% | Container Insights（enhanced）299 メトリクス × $0.07 = 20.93、アラーム 18 個 × $0.10 = 1.80、API Gateway の詳細メトリクス 7 × $0.30 = 2.10、ログ取り込み 約 9.8 GB × $0.76 = 7.45、ログ保存（90 日）× $0.033 = 0.97 |
| 6 | ALB（internal） | 23.58 | 282.95 | 4.2% | $0.0243/h × 730 h + LCU $0.008/h × 平均 1 LCU（保守的な仮定） |
| 7 | パブリック IPv4 | 10.95 | 131.40 | 2.0% | NAT の EIP 3 個 × $0.005/h × 730 h |
| 8 | AWS WAF | 10.06 | 120.72 | 1.8% | Web ACL $5 + ルール 5 個（レート制限、マネージドルールグループ × 3、IP 許可）× $1 + $0.60/100 万リクエスト |
| 9 | Secrets Manager | 3.90 | 46.80 | 0.7% | 8 シークレット × $0.40（Terraform が作る 6 個 + Keep がプロバイダ登録時に作る分として 2 個を仮定）+ API $0.05/1 万回 |
| 10 | DynamoDB（Journal） | 2.44 | 29.33 | 0.4% | オンデマンド。1 件あたり約 30 WRU（約 5 KB の項目を Put 1 回 + 状態更新 4〜5 回、GSI を含む）× $0.715/100 万 + 読み取り + 保存 0.5 GB（TTL 30 日）+ PITR |
| 11 | X-Ray | 1.30 | 15.60 | 0.2% | Active tracing。約 26 万トレース × $5/100 万（この流量ではほぼ全件がサンプリングされる） |
| 12 | KMS | 1.30 | 15.60 | 0.2% | CMK 1 個（アラーム用 SNS）$1 + リクエスト。ほかの暗号化は AWS マネージドキーか SSE-SQS で、キーの月額はかからない |
| 13 | AZ 間データ転送 | 1.04 | 12.48 | 0.2% | $0.01/GB × 双方向 × 約 52 GB（Keep ↔ RDS / Valkey / ALB の AZ 跨ぎ。仮定） |
| 14 | SQS FIFO | 0.84 | 10.08 | 0.2% | $0.50/100 万リクエスト。ESM のアイドル時のロングポーリング（2 本 × 約 65 万回/月、推定）+ 1 件あたり約 3.8 リクエスト |
| 15 | ECR | 0.50 | 6.00 | 0.1% | 5 GB（keep-api と keep-ui を数世代分。仮定）× $0.10 |
| 16 | API Gateway（REST） | 0.42 | 5.10 | 0.1% | $4.25/100 万リクエスト |
| 17 | Lambda × 4（arm64） | 0.39 | 4.70 | 0.1% | 約 27 万回 × $0.20/100 万 + 約 2.5 万 GB 秒 × $0.0000133334 |
| 18 | SNS | 0.21 | 2.46 | 0.0% | critical のメール約 1 万通（最初の 1,000 通は無料）× $2/10 万 |
| 19 | S3（tfstate） | 0.04 | 0.42 | 0.0% | 1 GB 未満 |
| | Route 53 / ACM | 0 | 0 | — | ホストゾーンは既存。レコードは AWS リソースへのエイリアスでクエリは無料。ACM のパブリック証明書は無料 |
| | **合計** | **558.25** | **6,698.98** | 100% | 約 100 万円/年 |

## 4. リソースの割当量

### 4.1 コンピュート

| リソース | 割当量 | 台数・同時実行数 | 定義箇所 |
|---|---|---|---|
| Keep API（ECS Fargate） | 1 vCPU / 2 GiB、エフェメラルストレージ 20 GiB（既定）、x86_64 | 2 タスク（デプロイ中は最大 200% = 4 タスク） | `keep_platform` `api_cpu_units` / `api_memory_mb` / `api_desired_count` |
| Keep UI（ECS Fargate） | 0.5 vCPU / 1 GiB | 1 タスク | `ui_cpu_units` / `ui_memory_mb` / `ui_desired_count` |
| Keep scheduler（任意） | 1 vCPU / 2 GiB | 0（`enable_dedicated_scheduler = true` で 1 タスク） | `services.tf` |
| **Fargate の定常合計** | **2.5 vCPU / 5 GiB** | 3 タスク | |
| Lambda authorizer | 256 MB / タイムアウト 10 秒、arm64 | 予約なし（オーソライザ結果のキャッシュ 300 秒） | `alert-pipeline/functions.tf` |
| Lambda ingest | 512 MB / 29 秒 | 予約なし（API のスロットリング 50 rps / バースト 200 が上限） | 同上 |
| Lambda router | 512 MB / 30 秒 | ESM の最大同時実行数 10、バッチ 10 | 同上 |
| Lambda dispatcher（VPC 内） | 512 MB / 60 秒 | 予約同時実行数 3、ESM の最大同時実行数 3、バッチ 5 | `dispatcher_reserved_concurrency` / `dispatcher_maximum_concurrency` |

### 4.2 データストア

| リソース | 割当量 | 定義箇所 |
|---|---|---|
| RDS for PostgreSQL 17 | db.t4g.medium（2 vCPU / 4 GiB、Graviton2、T 系のバースト）、Multi-AZ | `db_instance_class` |
| RDS ストレージ | gp3 50 GiB で開始し、自動拡張の上限は 200 GiB。400 GiB 未満なので IOPS と帯域は gp3 のベースラインになる | `db_allocated_storage_gb` / `db_max_allocated_storage_gb` |
| RDS バックアップ | 自動バックアップ 7 日、Performance Insights（既定の 7 日保持）、拡張モニタリング 60 秒 | `data_stores.tf` |
| ElastiCache for Valkey 8.0 | cache.t4g.small（2 vCPU / 1.37 GiB）× 2（プライマリ + レプリカ、自動フェイルオーバー） | `cache_node_type` |
| DynamoDB Journal | オンデマンド（容量の事前割当なし）、TTL 30 日、PITR、Streams | `alert_journal`、`journal_ttl_days` |
| SQS | FIFO 4 本（alerts、keep-delivery、critical-inhouse、non-critical-inhouse）+ DLQ 4 本。保持 14 日、`maxReceiveCount` 5 | `alert_queues` |

### 4.3 ネットワークと受信口

| リソース | 割当量 | 定義箇所 |
|---|---|---|
| VPC | 10.40.0.0/20。private サブネット /22 × 3 AZ（1a、1c、1d） | `foundation/terraform.tfvars` |
| NAT Gateway | Regional 1 個（3 AZ で稼働）、EIP 3 個を固定 | `network` |
| ALB | internal 1 個、3 サブネット | `keep_platform/load_balancer.tf` |
| API Gateway | REST（Regional）、ステージのスロットリング 50 rps / バースト 200 | `alert_ingress` |
| WAF | 5 ルール（WCU は約 930 と推定し、既定のリクエスト単価の範囲に収まる）。レート制限 2,000 件/5 分/IP（既定は COUNT） | `alert_ingress/waf.tf` |
| ログ保持 | コンテナ、Lambda、API、WAF、VPC フローログはすべて 90 日 | 各 `log_retention_days` |

## 5. 感度分析（年額への影響）

| 変更 | 年額への影響 | 備考 |
|---|---:|---|
| アラート量を 10 万件/月 → 100 万件/月 | +約 675 USD | 増える主な項目は DynamoDB、X-Ray、API Gateway、Lambda |
| `enable_dedicated_scheduler = true`（完了条件 6 の結果次第） | **+約 540 USD** | 1 vCPU / 2 GiB のタスクが 1 つ増える |
| RDS と ElastiCache を 1 年のリザーブドインスタンス（前払いなし）にする | **−約 617 USD** | RDS $0.202 → $0.1572/h、Valkey $0.0392 → $0.0264/h（いずれも Price List の Reserved 条件） |
| Fargate を arm64 にする（U5 が解消した場合） | −約 270 USD | vCPU $0.04045/h、メモリ $0.00442/GB-h |
| NAT の稼働 AZ を 3 → 2 に減らす | −約 587 USD | EIP も 1 個減る。可用性の設計判断なので推奨はしない（§7） |
| RDS を Single-AZ にする | −約 968 USD | Multi-AZ はフェーズ 3 の前提。推奨しない |
| RDS の CPU クレジット超過 | +$0.075/vCPU-h | t4g は既定で unlimited。CPU がベースラインを長く超えると課金される |

## 6. 情報の確からしさ

| 区分 | 項目 |
|---|---|
| 一次情報で確認済み | 本書に書いた Tokyo の単価はすべて AWS Price List Bulk API の値（Regional NAT の時間単価 `APN1-RegionalNatGateway-Hours` $0.062、Fargate、RDS、ElastiCache、ALB、WAF、API Gateway、Lambda、DynamoDB、SQS、SNS、Secrets Manager、KMS、CloudWatch、X-Ray、ECR、S3、パブリック IPv4、データ転送、Reserved の条件）。構成と割当量は本リポジトリのコードから読んだ |
| **未確認**（AWS のドキュメント本文はネットワークポリシーで取得できず、検索結果の抜粋のみ。条件 1 の Cost Explorer の実績で確かめる） | Regional NAT は「稼働している AZ ごと」に時間課金される。Container Insights（enhanced、ECS）のメトリクス数は、クラスター 29、サービス 31、タスク定義 26、タスク 26、コンテナ 26（AWS の料金例 2,264 メトリクスと計算が一致する）。RDS のバックアップはプロビジョニング容量まで無料。ElastiCache のスナップショットは 1 世代無料。Performance Insights / Database Insights Standard は 7 日保持まで無料 |
| 仮定（実測で置き換える） | アラート量、ログ量（ECS 5 GB、VPC フローログ 3 GB、RDS 1 GB/月）、NAT のデータ処理量 20 GB/月、ALB 1 LCU、Keep が作るシークレット数、ECR の容量、SQS ESM のアイドル時のポーリング回数、DynamoDB の項目サイズ（5 KB） |
| 未確認 | Regional NAT の手動モードで課金対象になる AZ の数（計画書 §14 U7。3 AZ を前提にした）。Keep がワークフローの実行ごとに Secrets Manager を読むかどうか（API 料金に影響するが、額は小さい） |

## 7. 裁定

**裁定: 現行の構成とリソース割当量は、フェーズ 1 のランニングコストとして妥当とする。年額は約 6,700 USD（約 100 万円、税抜き）を見込む。** ただし次の 3 点を条件とする。

**条件**
1. 最初の apply から 1 か月後に Cost Explorer の実績と本書を突き合わせる。確認するのは特に、Regional NAT が課金される AZ の数（U7）、Container Insights のメトリクス数、CloudWatch Logs の取り込み量の 3 つ。
2. リザーブドインスタンス（RDS と ElastiCache、1 年、前払いなし。年 −約 617 USD）は、完了条件 7（復旧時のバースト）で db.t4g.medium と cache.t4g.small の大きさが足りると確かめてから買う。
3. フェーズ 3（大阪 DR）の費用は本書の範囲外である。PagerDuty との比較で判断するときは、大阪分を加えた総額で行う。

**なぜこの裁定に至るのか（so that ×3）**

- **so that ①：費用の中身が「アラート量」ではなく「常時稼働の土台」だと分かり、管理すべき対象がはっきりするため。**
  - 固定費が約 98% を占め、アラートが 10 倍になっても年額は約 10% しか増えない。
  - 費用を動かすのは RDS、NAT、Fargate の 3 つ（約 74%）と、`enable_dedicated_scheduler` の切り替え（+約 540 USD/年）である。いずれも変数 1 つで変えられ、計画書の条件 3 の検証結果に応じて確定できる。
- **so that ②：大きな費目を削ると、計画書で固定した可用性の前提が崩れるため。**
  - RDS の Multi-AZ（−約 968 USD/年で削れる）は、フェーズ 3 のクロスリージョンレプリカの元である（計画書 §8、§13）。
  - NAT の 3 AZ は、Keep と Dispatcher の AWS API への経路を AZ 障害から守る。1 AZ 減らしても年 −約 587 USD にとどまる。
  - これらを削る節約は、「critical を落とさない」という設計の目的と釣り合わない。いま削れるのは、可用性に影響しない購入形態（リザーブドインスタンス）とアーキテクチャ（arm64、U5 の解消後）だけである。
- **so that ③：PagerDuty（年間約 200 万円、`why-keep.md`）と比べる土台ができるため。**
  - フェーズ 1 の AWS 費用は、その約半分（約 100 万円）である。
  - ただし、ここには運用の人件費と大阪 DR の費用が入っていない。東京と同じ構成を大阪に置けば、AWS 費用だけで PagerDuty に近づきうる（未試算）。
  - したがって、本書は解約判断の根拠そのものではない。フェーズ 3 の構成を決めるときの予算の上限として使う。

**付記**: 単価は 2026-09 時点の Price List による。単価の改定や為替で数字は変わるため、再試算するときは本書 §1 のエンドポイントから同じ usagetype の単価を取り直す。
