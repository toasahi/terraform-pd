import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { advance, checkReports, loadWorkflow, validateWorkflow, WorkflowError } from "../workflow.mjs";

const SCRIPT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../workflow.mjs");
const def = loadWorkflow("develop");
const fresh = () => ({ step: def.initial_step, status: "running", step_count: 0, monitors: {}, judge: null, history: [] });
const allApproved = ["code-reviewer=approved", "security-reviewer=approved", "ai-antipattern-reviewer=approved", "tester=approved"];
const oneNeedsFix = ["code-reviewer=approved", "security-reviewer=needs_fix", "ai-antipattern-reviewer=approved", "tester=approved"];

test("the shipped workflow definition is valid", () => {
  assert.doesNotThrow(() => validateWorkflow(def));
});

test("happy path: plan -> implement -> reviewers -> supervise -> COMPLETE", () => {
  const s = fresh();
  advance(def, s, ["planned"]);
  assert.equal(s.step, "implement");
  advance(def, s, ["implemented"]);
  assert.equal(s.step, "reviewers");
  advance(def, s, allApproved);
  assert.equal(s.step, "supervise");
  advance(def, s, ["approve"]);
  assert.equal(s.step, "COMPLETE");
  assert.equal(s.status, "COMPLETE");
  assert.throws(() => advance(def, s, ["approve"]), /already finished/);
});

test("any needs_fix routes to fix; parallel steps need every reviewer's label", () => {
  const s = { ...fresh(), step: "reviewers" };
  assert.throws(() => advance(def, s, ["code-reviewer=approved"]), /missing security-reviewer/);
  assert.throws(() => advance(def, s, [...allApproved.slice(0, 3), "tester=maybe"]), /invalid tester=maybe/);
  advance(def, s, oneNeedsFix);
  assert.equal(s.step, "fix");
});

test("unknown labels are rejected (rule_no_match) without consuming a step", () => {
  const s = fresh();
  assert.throws(() => advance(def, s, ["done"]), (e) => e instanceof WorkflowError && /rule_no_match/.test(e.message));
  assert.equal(s.step_count, 0);
  assert.equal(s.step, "plan");
});

test("global rules (ask_human / abort) are accepted on every step", () => {
  const s = { ...fresh(), step: "reviewers" };
  advance(def, s, ["ask_human"]);
  assert.equal(s.step, "ASK_HUMAN");
});

test("review-fix loop monitor hands over to the judge at the threshold, then caps at max", () => {
  const s = { ...fresh(), step: "reviewers" };
  const cycle = () => {
    advance(def, s, oneNeedsFix); // reviewers -> fix
    advance(def, s, ["fixed"]); // fix -> reviewers (counted)
  };
  cycle();
  cycle();
  assert.equal(s.step, "reviewers");
  assert.equal(s.monitors["review-fix"], 2);
  cycle();
  assert.equal(s.step, "judge:review-fix");
  advance(def, s, ["converging"]);
  assert.equal(s.step, "reviewers", "judge resumes the interrupted transition");
  cycle();
  advance(def, s, ["converging"]);
  cycle();
  advance(def, s, ["converging"]);
  cycle(); // 6th cycle > max 5
  assert.equal(s.step, "ASK_HUMAN");
  assert.match(s.history.at(-1).reason, /max 5/);
});

test("judge can stop an unproductive loop", () => {
  const s = { ...fresh(), step: "reviewers", monitors: { "review-fix": 2 } };
  advance(def, s, oneNeedsFix);
  advance(def, s, ["fixed"]);
  assert.equal(s.step, "judge:review-fix");
  advance(def, s, ["unproductive"]);
  assert.equal(s.step, "ASK_HUMAN");
});

test("replan is allowed once, the second replan escalates", () => {
  const s = fresh();
  advance(def, s, ["planned"]);
  advance(def, s, ["need_replan"]);
  assert.equal(s.step, "plan");
  advance(def, s, ["planned"]);
  advance(def, s, ["need_replan"]);
  assert.equal(s.step, "ASK_HUMAN");
});

