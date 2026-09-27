# コーディングエージェント（Claude Code）環境の設計と裁定

- 作成日: 2026-09-27
- 対象: 本リポジトリで Claude Code が「計画 → 実装 → レビュー → テスト」を回すための環境（`CLAUDE.md`、`.claude/`、CI の harness ジョブ）
- 方針
  - 推論ではなく一次情報源（公式ドキュメント、takt の公式リポジトリ）で前提を確認し、確認できなかったものは「未確認」として分ける。
  - takt の思想（エージェントは外から制御する、次に何をするかはワークフローが決める）を、Claude Code の標準機能（サブエージェント、スキル、フック、権限）で実装する。

---

## 1. 目的と範囲

| 項目 | 内容 |
|---|---|
| 目的 | エージェントに任せても次の 3 点が崩れない開発環境を作る。<br>- 計画を飛ばさない<br>- レビューとテストを黙って省略しない<br>- 修正ループが止まらなくならない |
| 範囲内 | 次の 7 つ<br>- ワークフロー定義と遷移エンジン<br>- エージェント 7 種<br>- ポリシーと規約（rules）<br>- スキル 3 種<br>- フック 4 種<br>- 検証スクリプト<br>- クラウドセッションの環境構築、CI の harness ジョブ |
| 範囲外 | 次の 2 つ<br>- 実 AWS への apply（人が行う）<br>- takt CLI そのものの導入（§3.3 で比較） |

## 2. 前提確認の結果（一次情報源）

