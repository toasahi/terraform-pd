#!/usr/bin/env node
// Workflow engine for the agent harness (takt's idea: "agents do the work, the workflow decides
// what happens next"). The orchestrating agent never chooses the next step itself: it reports the
// label a step ended with, and this script picks the transition from .claude/workflows/<name>.json,
// enforces the step budget and loop monitors, and checks that read-only steps left the tree alone.
//
// Usage:
//   workflow.mjs start <slug> [--workflow develop]   start a run, print the first step
//   workflow.mjs current [<run>]                     print the current step
//   workflow.mjs next <run|-> <label>                finish a normal step with <label>
//   workflow.mjs next <run|-> <agent>=<label> ...    finish a parallel step (one label per agent)
//   workflow.mjs status [<run>]                      print the run history
//   (<run> is a run directory or id; "-" or omitted means the active run)
//
// Exit codes: 0 ok, 2 usage / invalid label, 4 read-only violation, 5 no active run.
// State lives in <repo>/.agent-runs/<run-id>/state.json (git-ignored); WORKFLOW_RUNS_DIR overrides.

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const TERMINALS = new Set(["COMPLETE", "ABORT", "ASK_HUMAN"]);

export class WorkflowError extends Error {
  constructor(message, exitCode = 2) {
    super(message);
    this.exitCode = exitCode;
  }
}

const HARNESS_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

export function repoRoot(cwd = process.cwd()) {
  return execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd, encoding: "utf8" }).trim();
}

export function runsDir(root) {
  return process.env.WORKFLOW_RUNS_DIR ?? path.join(root, ".agent-runs");
}

export function loadWorkflow(name, dir = path.join(HARNESS_DIR, "workflows")) {
  const file = path.join(dir, `${name}.json`);
  const def = JSON.parse(fs.readFileSync(file, "utf8"));
  validateWorkflow(def);
  return def;
}

export function validateWorkflow(def) {
  const known = new Set([...Object.keys(def.steps), ...TERMINALS]);
  const check = (next, where) => {
    if (next !== "$resume" && !known.has(next)) throw new Error(`${where}: unknown next "${next}"`);
  };
  if (!Number.isInteger(def.max_steps) || def.max_steps < 1) throw new Error("max_steps must be a positive integer");
  if (!def.steps[def.initial_step]) throw new Error(`initial_step "${def.initial_step}" is not a step`);
  for (const [name, step] of Object.entries(def.steps)) {
    if (!step.agent && !step.parallel) throw new Error(`step ${name}: needs agent or parallel`);
    if (step.parallel && !step.labels?.length) throw new Error(`step ${name}: parallel steps need labels`);
    for (const rule of step.rules ?? []) check(rule.next, `step ${name}`);
  }
  for (const rule of def.all_steps?.rules ?? []) check(rule.next, "all_steps");
  for (const m of def.loop_monitors ?? []) {
    for (const s of m.cycle) if (!def.steps[s]) throw new Error(`monitor ${m.name}: unknown step "${s}"`);
    if (m.on_max) check(m.on_max, `monitor ${m.name}`);
    for (const rule of m.judge?.rules ?? []) check(rule.next, `monitor ${m.name} judge`);
    if (m.judge && !Number.isInteger(m.threshold)) throw new Error(`monitor ${m.name}: judge needs threshold`);
  }
}

// Fingerprint of the working tree (tracked changes + untracked file contents). Ignored paths such as
// .agent-runs/ are excluded, so reports written by the orchestrator do not count as edits.
export function treeFingerprint(root) {
  const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "buffer", maxBuffer: 256 * 1024 * 1024 });
  const hash = createHash("sha256");
  hash.update(git("status", "--porcelain=v1", "-uall"));
  try {
    hash.update(git("diff", "HEAD", "--binary"));
  } catch {
    hash.update(git("diff", "--binary"));
  }
  const untracked = git("ls-files", "--others", "--exclude-standard", "-z").toString().split("\0").filter(Boolean);
  for (const f of untracked.sort()) {
    hash.update(f);
    try {
      hash.update(fs.readFileSync(path.join(root, f)));
    } catch {
      /* removed while hashing */
    }
  }
  return hash.digest("hex");
}

