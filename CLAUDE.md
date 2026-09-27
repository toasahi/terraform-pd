# terraform-pd

PagerDuty のグローバルオーケストレーターとサービスルーターを、セルフホストの Keep に置き換えるための IaC（フェーズ 1：東京 MVP）。
Terraform（AWS、管理アカウントの ap-northeast-1）と、TypeScript + Effect の Lambda 4 本で構成する。

- なぜ作るか：@docs/why-keep.md
- 設計・前提・未確認事項：`docs/implementation-plan.md`（§5 の規約、§14 の未確認事項は変更前に読む）
- エージェント環境（このファイル、`.claude/`）の設計と裁定：`docs/agent-harness.md`

## 作業の流れ

- 1 行で差分を説明できる変更より大きいものは **`/develop <やること>`** で進める。流れは「計画 → テストを先に書いて実装 → 4 観点の並列レビューとテスト → 修正ループ → supervisor の最終判定」。次の step はエージェントではなく `.claude/workflows/develop.json` が決める。
- 手作業や別セッションで行った変更は `/peer-review` でレビューし、`/verify` で検証する。
- 「終わった」と言う前に、必ず `.claude/scripts/verify.sh` の `RESULT:` 行を示す。`UNVERIFIED` は合格ではない。どのツールが無かったかを添えて報告する。

## コマンド

```bash
.claude/scripts/verify.sh                         # 変更分を CI と同じ観点で検査（--scope all で全体、--level fast で軽量）
pnpm --dir lambda typecheck && pnpm --dir lambda test
terraform -chdir=modules/<name> init -backend=false && terraform -chdir=modules/<name> test   # mock_provider（AWS 資格情報は不要）
node --test '.claude/scripts/test/*.test.mjs'     # ハーネス自体のテスト
```

## 必ず守ること

- `terraform apply` / `destroy` / `import` / `state` の変更系、変更系の `aws` CLI は実行しない。apply はレビュー後に人が行う（PreToolUse ガードで拒否される）。
- テスト、`validation`、`precondition`、checkov の skip、tflint ルールを弱めて通さない。
- `.terraform.lock.hcl` と `pnpm-lock.yaml` は手で編集しない（`terraform init` / `pnpm` に書かせる）。
- 事実（provider の引数、AWS の上限、Keep の API）は一次情報源で確認する。確認できないものは「未確認」と書く。
- ハーネス（`.claude/settings.json`、`.claude/hooks/`、`.claude/workflows/`、`.claude/scripts/`）と CI の変更には、ユーザーの確認が要る（ガードが ask にする）。

## 環境の注意

- クラウドセッションでは SessionStart フック（`.claude/hooks/session-start.sh`）が terraform、tflint、checkov、`lambda/node_modules` を用意する。
- `registry.terraform.io` がネットワークポリシーで遮断されている場合は、ロックファイルのバージョンで releases.hashicorp.com からミラーを作り、`TF_CLI_CONFIG_FILE` で使う。
- ルートモジュールの `init` は `-backend=false` で行う（state バケットには触れない）。