| # | 事実 | 一次情報源 | 設計への反映 |
|---|---|---|---|
| T1 | takt は「AI エージェントを信頼するのではなく外から制御する」。「エージェントはコードを書けるが、次に何をするかはワークフローが決める」。「レビューは黙って省略できない」 | `nrslib/takt` の README（2026-09-26 時点の main、npm の最新は 0.66.1、MIT） | ラベルから次の step を決めるのはエンジン（`workflow.mjs`）で、エージェントは決めない |
| T2 | Faceted Prompting は 5 つの関心事に分かれる：Persona、Policy、Instruction、Knowledge、Output Contract | takt `docs/faceted-prompting.md` | agents / policies / workflow の instruction / docs と rules / 出力契約、の 5 つに分けた（§3.1） |
| T3 | ルールは YAML の順に評価され、一致しなければ `rule_no_match` で中断する。終端は `COMPLETE` と `ABORT` | takt `docs/workflows.md` | ルールを上から評価する。一致しないラベルは拒否する（§3.2 の差異を参照） |
| T4 | `loop_monitors` は cycle、threshold、judge を持ち、進捗しているかを AI の judge に判定させる。judge は常に新しいセッションで動く | takt `docs/workflows.md` | review-fix の監視を置く。閾値 3 で supervisor が judge になり、上限 5 回で人に戻す |
| T5 | レビューの step は `edit: false` にしてレビュアーにコードを変えさせない | takt `docs/workflows.md`（Best practice） | レビュアーには編集ツールを与えない。さらに作業ツリーの指紋を比べる |
| T6 | 組み込みの `terraform` ワークフローは次の流れ：plan → implement → 並列レビュー → final gate → fix → complete。`max_steps: 15`、fix ⇄ reviewers の監視は threshold 3 | takt `builtins/en/workflows/terraform.yaml` | 本リポジトリの `develop` の骨格に採用した（Terraform 中心のため） |
| T7 | supervise は、環境のせいで検証できないときは fix ループに戻さず `BLOCKED` で止める | takt `docs/workflows.md` | supervisor の `blocked` は `ASK_HUMAN` へ遷移する |
| C1 | 権限は deny → ask → allow の順に評価され、最初に一致したものが勝つ。Bash の deny はセキュリティ境界ではない（`bash -c` などで回避できる） | https://code.claude.com/docs/en/permissions | deny は settings に書き、確実に止める処理は PreToolUse フックで行う（多層） |
| C2 | フックは exit 2 または `permissionDecision` で止める。Stop フックの `decision: "block"` は作業を続けさせる。`stop_hook_active` を見る。連続の継続は既定で 8 回が上限で、超えると次の block を上書きしてターンを終える。上限は環境変数 `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` で変えられる（Stop と SubagentStop に適用、0 で上限なし） | https://code.claude.com/docs/en/hooks 、https://code.claude.com/docs/en/env-vars | Stop ゲートは自前のカウンタで 3 回までに抑え、組み込みの上限より先に人へ戻す（`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` は設定しない） |
| C3 | サブエージェントは `.claude/agents/*.md`。`tools` で使えるツールを絞れる（省略すると全ツールを継承する）。frontmatter の `Stop` フックは `SubagentStop` として動く。設定ファイルのフックはサブエージェントのツール呼び出しでも動き、入力に `agent_id` と `agent_type` が付く。`.claude/agents/` の追加・変更は数秒で検出され再起動は要らないが、セッション開始時に無かった `agents` ディレクトリは監視されず、再起動が要る | https://code.claude.com/docs/en/sub-agents 、https://code.claude.com/docs/en/hooks | read-only のエージェント 6 種（planner、4 レビュアー、supervisor）には編集ツール（Edit、Write、MultiEdit、NotebookEdit）を与えない。基本は Read/Grep/Glob/Bash で、planner は WebFetch と WebSearch、ai-antipattern-reviewer は WebFetch を加える（テストで固定：§7）。implementer にだけ Stop ゲートを付けた。ガードは `agent_id` の有無で区別せず、サブエージェントの編集も read-only step の間は拒否する |
| C4 | スキルは `.claude/skills/<name>/SKILL.md`。カスタムコマンドはスキルに統合された | https://code.claude.com/docs/en/skills | `/develop`、`/verify`、`/peer-review` |
| C5 | CLAUDE.md は 1 ファイル 200 行未満が目安。`@import` が使える。`.claude/rules/*.md` は `paths` を付けると、該当するファイルを読んだときだけ読み込まれる | https://code.claude.com/docs/en/memory | CLAUDE.md は約 40 行。規約は rules に分け、対象のパスでだけ読み込ませる |
| C6 | クラウドセッションでは `CLAUDE_CODE_REMOTE=true`。SessionStart フックは `CLAUDE_ENV_FILE` に書いた環境変数を後続のコマンドへ引き継ぐ | https://code.claude.com/docs/en/hooks 、https://code.claude.com/docs/en/cloud-environments | `session-start.sh` |
| C7 | 公式のベストプラクティスは 3 つ<br>- 検証手段を与える<br>- Explore → Plan → Implement → Commit の順で進める<br>- 新しいコンテキストのサブエージェントに敵対的なレビューをさせる | https://code.claude.com/docs/en/best-practices | ワークフロー全体の骨格。レビュアーは別コンテキストで、報告だけを受け渡す |
| A1 | evaluator-optimizer パターンは、評価基準が明確で反復に効果があるときに使う。反復回数の上限などの停止条件を置く | https://www.anthropic.com/engineering/building-effective-agents | レビュー → 修正ループの評価基準を review policy で明文化し、すべてのループに上限を置いた |
| A2 | 長時間動くエージェントには、進捗ファイル、1 セッションで 1 機能、「テストを消したり編集したりしてはならない」 | https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents（**本文ではなく要約経由で確認**） | step 間の記憶は `.agent-runs/<run>/` の報告だけにした。テストを弱めることは policy で禁止した |
| E1 | この環境では registry.terraform.io が 403、releases.hashicorp.com と github.com のリリースは取得できる | 実測（2026-09-27、本セッション） | SessionStart で provider のファイルシステムミラーを作る |

## 3. takt の思想の適用

### 3.1 対応表

