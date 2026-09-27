# non-critical アラート通知の契約（Keep → 内製ツール）

critical 以外のアラート（Keep の `severity` が `critical` でないもの）は、Keep のワークフローから SQS FIFO キューを経由して内製ツールに届けます。critical の直送経路（[`critical-notification-contract.md`](critical-notification-contract.md)）とは別のキューです。

| 項目 | 内容 |
|---|---|
| 経路 | Keep ワークフロー `non-critical-to-inhouse`（[`keep-workflows/non-critical-to-inhouse.yaml`](../keep-workflows/non-critical-to-inhouse.yaml)）→ SQS `keep-non-critical-inhouse.fifo` → 内製ツール Lambda（SQS イベントソースで起動） |
| キューの置き場所 | 本リポジトリの `keep` ルート（送信側の Keep と同じルート）。出力は `non_critical_inhouse_queue_arn` / `_url` / `_name`、`non_critical_inhouse_dead_letter_queue_name` |
| 役割分担 | Keep は「通知するかどうか」（重複除去、抑制）だけを決めます。どのルームに送るかは内製ツールが決めます |

- 配送は **at-least-once** です。受け手は重複排除キー（後述）で重複を除いてください。
- アラート（fingerprint）ごとの順序（firing → resolved）は、FIFO の `MessageGroupId` で保たれます。

## メッセージ本文（Keep の AlertDto の JSON）

本文は Keep の AlertDto をそのまま JSON にしたものです。ワークフローで `message: "{{ alert }}"` を渡しており、`AlertDto.__str__` は `json.dumps(self.dict(), indent=4, default=str)` を返します（keephq/keep v0.54.3 `keep/api/models/alert.py`）。

```json
{
    "id": "…",
    "name": "KubePodCrashLooping",
    "status": "firing",
    "severity": "warning",
    "lastReceived": "2026-09-23T00:00:01.234Z",
    "description": "pod is crash looping",
    "fingerprint": "prod:a1b2c3d4e5f60708",
    "labels": { "alertname": "KubePodCrashLooping", "severity": "warning", "system": "billing" },
    "annotations": { "summary": "pod is crash looping" },
    "…": "（AlertDto のその他のフィールド）"
}
```

| フィールド | 意味 |
|---|---|
| `fingerprint` | `<source>:<Alertmanager の fingerprint>`。Dispatcher が Keep に渡す値で、firing と resolved を対応付けるキー |
| `status` | Keep のアラートの状態（`firing`、`resolved` など） |
| `severity` | Keep の severity。`critical` 以外のものだけがこの経路に来ます |
| `name`、`description` | アラート名と説明 |
| `lastReceived` | Keep がこのアラートを最後に受け取った時刻 |
| `labels`、`annotations` | Alertmanager のラベルと注釈 |

- critical の契約（`schemaVersion: 1` の JSON）とはスキーマが異なります。1 つの Lambda で両方のキューを消費する場合は、Lambda イベントのレコードの `eventSourceARN` でどちらのキューのメッセージかを判別してください。
- 本文の形は Keep の版に依存します。Keep を更新するときは、AlertDto の変更点を確認してください（§未確認の U15）。

## SQS の属性と重複排除キー

| 属性 | 値 |
|---|---|
| `MessageGroupId` | `fingerprint` |
| `MessageDeduplicationId` | `<fingerprint>:<status>:<lastReceived>` |

- Keep の amazonsqs プロバイダは、キュー URL が `.fifo` で終わると `MessageGroupId` と `MessageDeduplicationId` を付けて送ります。どちらも省略できません（keephq/keep v0.54.3 `keep/providers/amazonsqs_provider/amazonsqs_provider.py` の `_notify`、`__write_to_queue`）。
- **重複排除キー**は `MessageDeduplicationId` と同じ値です。本文の `fingerprint`、`status`、`lastReceived` から同じ値を組み立てられるので、受け手は本文だけで冪等に処理できます（例：DynamoDB の条件付き書き込み）。

## システム名のラベルと振り分け

- **システム名は `labels.system`** です。Alertmanager のアラートに `system` ラベルを付けてください。
  - Keep の prometheus プロバイダは、ラベルのキーを小文字にして取り込みます（keephq/keep v0.54.3 `keep/providers/prometheus_provider/prometheus_provider.py` の `_format_alert`）。そのため `System` と書いても `system` になります。
  - critical の JSON でも、同じラベルは `labels.system` に入ります。
- **対応表**：システム名 → 通知ルームの対応表は、内製ツールのリポジトリに YAML で置き、Git で管理します。critical と non-critical で**同じ対応表**を使います。本リポジトリと Keep のワークフローは対応表を持ちません。
- **フォールバック**：`labels.system` が無いアラートや、対応表に無いシステム名のアラートは、内製ツールがフォールバックのルームに送ります。
  - そのため、Keep のワークフローは `labels.system` を参照しません。ワークフローの `with` の値はキーが無いとレンダリングに失敗し、そのアラートの送信自体が失敗するためです（keephq/keep v0.54.3 `keep/iohandler/iohandler.py` の `render_context`、`_render`）。

## Keep のスコープ検証メッセージ

Keep は amazonsqs プロバイダを登録するときに、本文が `KEEP_SCOPE_TEST_MSG_PLEASE_IGNORE`、`MessageGroupId` が `keep` のテストメッセージをキューへ送ります（`amazonsqs_provider.py` の `validate_scopes`）。内製ツールはこのメッセージを**処理せずに削除（成功扱い）**してください。いつ送られるか（登録時のみか、定期的か）は未確認です（U13）。

