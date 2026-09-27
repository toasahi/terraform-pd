---
name: develop
description: Runs the plan -> implement -> review/test -> fix -> supervise workflow for a change to this repository (Terraform modules/roots, Lambda code, docs). Use for any change larger than a one-line fix.
argument-hint: <what to change>
---
# /develop - workflow orchestrator

You are the **orchestrator**. You do not plan, implement, review or judge yourself: you launch the agent
the workflow names, save its report, and hand its LABEL to the workflow engine, which decides the next
step. (takt: "agents do the work, the workflow decides what happens next".)

Task: $ARGUMENTS

Definition: `.claude/workflows/develop.json` (steps, rules, `max_steps`, loop monitors).
Engine: `node .claude/scripts/workflow.mjs` (state in `.agent-runs/<run>/state.json`, git-ignored).

## Procedure

1. `node .claude/scripts/workflow.mjs start <short-slug>` - prints the first step. If a run is already
   active, resume it with `workflow.mjs current` instead (or end it with `next - abort` if it is stale).
2. Loop until the engine prints `END`:
   1. Read the printed `STEP`, `AGENT(S)`, `REPORT_DIR`, `INSTRUCTION`.
   2. Launch the agent with the Agent tool (`subagent_type` = the agent name). Give it: the task above,
      the step instruction, the run directory, and the paths of the reports it needs (plan.md, latest
      implementation/fix report, latest review reports). For `AGENTS ... (launch in parallel)`, launch all of
      them in **one message** so they run concurrently. Wait for their results (do not run them in the background).
      If the Agent tool rejects the `subagent_type` (agent not found), launch a `general-purpose` agent
      instead and make its first instruction "read `.claude/agents/<agent>.md` and act as that persona,
      including its output contract". Newly added agents may not be available until they are (re)loaded:
      the docs say to restart for a new agents directory, but agents can also appear after a delay without
      one - retry the named `subagent_type` at the next step. In this fallback the persona's `tools`
      allowlist does **not** apply (general-purpose has edit tools), so read-only steps rely on the guard
      hook (it denies edits outside `.agent-runs/` during read-only steps, for subagents too) and on the
      engine's fingerprint check (exit 4).
   3. Save each returned report verbatim to `REPORT_DIR` (`<agent>.md` for parallel steps, otherwise the
      named report file). Reports are the only memory between steps - agents do not share context.
   4. Take the `LABEL:` line from each report and run the printed `THEN` command, e.g.
      `node .claude/scripts/workflow.mjs next - planned` or
      `node .claude/scripts/workflow.mjs next - code-reviewer=approved security-reviewer=needs_fix ...`.
      Never pick a label the agent did not return. If a report has no valid label, re-launch that agent once
      asking for the output contract; if it fails again use `ask_human`.
   5. If the engine exits 4 (`VIOLATION`: a read-only step changed files), show the diff, revert those
      changes, and re-run the step. Exit 2 means the label was invalid - fix the call, do not guess.
3. On `END COMPLETE`: commit with a message that summarises plan.md and the verdict (no `--no-verify`), push
   the designated branch if the session requires it, and report to the user.
   On `END ASK_HUMAN` / `END ABORT`: do not commit. Summarise why (the engine's NOTE, the last reports) and
   what decision you need from the user.

## Rules for the orchestrator

- Never edit code yourself during a run; only the implementer does (the guard hook denies edits during
  read-only steps).
- Never skip a step or reorder steps; never re-run reviewers "until they approve" outside the engine.
- The Stop hook blocks ending a turn once while a run is active - either continue, or end the run
  explicitly with `ask_human` / `abort`.
- Final message to the user: run id, step history (`workflow.mjs status`), the verdict, verify.sh RESULT,
  and anything UNVERIFIED.