test("max_steps aborts the run", () => {
  const small = { ...def, max_steps: 3, loop_monitors: [] };
  const s = { ...fresh(), step: "reviewers" };
  advance(small, s, oneNeedsFix);
  advance(small, s, ["fixed"]);
  advance(small, s, oneNeedsFix);
  assert.equal(s.step, "ABORT");
  assert.match(s.history.at(-1).reason, /max_steps/);
});

test("read-only steps must leave the working tree unchanged", () => {
  const s = { ...fresh(), step: "reviewers", snapshot: "before" };
  assert.throws(() => advance(def, s, allApproved, "after"), (e) => e.exitCode === 4 && /VIOLATION/.test(e.message));
  advance(def, s, allApproved, "before");
  assert.equal(s.step, "supervise");
});

test("checkReports: every parallel reviewer needs its own report with the matching label", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rep-"));
  const s = { ...fresh(), step: "reviewers" };
  for (const a of allApproved) fs.writeFileSync(path.join(dir, `${a.split("=")[0]}.md`), "# r\nLABEL: approved\n");
  assert.doesNotThrow(() => checkReports(def, s, allApproved, dir));
  assert.throws(() => checkReports(def, s, oneNeedsFix, dir), /security-reviewer\.md ends with LABEL: approved, not "needs_fix"/);
  fs.rmSync(path.join(dir, "tester.md"));
  assert.throws(() => checkReports(def, s, allApproved, dir), /missing report/);
  assert.doesNotThrow(() => checkReports(def, s, ["ask_human"], dir), "escape labels need no report");
});

test("validateWorkflow rejects dangling transitions", () => {
  const broken = structuredClone(def);
  broken.steps.plan.rules[0].next = "nowhere";
  assert.throws(() => validateWorkflow(broken), /unknown next "nowhere"/);
});

test("CLI: start / next / read-only violation / terminal clears ACTIVE", () => {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "wf-"));
  const git = (...a) => execFileSync("git", a, { cwd: repo });
  git("init", "-q");
  git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init");
  fs.writeFileSync(path.join(repo, ".gitignore"), ".agent-runs/\n");
  const env = { ...process.env };
  delete env.WORKFLOW_RUNS_DIR;
  const run = (...a) => spawnSync("node", [SCRIPT, ...a], { cwd: repo, encoding: "utf8", env });

  let r = run("start", "demo-task");
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /STEP 1\/20 plan \(read-only\)/);
  assert.equal(run("start", "second").status, 2, "only one active run");

  const planDir = path.join(repo, ".agent-runs", fs.readFileSync(path.join(repo, ".agent-runs", "ACTIVE"), "utf8").trim(), "01-plan");
  r = run("next", "-", "planned");
  assert.equal(r.status, 2, "a label without a saved report is rejected");
  assert.match(r.stderr, /missing report/);

  fs.writeFileSync(path.join(planDir, "plan.md"), "# Plan\nLABEL: ask_human\n");
  r = run("next", "-", "planned");
  assert.equal(r.status, 2, "the label must match the report");
  assert.match(r.stderr, /not "planned"/);

  fs.writeFileSync(path.join(planDir, "plan.md"), "# Plan\nLABEL: planned\n");
  fs.writeFileSync(path.join(repo, "edited.txt"), "planner must not write code");
  r = run("next", "-", "planned");
  assert.equal(r.status, 4);
  assert.match(r.stderr, /VIOLATION/);

  fs.rmSync(path.join(repo, "edited.txt"));
  r = run("next", "-", "planned");
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /STEP 2\/20 implement \(edit\)/);

  fs.writeFileSync(path.join(repo, "code.txt"), "implementer may edit");
  r = run("next", "-", "abort");
  assert.match(r.stdout, /END ABORT/);
  assert.equal(fs.existsSync(path.join(repo, ".agent-runs", "ACTIVE")), false);
  assert.equal(run("current").status, 5);
});
