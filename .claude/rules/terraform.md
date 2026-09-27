---
paths:
  - "**/*.tf"
  - "**/*.tftest.hcl"
  - "**/*.tfvars"
  - "**/.terraform.lock.hcl"
---
# Terraform rules (source: docs/implementation-plan.md §5, Google Cloud Terraform best practices)

- Modules (`modules/`) never configure providers; `versions.tf` uses lower bounds only (`>=`). Roots
  (`envs/management/ap-northeast-1/*`) pin `~> 6.66` and commit `.terraform.lock.hcl`; modules do not.
- Naming: snake_case, singular, do not repeat the resource type, `main` for the only instance
  (`aws_lambda_function.main`, `aws_sqs_queue.dead_letter`).
- Variables: `description` and `type` always; units in names (`timeout_seconds`, `memory_size_mb`);
  booleans positive (`enable_*`); no `default` for environment-specific values (account id, zone, digests).
- Outputs come from resource attributes, never pass-through of inputs.
- Stateful resources (Journal, RDS, state bucket) keep `prevent_destroy` and deletion protection.
- Secrets never enter state or plan: write-only `*_wo` arguments + ephemeral `random_password`.
- Cross-root data flows through `terraform_remote_state` in the order foundation -> keep -> alert-pipeline.
- Guard invariants with `validation` / `precondition` and prove them in `tests/*.tftest.hcl` with
  `mock_provider "aws"` (no credentials). A behaviour change without a test change is incomplete.
- Phase-3 invariants must not regress (§13): REST API Regional + WAF, Journal `NEW_AND_OLD_IMAGES`,
  custom domain with execute-api endpoint disabled.
- Verify: `.claude/scripts/verify.sh --level full` (fmt, validate, test, tflint, checkov). Never run
  `terraform apply` / `destroy` / `import` / `state` mutations - a human applies after review.
