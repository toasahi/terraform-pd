---
name: peer-review
description: Runs the four read-only reviewers (code, security, AI-antipattern, tester) in parallel on the current branch diff outside a workflow run, and summarises blocking findings. Use to review a change made by hand or by another session.
argument-hint: "[focus or base ref]"
---
Review the current branch against its merge-base with `origin/main` (or the ref in: $ARGUMENTS).

1. Launch `code-reviewer`, `security-reviewer`, `ai-antipattern-reviewer` and `tester` with the Agent tool
   in **one message** (parallel). Give each the diff command
   (`git diff $(git merge-base HEAD origin/main)` + `git status --short`) and any focus from the arguments.
   There is no plan.md: tell them to infer requirements from the commit messages and docs they touch.
2. Do not edit anything. Merge the four reports into one table: id, severity, path:line, finding.
3. Verdict: `approved` only if no reviewer reported a blocking finding; otherwise list what must change.
   To fix the findings with the full loop, run `/develop fix review findings: <ids>`.