## 内製ツール側の設定（管理アカウント）

1. **イベントソースマッピング**：内製ツールの Lambda に、`non_critical_inhouse_queue_arn` のキューを SQS トリガーとして設定します。
   - `function_response_types = ["ReportBatchItemFailures"]` にし、失敗したメッセージ以降を同じバッチ内ですべて失敗として返してください。アラートごとの順序が保たれます。
2. **IAM**：ツールの実行ロールに `sqs:ReceiveMessage`、`sqs:DeleteMessage`、`sqs:GetQueueAttributes` をこのキューの ARN に対して付与します（同一アカウントなのでキューポリシーは不要）。
3. **タイムアウト**：キューの可視性タイムアウト（既定 900 秒）は、ツール Lambda のタイムアウトの 6 倍以上にします。`keep` ルートの `inhouse_notifier_visibility_timeout_seconds` で調整できます。
4. **重複排除**：上記の重複排除キーで冪等に処理してください。
5. **失敗時**：5 回受信しても処理できないと DLQ（`keep-non-critical-inhouse-dlq.fifo`）に移り、アラームが鳴ります。

## Keep 側の手作業（人が行う）

`keep` ルートの apply 後に、次を行います。Terraform は Keep の中の設定を管理しません。

1. **プロバイダの登録**：Keep の UI で amazonsqs プロバイダを `inhouse-non-critical` という名前で登録します。
   - `region_name` = `ap-northeast-1`
   - `sqs_queue_url` = 出力 `non_critical_inhouse_queue_url`
   - アクセスキーは空欄にし、ECS のタスクロールを使います（タスクロールには、このキューへの `sqs:SendMessage`、`sqs:GetQueueUrl`、`sqs:GetQueueAttributes` だけが付いています）。
2. **ワークフローの反映**：[`keep-workflows/non-critical-to-inhouse.yaml`](../keep-workflows/non-critical-to-inhouse.yaml) を Keep に登録します。

**不変条件：Keep のタスクロールに `sqs:ReceiveMessage` や `sqs:DeleteMessage` を付けないでください。** Keep は `CONSUMER=true` で動いており（`modules/keep_platform/main.tf`）、amazonsqs プロバイダは `start_consume` を持つため、登録済みのプロバイダでキューの消費を試みます（keephq/keep v0.54.3 `keep/event_subscriber/event_subscriber.py`）。現在は受信権限が無いので消費に失敗して終わりますが、権限を付けると Keep が内製ツール宛てのメッセージを横取りし、アラートとして取り込んでワークフローで再び送るループになります。

## critical との境界

- ワークフローの条件は `severity != "critical"`（Keep の severity）です。Keep の severity が `critical` になるのは、`labels.severity` が `critical` のときだけです（`prometheus_provider.py` の `SEVERITIES_MAP`。未知の値は `info`）。
- router Lambda の `critical_severities`（既定 `["critical"]`、`labels.severity` と完全一致）と一致しているのは既定値のときだけです。`critical_severities` を広げると、そのアラートは critical 経路と non-critical 経路の両方に届きます。変えるときはワークフローの CEL も合わせてください。
- CEL は `labels.severity != "critical"` ではなく `severity != "critical"` と書きます。Keep は `<識別子> <演算子> "critical"` の形の式を severity の数値比較に書き換えるためです（keephq/keep v0.54.3 `keep/api/utils/cel_utils.py`）。

## 監視

アラームは `alert-pipeline` ルートの `module.monitoring` が作ります。

| アラーム | 意味 |
|---|---|
| `alert-pipeline-non_critical_inhouse-oldest-message-age` | 内製ツールがキューを消費していない（既定 300 秒。`non_critical_inhouse_max_oldest_message_seconds`） |
| `alert-pipeline-non_critical_inhouse-dlq-not-empty` | 内製ツールがメッセージを処理できていない |

Keep がキューに送れていない場合（プロバイダ未登録、ワークフローの失敗）は、このアラームでは検知できません。Keep のワークフロー実行履歴で確認します。

## 未確認

番号は [`implementation-plan.md`](implementation-plan.md) §14 と共通です。

- **U11**：`{{ alert }}` が実行時に正しい JSON になるか。ソース上は `AlertDto.__str__` → chevron の HTML エスケープ → Keep の `html.unescape` の順で JSON に戻りますが、値に `&lt;` などの実体参照や `keep.xxx(` のような文字列を含むと、変形や関数評価のエラーになる可能性があります。Keep の初回構築時にテストアラートを送り、本文を確認します。
- **U12**：Alertmanager の再送（Keep が重複として扱うイベント）でワークフローが起動するか。起動する場合は通知量が増えるので、`only_on_change: [status]` を追加するかを判断します。GameDay で確認します。
- **U13**：スコープ検証メッセージが送られる時機（登録時のみか、定期的か）。
- **U14**：SQS の `MessageGroupId` / `MessageDeduplicationId` の長さと文字種の制約、メッセージサイズの上限。AWS の一次情報源を未取得です。fingerprint は `<source>:<16 桁の hex>` なので、128 文字以内に収まる見込みです。
- **U15**：配備する Keep のタグが v0.54.3 と同じ挙動か。イメージのミラー時にソースの差分を確認します。