| takt | 本リポジトリ | 補足 |
|---|---|---|
| workflow（YAML） | `.claude/workflows/develop.json` | 依存なしの Node で読めるよう JSON にした。構造（step、ルール、並列、ループ監視、step 数の上限）は takt を手本にしたが、キーの互換はない。名前と意味が takt と一致するキーは `max_steps`、`initial_step`、`edit`、`rules` と `next`、`loop_monitors` の `cycle`・`threshold`・`judge` だけである（移行に要る対応付けは §3.3） |
| ワークフローの実行系 | `.claude/scripts/workflow.mjs` | Claude Code にはワークフローの実行系がないため、遷移・予算・ループ監視・read-only の検査をスクリプトで確定的に行う |
| Persona | `.claude/agents/*.md` | planner、implementer、code-reviewer、security-reviewer、ai-antipattern-reviewer、tester、supervisor |
| Policy | `.claude/policies/coding.md`、`.claude/policies/review.md` | 「根拠がなければ指摘ではない」「non-blocking では修正ループに入らない」「再レビューは前回の指摘の確認から始める」 |
| Knowledge | `docs/*.md`、`.claude/rules/*.md`（paths 付き） | Terraform の規約は implementation-plan §5 をそのまま rules にした |
| Instruction | workflow の各 step の `instruction` | エンジンが step ごとに表示する |
| Output Contract | 各エージェント末尾の出力契約と、最終行の `LABEL:` | エンジンは、保存された報告の `LABEL:` と一致しないラベルを受け付けない |
| `edit: false` | 次の 3 重で担保<br>- 編集ツールを与えない（エージェント定義の `tools`。`subagent_type` で起動したときだけ効く）<br>- step の開始時と終了時に作業ツリーの指紋を比べる（exit 4。Bash による編集も検出する）<br>- read-only step の間はガードが編集ツールによる編集を拒否する（メインセッションとサブエージェントの両方） | `.agent-runs/` への報告の書き込みは許可する<br>エージェントが未ロードで general-purpose に persona ファイルを読ませて代行したとき（H8）は 1 つ目が効かず、ガードと指紋の 2 重になる<br>read-only step を放置すると、その間はどのエージェントも編集できない。`workflow.mjs next - abort` で解除する |
| parallel + `all()`/`any()` | `reviewers` step（4 名を並列に実行） | `all: approved` なら supervise、`any: needs_fix` なら fix |
| `loop_monitors` + judge | `review-fix`（threshold 3、max 5）、`replan`（max 1） | judge は supervisor。`$resume` で中断した遷移を再開する |
| `max_steps` | 20 | 組み込みの terraform ワークフロー（15）に、replan と judge の分を足した |
| supervisor の `BLOCKED` | `blocked` → `ASK_HUMAN` | 人の判断へのエスカレーションを終端状態として明示した |
| `.takt/runs/` のレポート | `.agent-runs/<run>/NN-<step>/` | git 管理外。step 間の唯一の記憶 |

### 3.2 takt と意図的に変えた点

- **一致しないラベル**：takt は `rule_no_match` で中断するが、本エンジンは入力エラー（exit 2）として step を消費せずに拒否する。ラベルの誤りは多くがオーケストレータの転記ミスだからである。報告のやり直しは 1 回まで（SKILL で規定）とし、2 回目は `ask_human` にする。
- **judge が「進捗なし」と判定したときの行き先**：takt の例（`docs/workflows.md` の `loop_monitors`、組み込みの `terraform.yaml`）は `ABORT` だが、本リポジトリの `review-fix` の judge は `unproductive` → `ASK_HUMAN` にした。振動や要件の衝突は人が判断すれば進められることが多く、run を捨てるより人に戻す方が作業を失わないからである。上限（max 5）に達したときの `on_max` も同じく `ASK_HUMAN` である。
- **ステップの 3 フェーズ**（本作業 → 報告 → 判定）：takt はランタイム側で分けている。Claude Code では、サブエージェントの戻り値が出力契約（報告と `LABEL:`）を兼ねる。

### 3.3 takt CLI をそのまま使わない理由

| 案 | 内容 | 評価 |
|---|---|---|
| **A（採用）** | Claude Code の標準機能と、小さなエンジンで takt の思想を再現する | 利用者が普段使う Claude Code（Web、アプリ、CLI）の中で完結する<br>フックと権限で確定的に止められる<br>追加の依存がない（Node のみ） |
| B | takt CLI（`npm i -g takt`、provider は claude）を導入する | 機能は豊富（ループ監視、parallel、レポート）<br>ただし Claude Code のセッションの外で動き、Claude Code を子プロセスとして呼ぶ構成になる<br>クラウドセッションの権限・フックとの二重管理になる |
| C | CLAUDE.md に手順を書くだけ | 手順を飛ばしても検出できない（CLAUDE.md は助言であって強制ではない：C1、C5） |