export function resolveStep(def, state) {
  if (state.step.startsWith("judge:")) {
    const monitor = def.loop_monitors.find((m) => `judge:${m.name}` === state.step);
    const count = state.monitors[monitor.name];
    return {
      name: state.step,
      agent: monitor.judge.agent,
      edit: false,
      report: `judge-${monitor.name}.md`,
      instruction: monitor.judge.instruction.replaceAll("{cycle_count}", String(count)),
      rules: monitor.judge.rules,
    };
  }
  return { name: state.step, ...def.steps[state.step] };
}

function allowedLabels(def, step) {
  const own = step.parallel ? step.labels : (step.rules ?? []).map((r) => r.when);
  return { own, global: (def.all_steps?.rules ?? []).map((r) => r.when) };
}

// Pure transition function: returns { target, reason } without touching disk.
export function decide(def, state, args) {
  const step = resolveStep(def, state);
  const { own, global } = allowedLabels(def, step);
  if (args.length === 1 && !args[0].includes("=") && global.includes(args[0])) {
    const rule = def.all_steps.rules.find((r) => r.when === args[0]);
    return { target: rule.next, labels: { [step.name]: args[0] } };
  }
  let rule;
  let labels;
  if (step.parallel) {
    labels = Object.fromEntries(args.map((a) => a.split("=")));
    const missing = step.parallel.filter((a) => !(a in labels));
    const extra = Object.keys(labels).filter((a) => !step.parallel.includes(a));
    const bad = Object.entries(labels).filter(([, v]) => !own.includes(v));
    if (missing.length || extra.length || bad.length) {
      throw new WorkflowError(
        `step ${step.name} needs one label per agent: ${step.parallel.map((a) => `${a}=<${own.join("|")}>`).join(" ")}` +
          (missing.length ? `; missing ${missing.join(", ")}` : "") +
          (extra.length ? `; unknown ${extra.join(", ")}` : "") +
          (bad.length ? `; invalid ${bad.map(([k, v]) => `${k}=${v}`).join(", ")}` : ""),
      );
    }
    const values = Object.values(labels);
    rule = step.rules.find((r) => (r.all ? values.every((v) => v === r.all) : r.any ? values.includes(r.any) : false));
  } else {
    if (args.length !== 1) throw new WorkflowError(`step ${step.name} takes exactly one label: ${[...own, ...global].join(" | ")}`);
    labels = { [step.agent]: args[0] };
    rule = step.rules.find((r) => r.when === args[0]);
  }
  if (!rule) throw new WorkflowError(`rule_no_match: step ${step.name} accepts ${[...own, ...global].join(" | ")}`);
  let target = rule.next;
  if (target === "$resume") target = state.judge.resume;
  return { target, labels, fromJudge: step.name.startsWith("judge:") };
}

// The label must come from the agent's saved report, not from the orchestrator: each report named by
// the step (one <agent>.md per agent for parallel steps) must exist in visitDir and end its contract
// with "LABEL: <label>". Global escape labels (ask_human / abort) need no report.
export function checkReports(def, state, args, visitDir) {
  const step = resolveStep(def, state);
  const { global } = allowedLabels(def, step);
  if (args.length === 1 && global.includes(args[0])) return;
  const expected = step.parallel
    ? args.map((a) => a.split("=")).map(([agent, label]) => [`${agent}.md`, label])
    : [[step.report ?? `${step.agent}.md`, args[0]]];
  for (const [file, label] of expected) {
    const full = path.join(visitDir, file);
    if (!fs.existsSync(full)) throw new WorkflowError(`missing report ${full}: save the agent's report before calling next`);
    const labels = [...fs.readFileSync(full, "utf8").matchAll(/^LABEL:\s*([a-z_]+)\s*$/gm)].map((m) => m[1]);
    if (labels.at(-1) !== label) {
      throw new WorkflowError(`report ${file} ends with LABEL: ${labels.at(-1) ?? "<none>"}, not "${label}"`);
    }
  }
}

