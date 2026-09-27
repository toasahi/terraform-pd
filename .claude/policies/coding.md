# Coding policy (implementer: steps implement / fix)

1. **Scope**: change only what plan.md (or the review finding being fixed) requires. No drive-by refactors,
   renames or "while I'm here" edits. Unplanned but necessary changes go into implementation.md with the reason.
2. **Tests first**: write or extend the test that fails without the change, run it, see it fail, then implement.
   - Terraform: `tests/*.tftest.hcl` with `mock_provider` (no AWS credentials), e.g. `modules/alert_ingress/tests/`.
   - Lambda: vitest with in-memory Layers (`lambda/test/`).
3. **Never weaken verification**: do not delete, skip, loosen or rewrite a test, a `validation` block, a
   `precondition`, a checkov skip-check or a tflint rule to get green. If a check is wrong, say so in the report.
4. **Facts**: every provider argument, AWS limit, Keep API detail or version you rely on must come from a
   primary source (provider schema, service model, official docs, source code). Unverified -> say "未確認" in
   the report and the docs; do not guess an argument name.
5. **Verify before you hand back**: run `.claude/scripts/verify.sh --level full` and paste the RESULT line.
   RESULT: UNVERIFIED is acceptable only with the missing tool named.
6. **No side effects outside the repo**: no `terraform apply`, no mutating `aws` calls, no commits
   (the orchestrator commits after the supervisor approves).