`develop.json` の構造は takt を手本にしたが、takt の YAML とキーの互換はない（takt `docs/workflows.md` と `builtins/en/workflows/terraform.yaml` で確認）。将来 B に移るときは、YAML に書き写すだけでは済まず、次の対応付けが要る。
- ルールの `when` → `condition`
- step の `agent` → `persona`
- `steps` のマップ（キーが step 名）→ `name` を持つ step のリスト
- ルールの `all`/`any` のキー → 条件式 `all("x")`/`any("x")`
- `parallel` のエージェント名の配列 → サブ step（`name`、`persona`、`rules` を持つ）のリスト
- `all_steps.rules`：本リポジトリでは全 step に共通の遷移ルールだが、takt では規約の参照（`ref`、`position`）であり意味が違う

次のものは takt に相当するものが無く、再設計が要る。
- `ASK_HUMAN`（takt の終端は `COMPLETE` と `ABORT` だけ）
- judge のルールの `$resume`
- `loop_monitors` の `name`、`max`、`on_max`

## 4. ハーネスエンジニアリング

「プロンプトは助言、強制はコード」という方針で、層ごとに役割を分けた。

| 層 | 実体 | 強制力 | 役割 |
|---|---|---|---|
| コンテキスト | `CLAUDE.md`（約 40 行）、`.claude/rules/*`（paths 付き）、`.claude/policies/*` | 助言 | 規約、コマンド、禁止事項を伝える。必要なときだけ読み込ませる |
| 権限 | `.claude/settings.json` の allow / ask / deny | 確定的（ただし Bash の文字列一致にとどまる） | 検証コマンドは許可する。apply と state 系は拒否する |
| ガード | `hooks/guard.mjs`（PreToolUse） | 確定的。入力を読めないときは止める側に倒す（exit 2） | 次のものを拒否する<br>- terraform apply / destroy / import / state 変更<br>- 読み取り専用の allowlist（describe、list、get、head、lookup、search、filter、batch-get、query、scan、simulate、validate、wait、`s3 ls`）以外の aws CLI<br>- force push、main への push、`--no-verify` と `commit -n`（`git -C` などのグローバルオプションの後も判定する）<br>- ロックファイルや state、エンジンの制御ファイル（`.agent-runs/ACTIVE`、`.stop-gate.json`、`<run>/state.json`）の手編集<br>- read-only step 中の編集（サブエージェントを含む）<br>ハーネス（`settings.local.json` を含む）や CI の編集は ask にする<br>コマンドは、コマンドの位置にあるときだけ判定する。コマンドの位置とは、文字列の先頭、または `;`、`&`、`|`、`(`、改行の後である。その後ろに置けるもの：`VAR=x`、シェルの予約語（then、do、else、elif、if、while、until）、`{`、`!`、前置コマンド（time、env、sudo、nice、xargs、command、exec、timeout）。行の途中で触れるだけの文字列は通す。heredoc の行頭にあるコマンドは拒否する（安全側） |
| 即時フィードバック | `hooks/post-edit.mjs`（PostToolUse） | 確定的 | `terraform fmt`、`bash -n`、JSON の構文検査。失敗すれば exit 2 で即座に返す |
| 終了ゲート | `hooks/stop-gate.mjs`（Stop と、implementer の SubagentStop） | 確定的（回数に上限あり） | 次の 2 つを行う<br>- 検証が通らなければ終了させない（上限はセッションとエージェントごとに数える）<br>- 実行中のワークフローがあれば 1 回止める。その間メインセッションでは検証を実行しない |
| 検証器 | `.claude/scripts/verify.sh` | 確定的 | CI と同じ観点を実行する（fmt、validate、test、tflint、checkov、typecheck、vitest、ハーネスのテスト）。ツールが無いときは PASS ではなく `UNVERIFIED`（exit 3）を返す |
| 実行環境 | `hooks/session-start.sh`（クラウドのみ） | ベストエフォート | terraform 1.16.4、tflint 0.64.0 と aws ruleset、checkov、pnpm install を用意する。レジストリが遮断されていれば provider ミラーを作る |
| 手順 | `workflow.mjs` + `develop.json` + `/develop` | 確定的 | 遷移、予算、ループ監視、報告とラベルの一致、read-only 違反を検出する |
| 回帰防止 | CI の `harness` ジョブ | 確定的 | エンジン、フック、設定の突き合わせ、verify.sh の失敗表示のテスト（node:test 34 件）、シェルスクリプトの構文検査 |

## 5. ループエンジニアリング

すべてのループに「数える場所」と「上限を超えたときの行き先」を決めた。上限を超えたら人に戻す。

