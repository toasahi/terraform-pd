---
name: verify
description: Runs this repository's deterministic checks (terraform fmt/validate/test, tflint, checkov, lambda typecheck + vitest, harness tests) on the changed files or the whole repo and reports PASS / FAIL / UNVERIFIED.
argument-hint: "[--scope changed|all] [--level fast|full]"
---
Run `.claude/scripts/verify.sh $ARGUMENTS` from the repository root (defaults: `--scope changed --level full`).

Report the `RESULT:` line and every `FAIL` / `SKIP` line verbatim.
- `FAIL`: show the failing output and the root cause; do not weaken a test or a check to make it pass.
- `UNVERIFIED` (exit 3): name each skipped check and the missing tool. It is not a pass. In cloud sessions
  the SessionStart hook installs the tools; locally see README "必要なツール".
