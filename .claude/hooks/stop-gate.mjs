#!/usr/bin/env node
// Stop / SubagentStop gate: the deterministic end-of-turn check (Anthropic best practices: "a Stop
// hook as a deterministic gate"). Two checks, both bounded so the loop can never spin forever:
//
// 1. Workflow check (main session only; skipped with --gate-only): if a workflow run is active and
//    not finished, block the stop once so reviews / supervise cannot be silently skipped. On the
//    second attempt (stop_hook_active) it lets the turn end - the run stays ACTIVE and is resumable.
//    While the run is running the main session never runs the verify gate (step 2): verification is
//    done inside the run (implementer's SubagentStop gate via --gate-only, tester, supervisor).
// 2. Verify gate: runs .claude/scripts/verify.sh --level fast on the branch's changes.
//      FAIL        -> block with the failing output, at most MAX_BLOCKS times in a row per session and
//                     agent (session_id + agent_id, "main" for the main session);
//                     then allow the stop with a warning so the agent reports the failure (escalation)
//      UNVERIFIED  -> allow, with a warning naming the missing tool (never reported as a pass)
//      PASS        -> allow, reset the counter

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const MAX_BLOCKS = Number(process.env.HARNESS_STOP_GATE_MAX_BLOCKS ?? 3);
const gateOnly = process.argv.includes("--gate-only");

let raw = "";
for await (const chunk of process.stdin) raw += chunk;
const input = JSON.parse(raw || "{}");
const root = process.env.CLAUDE_PROJECT_DIR || input.cwd || process.cwd();
const runsDir = process.env.WORKFLOW_RUNS_DIR ?? path.join(root, ".agent-runs");
const out = (obj) => {
  process.stdout.write(JSON.stringify(obj));
  process.exit(0);
};

// 1. Unfinished workflow run (main session only)
if (!gateOnly) {
  let running = null;
  try {
    const id = fs.readFileSync(path.join(runsDir, "ACTIVE"), "utf8").trim();
    const state = JSON.parse(fs.readFileSync(path.join(runsDir, id, "state.json"), "utf8"));
    if (state.status === "running") running = { id, step: state.step };
  } catch {
    /* no active run */
  }
  if (running) {
    if (!input.stop_hook_active) {
      out({
        decision: "block",
        reason:
          `Workflow run ${running.id} is still at step "${running.step}". Continue it (node .claude/scripts/workflow.mjs current), ` +
          `or end it explicitly with "workflow.mjs next - ask_human" (decision for the user) / "next - abort".`,
      });
    }
    // While a run is running, verification belongs to the run (implementer's SubagentStop gate, tester,
    // supervisor). Gating the orchestrator here would push it to fix code itself, against /develop.
    process.exit(0);
  }
}

// 2. Verify gate. The block budget is per session and per agent (main session vs each subagent).
const counterFile = path.join(runsDir, ".stop-gate.json");
const sessionPrefix = `${input.session_id}|`;
const counterKey = `${sessionPrefix}${input.agent_id ?? "main"}`;
const readCounters = () => {
  try {
    const c = JSON.parse(fs.readFileSync(counterFile, "utf8"));
    return c && typeof c.blocks === "object" && c.blocks !== null ? c.blocks : {};
  } catch {
    return {};
  }
};
const readCounter = () => readCounters()[counterKey] ?? 0;
const writeCounter = (blocks) => {
  // keep only this session's counters so the file does not grow across sessions
  const kept = Object.fromEntries(Object.entries(readCounters()).filter(([k]) => k.startsWith(sessionPrefix)));
  kept[counterKey] = blocks;
  fs.mkdirSync(runsDir, { recursive: true });
  fs.writeFileSync(counterFile, JSON.stringify({ blocks: kept }));
};

const verify = spawnSync(path.join(root, ".claude/scripts/verify.sh"), ["--level", "fast"], { cwd: root, encoding: "utf8", timeout: 280_000 });
const output = `${verify.stdout ?? ""}${verify.stderr ?? ""}`.trim().split("\n").slice(-60).join("\n");

if (verify.status === 0) {
  writeCounter(0);
  process.exit(0);
}
if (verify.status === 3) {
  writeCounter(0);
  out({ systemMessage: `[stop-gate] UNVERIFIED: a check was skipped because a tool is missing.\n${output}` });
}
const blocks = readCounter();
if (blocks >= MAX_BLOCKS) {
  writeCounter(0);
  out({
    systemMessage: `[stop-gate] verify.sh still fails after ${MAX_BLOCKS} attempts; stopping so a human can decide. The work is NOT done.\n${output}`,
  });
}
writeCounter(blocks + 1);
out({ decision: "block", reason: `[stop-gate ${blocks + 1}/${MAX_BLOCKS}] verify.sh --level fast failed. Fix the cause (never weaken or skip a test), then finish.\n${output}` });