```
L0  編集 1 回ごと        Edit/Write ─▶ post-edit（fmt / 構文）──失敗─▶ その場で修正          上限: なし（1 編集で完結）
L1  implementer の終了   SubagentStop ─▶ verify --level fast ──FAIL─▶ 作業に戻す           上限: 3 回 ─▶ 失敗を報告して終了
L2  レビュー ⇄ 修正      reviewers ─any(needs_fix)─▶ fix ─fixed─▶ reviewers                 3 周目から supervisor が judge
                          judge: converging ─▶ 再開 / unproductive ─▶ ASK_HUMAN            上限: 5 周 ─▶ ASK_HUMAN
L2' 最終ゲートの差し戻し  supervise ─reject─▶ fix ─▶ reviewers（L2 と同じカウンタ）
L3  再計画               implement / fix ─need_replan─▶ plan                                上限: 1 回 ─▶ ASK_HUMAN
L4  実行全体             step 数                                                             上限: max_steps 20 ─▶ ABORT
L5  メインセッション      実行中の run を残したまま Stop ─▶ 1 回だけ止めて続行を促す            2 回目は通す（run は ACTIVE のまま再開できる）
                          run が running の間、メインセッションでは verify ゲートを実行しない（検証は L1、tester、supervisor が行う）
```

**収束のための設計**（振動を防ぐ）
- レビュアーは、2 周目以降は前回の指摘の解消確認から始め、変わっていないコードに新しいスタイル指摘をしない（review policy 5）。
- non-blocking の指摘は `needs_fix` にしない。ループに入るのは根拠のある blocking の指摘だけ。
- tester と ai-antipattern-reviewer は verify.sh を自分で実行し直す。implementer の「PASS」を鵜呑みにしない。
- 報告だけが step 間の記憶になる。レビュアーは毎回新しいコンテキストで起動する（C7、T4）。

**停止性**
- 遷移は 1 回ごとに `step_count` が増える。20 を超える非終端の遷移は ABORT になる。
- judge からの再開はループのカウンタを増やさないが、`step_count` は増える。そのため judge を挟んでも全体は有限で終わる。
- Stop ゲートの上限 3 は、Claude Code 組み込みの上限 8（C2）より小さい。

## 6. 使い方

```text
/develop Keep の ALB にアクセスログを追加する        # 計画から最終判定までの一連
/peer-review                                          # 既存の差分を 4 観点で並列レビュー
/verify --scope all                                   # CI と同じ検査を全体に対して実行
node .claude/scripts/workflow.mjs status              # 実行中の run の履歴
```

## 7. 検証結果（本セッション）

§7 は、このハーネス自身を `/develop` で回した結果を記録する（下の「ドッグフーディング」）。

| 検証 | 結果 |
|---|---|
| `verify.sh --scope all --level full`（ハーネスの追加前） | 全ルートとモジュールの init、validate、`terraform test`（20 件）、tflint、checkov が PASS。Lambda の typecheck と vitest（29 件）も PASS |
| ハーネスのテスト（`node --test`） | 34 件 PASS。遷移、並列の all/any、ループ監視、judge、replan、max_steps、read-only 違反、報告とラベルの一致、ガード（read-only step 中のサブエージェントの編集、git のグローバルオプションと短縮・結合フラグ、コマンドの位置（改行、シェルの予約語、`{`、`!`、time/env/sudo）、aws の読み取り専用 allowlist、エンジンの制御ファイル、`settings.local.json`）、Stop ゲート（上限、セッションとエージェントごとのカウンタ、run の実行中はメインセッションで verify しないこと）、verify.sh の FAIL 出力に失敗したテスト名が出ること、`develop.json` とエージェント定義の突き合わせ（ファイルと `name` の一致、read-only のエージェントに編集ツールがないこと）を検証した |
| SessionStart フック（`CLAUDE_CODE_REMOTE=true`） | 約 48 秒で完了。terraform 1.16.4、provider ミラー、tflint 0.64.0 + aws ruleset 0.47.0、pnpm install、checkov が用意できた |
| ドッグフーディング（run `20260927T025424-agent-harness`） | このハーネス自身の仕上げを `/develop` で実行し、**8 step で COMPLETE** になった：plan → implement → reviewers（4 名とも needs_fix）→ fix → reviewers（security のみ needs_fix）→ fix → reviewers（全員 approved）→ supervise（approve）。review-fix のカウンタは 2 で、judge の閾値 3 には達しなかった。各レビューの blocking 指摘は **9 → 1 → 0** と収束し、一度解消した指摘の再発は無かった。作成者（オーケストレータ）自身が見落としていた欠陥を、レビュアーが 10 件見つけて修正した<br>- 読み取り専用のロックがサブエージェントに効いていなかった<br>- git のグローバルオプション（`-C` など）と `commit -n`、改行やシェルの予約語の後ろに置いたコマンドを、ガードが通していた<br>- aws の拒否が動詞リスト方式で漏れていた<br>- `settings.local.json` を確認なしで編集できた<br>- エンジンの制御ファイルを書き換えて、ロックを外せた<br>- メインセッションの Stop ゲートが、実装の途中にオーケストレータを止めていた<br>- verify.sh の出力で、失敗したテストの名前が見えなかった<br>- 設計書が takt とのキー互換性を誤って主張していた<br>実際に動作を観測したもの：L5（run が実行中なら終了を 1 回止める）、L1 の上限（修正前は 3/3 で止め、その後にエスカレーション）、エンジンの報告とラベルの一致の検査、ガードの拒否（implementer が危険な文字列を含む heredoc を書こうとして拒否され、Edit で書き直した）。オーケストレータの逸脱が 1 件ある：報告を run ディレクトリに保存する際、原文ではなく内容を保った日本語の要約として保存した（SKILL の「verbatim」に反する） |

