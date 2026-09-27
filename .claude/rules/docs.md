---
paths:
  - "docs/**"
  - "README.md"
---
# Documentation rules

- Japanese, plain style matching the existing docs (だ・である調 in design docs, です・ます調 in README).
- Every technical fact cites its primary source (official docs, provider schema, service model, upstream
  source code). Anything not checked is marked **未確認** with how it will be checked - never guessed.
- Decisions are written as a verdict with **so that** reasons (see docs/implementation-plan.md §15).
- Keep README's document list in sync when adding a file under docs/.