// Applies budgets and loop monitors on top of decide(). Mutates and returns state.
export function advance(def, state, args, fingerprint) {
  if (TERMINALS.has(state.step)) throw new WorkflowError(`run already finished: ${state.step}`);
  const step = resolveStep(def, state);
  if (step.edit === false && state.snapshot && fingerprint !== undefined && fingerprint !== state.snapshot) {
    throw new WorkflowError(
      `VIOLATION: read-only step "${step.name}" changed the working tree. Revert those changes (git diff), then re-run the step.`,
      4,
    );
  }
  const { target: decided, labels, fromJudge } = decide(def, state, args);
  let target = decided;
  let reason = null;
  state.step_count += 1;

  if (!fromJudge && !TERMINALS.has(target)) {
    for (const m of def.loop_monitors ?? []) {
      if (target !== m.cycle[0] || !m.cycle.includes(state.step) || state.step === target) continue;
      state.monitors[m.name] = (state.monitors[m.name] ?? 0) + 1;
      const count = state.monitors[m.name];
      if (m.max !== undefined && count > m.max) {
        target = m.on_max ?? "ABORT";
        reason = `loop monitor ${m.name}: ${count} cycles > max ${m.max}`;
      } else if (m.judge && count >= m.threshold) {
        state.judge = { monitor: m.name, resume: target };
        target = `judge:${m.name}`;
        reason = `loop monitor ${m.name}: cycle ${count} >= threshold ${m.threshold}, judging progress`;
      }
      break;
    }
  }
  if (!TERMINALS.has(target) && state.step_count >= def.max_steps) {
    reason = `max_steps ${def.max_steps} reached`;
    target = "ABORT";
  }
  if (fromJudge) state.judge = null;

  state.history.push({ n: state.step_count, step: state.step, labels, next: target, reason, at: new Date().toISOString() });
  state.step = target;
  if (TERMINALS.has(target)) state.status = target;
  return state;
}

// --- persistence / CLI ----------------------------------------------------------------------------

function statePath(runDir) {
  return path.join(runDir, "state.json");
}

function readState(runDir) {
  return JSON.parse(fs.readFileSync(statePath(runDir), "utf8"));
}

function writeState(runDir, state) {
  fs.writeFileSync(statePath(runDir), `${JSON.stringify(state, null, 2)}\n`);
}

export function activeRun(root) {
  const file = path.join(runsDir(root), "ACTIVE");
  if (!fs.existsSync(file)) return null;
  const runDir = path.join(runsDir(root), fs.readFileSync(file, "utf8").trim());
  return fs.existsSync(statePath(runDir)) ? runDir : null;
}

function resolveRun(root, arg) {
  if (!arg || arg === "-") {
    const run = activeRun(root);
    if (!run) throw new WorkflowError("no active workflow run (start one with: workflow.mjs start <slug>)", 5);
    return run;
  }
  const candidates = [arg, path.join(runsDir(root), arg)];
  const found = candidates.find((c) => fs.existsSync(statePath(c)));
  if (!found) throw new WorkflowError(`run not found: ${arg}`, 5);
  return path.resolve(found);
}

function enterStep(root, runDir, def, state) {
  if (TERMINALS.has(state.step)) {
    state.snapshot = null;
    state.visit_dir = null;
    const active = path.join(runsDir(root), "ACTIVE");
    if (fs.existsSync(active) && fs.readFileSync(active, "utf8").trim() === path.basename(runDir)) fs.rmSync(active);
    return;
  }
  const step = resolveStep(def, state);
  state.visit_dir = path.join(runDir, `${String(state.step_count + 1).padStart(2, "0")}-${state.step.replace(":", "-")}`);
  fs.mkdirSync(state.visit_dir, { recursive: true });
  state.snapshot = step.edit === false ? treeFingerprint(root) : null;
}