## 8. リスクと未確認事項

| # | 項目 | 影響 | 対応 |
|---|---|---|---|
| H1 | ガードは文字列の一致であり、セキュリティ境界ではない（C1） | `bash -c` などで回避できる | 権限の deny、ガード、レビュー、人による apply の多層で守る。本番の資格情報をエージェント環境に置かない |
| H2 | オーケストレータが `/develop` の手順に従わず、自分で編集する可能性 | step を飛ばされる | 次の 3 つで検出・抑止する<br>- read-only step 中の編集はガードが拒否する<br>- ラベルは保存された報告と一致しないと進まない<br>- 実行中の run を放置して終了すると Stop フックが止める<br>完全には防げないため、supervisor の判定と PR のレビューで補う |
| H3 | サブエージェントの frontmatter の `Stop` フック（implementer の L1）の実動作 | 動かなければ、L1 はレビュアーと supervisor による再実行だけになる | ドキュメント（C3）で仕様は確認済み。今回の run では implementer が常に PASS の状態で終わったため、実動作は**未確認**（§9 の条件 3） |
| H4 | Stop ゲートがターンの終了ごとに fast 検査を実行する | 数秒〜十数秒の遅延 | fast は変更のあった領域だけを検査する（fmt、関連するテスト）。重い検査は full（明示的に実行）に分けた |
| H5 | ローカルの Node が 22、CI と Lambda は 24 | Node 24 固有の挙動の差 | ハーネスは Node 22 の機能だけを使う。CI は 24 で実行する |
| H6 | tflint のバージョンを 0.64.0 に固定したが、CI の setup-tflint は最新を使う | ルールの差 | バージョン更新時に `session-start.sh` の `TFLINT_VERSION` を上げる |
| H7 | takt の各組み込みワークフローのプロンプト本文は未読（構造のみ確認） | 観点の取りこぼし | レビュアーの観点は本リポジトリの規約（§5、§9）から作った。必要なら takt の facet を参照して足す |
| H8 | 新しく追加したエージェントは、（再）読み込みされるまで使えないことがある。ドキュメントは新しい `agents` ディレクトリには再起動が要るとしている（C3）。本セッションでは、セッション中に `.claude/agents/` を作った直後は Agent tool が `subagent_type: "planner"` を「見つからない」として拒否し、数分後には再起動なしで使えるようになった（実測、2026-09-27） | `subagent_type` で起動できない間は、エージェント定義の `tools` の制限が効かない | `/develop` の手順で、general-purpose エージェントに persona ファイルを読ませて代行する（本セッションの plan step はこの方法で実行した）。read-only はガード（サブエージェントにも適用）と指紋検査で担保する。定義とペルソナの対応はテスト（`harness-config.test.mjs`）で固定した |
| H9 | メインセッションの Stop フック（`stop-gate.mjs`）は、run が running の間はターンの終了ごとに 1 回止める（`stop_hook_active` が false のとき）。本セッションでは、run が step `plan` のときにオーケストレータのターン終了を止めた（L5 の動作を確認）。バックグラウンドのエージェントを待っている間のターン終了でも止める（実測、2026-09-27）。run が running の間、メインセッションでは verify ゲートを実行しないため、続く終了（`stop_hook_active` が true）は通す（テストで固定：§7） | 待機中のターン終了ごとに 1 回、不要な block が出る（ノイズ）。停止はしない | 現状は許容する。SKILL ではエージェントをバックグラウンドで動かさず、結果を待つよう指示している。Stop の入力には、実行中のタスクの配列 `background_tasks`（各要素に `id`、`type`、`status` など。`subagent` のタスクには `agent_type`。何も無ければ空）がある（https://code.claude.com/docs/en/hooks の「Stop input」）。これを見て待機中は止めない改善は、まだ入れていない |

