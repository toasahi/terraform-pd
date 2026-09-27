---
paths:
  - "lambda/**"
---
# Lambda rules (source: docs/implementation-plan.md §4, §7)

- TypeScript + Effect 3.x on Node.js 24 (`nodejs24.x`, arm64); pnpm version from `package.json`
  (`corepack enable`). Never hand-edit `pnpm-lock.yaml`; use `pnpm --dir lambda add|update`.
- Services are `Context.Tag` + `Layer`; tests swap in in-memory Layers (`lambda/test/helpers.ts`).
- Ingest returns **5xx on any internal failure** - Alertmanager retries only 5xx, a wrong 4xx loses the alert.
- FIFO consumers report `batchItemFailures` from the first failure onward (keeps per-group order).
- Journal state only moves forward (conditional `state_rank` update); dedup is the conditional put on
  `transition_id`, not SQS dedup (5-minute window).
- Critical delivery (in-house SQS + SNS) must not depend on Keep; each channel records success separately.
- Verify: `pnpm --dir lambda typecheck && pnpm --dir lambda test` (vitest), or `.claude/scripts/verify.sh`.
