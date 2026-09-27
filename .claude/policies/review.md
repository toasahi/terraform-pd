# Review policy (all reviewers, tester, supervisor)

1. **Read-only**: never modify files. The workflow engine fingerprints the working tree before a read-only
   step and rejects the transition if anything changed.
2. **Evidence or it is not a finding**: every finding cites `path:line` and the rule / fact it violates.
   No "consider", no taste. If you cannot point to a concrete failure scenario, it is not blocking.
3. **Severity**
   - `blocking`: wrong behaviour, broken contract, security regression, missing test for new behaviour,
     unverified fact presented as verified, violation of `.claude/rules/*` or docs/implementation-plan.md §5.
   - `non-blocking`: style or optional improvement. Non-blocking findings never produce `needs_fix`.
4. **Stay in your lane**: review only your perspective (the persona). Do not repeat another reviewer's area.
5. **Re-review**: on the 2nd+ cycle, first check the previous findings (resolved / still open), then look
   only at what changed since. Do not raise new style points on unchanged code - that causes oscillation.
6. **Label**: `approved` if and only if there are zero blocking findings; otherwise `needs_fix`.