function describe(root, runDir, def, state) {
  const rel = (p) => path.relative(root, p) || ".";
  const lines = [`RUN ${rel(runDir)}  (workflow ${def.name})`];
  const last = state.history.at(-1);
  if (last?.reason) lines.push(`NOTE ${last.reason}`);
  if (TERMINALS.has(state.step)) {
    lines.push(`END ${state.step} after ${state.step_count} steps`);
    if (state.step === "ASK_HUMAN") lines.push("ACTION stop and ask the user; summarize the reports in the run directory.");
    return lines.join("\n");
  }
  const step = resolveStep(def, state);
  const { own, global } = allowedLabels(def, step);
  lines.push(`STEP ${state.step_count + 1}/${def.max_steps} ${step.name} (${step.edit === false ? "read-only" : "edit"})`);
  lines.push(step.parallel ? `AGENTS ${step.parallel.join(", ")} (launch in parallel, one message)` : `AGENT ${step.agent}`);
  lines.push(`REPORT_DIR ${rel(state.visit_dir)}${step.report ? `  (write ${step.report})` : "  (one <agent>.md per reviewer)"}`);
  lines.push(`INSTRUCTION ${step.instruction}`);
  const script = rel(path.join(HARNESS_DIR, "scripts", "workflow.mjs"));
  const usage = step.parallel ? step.parallel.map((a) => `${a}=<${own.join("|")}>`).join(" ") : `<${own.join("|")}>`;
  lines.push(`THEN node ${script} next - ${usage}   (or: ${global.join(" | ")})`);
  return lines.join("\n");
}

function main(argv) {
  const root = repoRoot();
  const [cmd, ...rest] = argv;
  switch (cmd) {
    case "start": {
      const wfIdx = rest.indexOf("--workflow");
      const wfName = wfIdx >= 0 ? rest[wfIdx + 1] : "develop";
      const slug = wfIdx < 0 ? rest[0] : rest.filter((_, i) => i !== wfIdx && i !== wfIdx + 1)[0];
      if (!slug || !/^[a-z0-9][a-z0-9-]{0,40}$/.test(slug)) throw new WorkflowError("usage: start <slug> (lowercase, digits, hyphens)");
      const current = activeRun(root);
      if (current) throw new WorkflowError(`a run is already active: ${path.basename(current)} (finish it, or: next - abort)`);
      const def = loadWorkflow(wfName);
      const id = `${new Date().toISOString().replace(/[-:]/g, "").replace(/\..*/, "")}-${slug}`;
      const runDir = path.join(runsDir(root), id);
      fs.mkdirSync(runDir, { recursive: true });
      const state = { workflow: wfName, run_id: id, created_at: new Date().toISOString(), step: def.initial_step, status: "running", step_count: 0, monitors: {}, judge: null, history: [] };
      enterStep(root, runDir, def, state);
      writeState(runDir, state);
      fs.writeFileSync(path.join(runsDir(root), "ACTIVE"), `${id}\n`);
      return describe(root, runDir, def, state);
    }
    case "current":
    case "next": {
      const runDir = resolveRun(root, rest[0]);
      const state = readState(runDir);
      const def = loadWorkflow(state.workflow);
      if (cmd === "next") {
        if (rest.length < 2) throw new WorkflowError("usage: next <run|-> <label> | <agent>=<label> ...");
        const step = resolveStep(def, state);
        decide(def, state, rest.slice(1)); // validate labels before looking for reports
        checkReports(def, state, rest.slice(1), state.visit_dir);
        advance(def, state, rest.slice(1), step.edit === false && state.snapshot ? treeFingerprint(root) : undefined);
        enterStep(root, runDir, def, state);
        writeState(runDir, state);
      }
      return describe(root, runDir, def, state);
    }
    case "status": {
      const runDir = resolveRun(root, rest[0]);
      const state = readState(runDir);
      const rows = state.history.map((h) => `${String(h.n).padStart(2)} ${h.step} ${JSON.stringify(h.labels)} -> ${h.next}${h.reason ? `  [${h.reason}]` : ""}`);
      return [`RUN ${state.run_id} status=${state.status} step=${state.step} monitors=${JSON.stringify(state.monitors)}`, ...rows].join("\n");
    }
    default:
      throw new WorkflowError("usage: workflow.mjs start|current|next|status (see header)");
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    console.log(main(process.argv.slice(2)));
  } catch (err) {
    console.error(err.message);
    process.exit(err instanceof WorkflowError ? err.exitCode : 1);
  }
}