## 9. 最終裁定

**裁定: このエージェント環境は「条件付き Go」とする。** 本リポジトリの以後の変更は `/develop`（計画 → 実装 → 並列レビューとテスト → 修正ループ → 最終判定）で進めてよい。

**条件**
1. PR [toasahi/terraform-pd#1](https://github.com/toasahi/terraform-pd/pull/1) は人がレビューしてからマージする。この PR は CI（`harness` ジョブ）、`settings.json`、フックを変更するため、ハーネスの変更を人が承認する原則（ガードの ask）に当たる。
2. 最初のフォローアップとして、次の 2 件を `/develop` で直す。
   - C7/S14：ガードの境界 `\s*` を `[ \t]*` にし、時間を測るテストを加える。改行の多い入力で処理時間が二乗で増え、約 13000 行を超えるとタイムアウトで検査されずに通る恐れがある。
   - C5：エスケープのラベル（`next - abort`）では指紋検査を行わないようにする。docs がロックアウトの解除手段として案内しているのに、実際には exit 4 になるため。
3. H3（implementer の SubagentStop ゲートの実動作）は、今回の run では観測する機会が無かった。次の実タスクで、implementer が verify の失敗を残したまま終わろうとした場面の挙動を確認する。
4. ローカルの開発者は terraform、tflint、checkov、Node を用意する。用意しない場合、verify.sh は `UNVERIFIED` を返す（合格としては扱わない）。
5. 残る non-blocking の指摘（C4、C8、S5〜S9、S11〜S13、A3〜A7、T3〜T6）は、run ディレクトリのレビュー報告にある。優先度を付けて順に消化する。

**なぜこの裁定に至るのか（so that ×3）**

- **so that ①：手順を、プロンプトではなく構造で強制できるため。**
  - takt の「次に何をするかはワークフローが決める」を、エンジン、フック、権限で実装した。
  - ドッグフーディングでは次のものが実際に働いた。
    - 報告とラベルの一致の検査
    - read-only の指紋検査
    - Stop フック（L5）
    - ガードの拒否
  - 作成者自身が見落とした欠陥 10 件を、新しいコンテキストで起動した 4 観点のレビュアーが見つけた。evaluator-optimizer（A1）と、敵対的レビュー（C7）の効果を、このリポジトリで実証できた。
- **so that ②：ループが有限で、しかも収束することを確かめたため。**
  - すべてのループに、数える場所と上限、上限を超えたときの行き先（人）がある（§5）。いずれもテストで固定した。
  - 実際の run では、blocking の指摘が 9 → 1 → 0 と単調に減り、review-fix は 2 周、全体は 20 step 中 8 step で終わった。
  - 振動を防ぐ policy は機能した。再レビューは前回の指摘の確認から始め、変わっていないコードには指摘しない。
- **so that ③：残る不確実性を明示し、小さなコストで閉じられる範囲に収めたため。**
  - ガードは sandbox ではない（H1）。そのため、権限の deny、指紋検査、レビュー、人による apply の多層で補っている。
  - 残る既知の穴（C7/S14、C5、H3）は、それぞれ 1 行の修正か、1 回の観測で閉じられる。
  - 事実は一次情報源で確認し、確認できないものは「未確認」として残した。レビューで見つかった誤り（`consecutive_stop_hooks`、takt とのキー互換性）も、一次情報源で訂正した。
