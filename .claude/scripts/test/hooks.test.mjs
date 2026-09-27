import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { evaluate } from "../../hooks/guard.mjs";

const HOOKS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../hooks");
const root = "/repo";
const bash = (command) => evaluate({ tool_name: "Bash", tool_input: { command } }, { root })?.decision ?? "allow";
const edit = (file, readOnly = false) =>
  evaluate({ tool_name: "Edit", tool_input: { file_path: path.join(root, file) } }, { root, activeStepIsReadOnly: () => readOnly })?.decision ?? "allow";

test("guard: terraform mutations are denied, read-only terraform is allowed", () => {
  assert.equal(bash("terraform apply"), "deny");
  assert.equal(bash("terraform -chdir=envs/management/ap-northeast-1/keep apply -auto-approve"), "deny");
  assert.equal(bash("cd x && terraform destroy"), "deny");
  assert.equal(bash("TF_LOG=debug timeout 60 terraform state rm aws_s3_bucket.main"), "deny");
  assert.equal(bash("terraform import aws_s3_bucket.main b"), "deny");
  assert.equal(bash("terraform plan -out=apply.tfplan"), "allow");
  assert.equal(bash("terraform -chdir=modules/network test"), "allow");
  assert.equal(bash("terraform fmt -check -recursive"), "allow");
  assert.equal(bash("terraform init -upgrade"), "ask");
});

test("guard: text that merely mentions a command is not blocked", () => {
  assert.equal(bash('git commit -m "Document that terraform apply is run by humans"'), "allow");
  assert.equal(bash("grep -rn 'terraform destroy' docs"), "allow");
});

test("guard: aws CLI is read-only", () => {
  assert.equal(bash("aws secretsmanager put-secret-value --secret-id x --secret-string y"), "deny");
  assert.equal(bash("aws --region ap-northeast-1 lambda invoke --function-name f out.json"), "deny");
  assert.equal(bash("aws s3 rm s3://bucket/key"), "deny");
  assert.equal(bash("aws sts get-caller-identity"), "allow");
  assert.equal(bash("aws --region ap-northeast-1 ecs describe-services --cluster keep"), "allow");
  assert.equal(bash("aws s3 ls"), "allow");
});

test("guard: git safety", () => {
  assert.equal(bash("git push --force origin claude/x"), "deny");
  assert.equal(bash("git push -f"), "deny");
  assert.equal(bash("git push origin main"), "deny");
  assert.equal(bash("git push -u origin HEAD:main"), "deny");
  assert.equal(bash("git push -u origin claude/cool-davinci-mnw4j6"), "allow");
  assert.equal(bash("git push -u origin claude/main-fix"), "allow");
  assert.equal(bash("git commit --no-verify -m x"), "deny");
  assert.equal(bash("git reset --hard HEAD~1"), "ask");
  assert.equal(bash("rm -rf /"), "deny");
  assert.equal(bash("rm -rf lambda/dist"), "allow");
});

test("guard: git rules see through global options (-C, -c, --git-dir) and short / combined flags", () => {
  // S1: global options before the subcommand
  assert.equal(bash("git -C /repo push --force origin claude/x"), "deny");
  assert.equal(bash("git -C ../other push origin main"), "deny");
  assert.equal(bash("git -c user.name=x commit --no-verify -m x"), "deny");
  assert.equal(bash("git --git-dir=/repo/.git push -f"), "deny");
  assert.equal(bash("git --no-pager -C /repo push -u origin HEAD:main"), "deny");
  assert.equal(bash('git -c "user.name=A B" -C /repo push --force'), "deny");
  assert.equal(bash("git -C /repo reset --hard HEAD~1"), "ask");
  // S1: short --no-verify for commit, force in combined short flags for push
  assert.equal(bash("git commit -n -m x"), "deny");
  assert.equal(bash("git commit -an -m x"), "deny");
  assert.equal(bash("git -C /repo commit -n -m x"), "deny");
  assert.equal(bash("git push -fu origin claude/x"), "deny");
  assert.equal(bash("git push -uf origin claude/x"), "deny");
  // still allowed
  assert.equal(bash("git -C /repo push -u origin claude/x"), "allow");
  assert.equal(bash("git -C /repo status"), "allow");
  assert.equal(bash("git push -n origin claude/x"), "allow"); // push -n is --dry-run
  assert.equal(bash("git commit --amend --no-edit"), "allow");
  assert.equal(bash("git commit -uno -m x"), "allow"); // -u<mode> takes an attached value
  assert.equal(bash("git commit -am x"), "allow");
  assert.equal(bash("git commit -mnote"), "allow"); // -m with an attached value
  assert.equal(bash("git commit -m x -m 'run terraform init -input=false -internal'"), "allow");
  assert.equal(bash("git commit -anm x"), "deny");
  assert.equal(bash('git commit -m "Document that git push --force is denied"'), "allow");
});

test("guard: command position includes newlines, shell keywords, { !, and time / env / sudo prefixes", () => {
  // S10: every deny / ask rule (terraform, aws, git, rm) sees these forms
  assert.equal(bash("cd infra\nterraform apply -auto-approve"), "deny");
  assert.equal(bash("cd x\nterraform -chdir=y destroy"), "deny");
  assert.equal(bash("cd x\naws iam delete-role --role-name r"), "deny");
  assert.equal(bash("git status\ngit -C . push --force origin feat"), "deny");
  assert.equal(bash("for r in a b; do aws iam delete-role --role-name $r; done"), "deny");
  assert.equal(bash("for r in a b\ndo\n  aws iam delete-role --role-name $r\ndone"), "deny");
  assert.equal(bash("if true; then git push --force; fi"), "deny");
  assert.equal(bash("if true; then :; else terraform apply; fi"), "deny");
  assert.equal(bash("if false; then :; elif true; then git push -f origin feat; fi"), "deny");
  assert.equal(bash("if aws iam delete-role --role-name r; then :; fi"), "deny");
  assert.equal(bash("while git push --force; do :; done"), "deny");
  assert.equal(bash("{ aws s3 rm s3://b/k; }"), "deny");
  assert.equal(bash("! git push --force"), "deny");
  assert.equal(bash("time aws iam delete-role --role-name r"), "deny");
  assert.equal(bash("env AWS_PROFILE=p aws iam delete-role --role-name r"), "deny");
  assert.equal(bash("sudo aws s3 rm s3://b/k"), "deny");
  assert.equal(bash("sudo -E terraform apply"), "deny");
  assert.equal(bash("time -p env TF_LOG=debug terraform destroy"), "deny");
  assert.equal(bash("cd x\nrm -rf /"), "deny");
  assert.equal(bash("cd x\ngit commit --no-verify -m x"), "deny");
  assert.equal(bash("cd x\ngit reset --hard"), "ask");
  assert.equal(bash("sudo git reset --hard"), "ask");
  assert.equal(bash("cd x\nterraform init -upgrade"), "ask");
  // Accepted side effect (safe side): a heredoc / multi-line string line that starts with a command
  // is read as a command, so this is denied although cat only prints it.
  assert.equal(bash("cat <<EOF\nterraform apply\nEOF"), "deny");
  // still allowed: read-only multi-line scripts and text that mentions a command mid-line
  assert.equal(bash("cd x\nterraform -chdir=y validate\naws sts get-caller-identity"), "allow");
  assert.equal(bash("for r in a b; do aws iam get-role --role-name $r; done"), "allow");
  assert.equal(bash("if true; then git status; fi"), "allow");
  assert.equal(bash("time terraform plan"), "allow");
  assert.equal(bash("env AWS_PROFILE=p aws sts get-caller-identity"), "allow");
  assert.equal(bash('git commit -m "Summary\n\nDocument that terraform apply is run by humans"'), "allow");
  assert.equal(bash("echo then git push --force is denied"), "allow"); // a keyword mid-line is not command position
  assert.equal(bash("grep -rn 'do aws iam delete-role' docs"), "allow");
});

test("guard: aws CLI is an allowlist of read-only operations", () => {
  // S2: mutating calls whose verb was missing from the old denylist
  assert.equal(bash("aws ec2 authorize-security-group-ingress --group-id sg-1 --protocol tcp --port 22 --cidr 0.0.0.0/0"), "deny");
  assert.equal(bash("aws lambda add-permission --function-name f --statement-id s --action lambda:InvokeFunction --principal '*'"), "deny");
  assert.equal(bash("aws wafv2 disassociate-web-acl --resource-arn arn:x"), "deny");
  assert.equal(bash("aws kms schedule-key-deletion --key-id k"), "deny");
  assert.equal(bash("aws cloudformation deploy --template-file t.yaml --stack-name s"), "deny");
  assert.equal(bash("aws kms disable-key --key-id k"), "deny");
  assert.equal(bash("aws iam add-user-to-group --user-name u --group-name g"), "deny");
  assert.equal(bash("aws ec2 revoke-security-group-ingress --group-id sg-1"), "deny");
  assert.equal(bash("aws s3 cp a.txt s3://bucket/a.txt"), "deny");
  assert.equal(bash("aws --debug ec2 terminate-instances --instance-ids i-1"), "deny");
  assert.equal(bash("aws ec2 --region ap-northeast-1 terminate-instances --instance-ids i-1"), "deny");
  assert.equal(bash("aws ec2 $OP"), "deny");
  assert.equal(bash("echo '{}' | aws lambda invoke --function-name f out.json"), "deny");
  // read-only operations
  assert.equal(bash("aws ec2 describe-instances"), "allow");
  assert.equal(bash("aws --region ap-northeast-1 --output json iam list-roles"), "allow");
  assert.equal(bash("aws ec2 --region ap-northeast-1 describe-instances"), "allow");
  assert.equal(bash("aws --debug ecs describe-services --cluster keep"), "allow");
  assert.equal(bash("aws s3api get-bucket-policy --bucket b"), "allow");
  assert.equal(bash("aws s3 ls s3://bucket/prefix/"), "allow");
  assert.equal(bash("aws logs filter-log-events --log-group-name g"), "allow");
  assert.equal(bash("aws dynamodb query --table-name t"), "allow");
  assert.equal(bash("aws ec2 wait instance-running --instance-ids i-1"), "allow");
  assert.equal(bash("aws --version"), "allow");
  assert.equal(bash("aws help"), "allow");
  assert.equal(bash("aws ec2 help"), "allow");
  assert.equal(bash("grep -rn 'aws ec2 terminate-instances' docs"), "allow");
});

test("guard: engine control files are never edited by tools, reports are", () => {
  // S4: always, not only during read-only steps
  for (const ro of [false, true]) {
    assert.equal(edit(".agent-runs/ACTIVE", ro), "deny");
    assert.equal(edit(".agent-runs/.stop-gate.json", ro), "deny");
    assert.equal(edit(".agent-runs/20260927-x/state.json", ro), "deny");
    assert.equal(edit(".agent-runs/20260927-x/04-fix/fix.md", ro), "allow");
  }
  const write = evaluate({ tool_name: "Write", tool_input: { file_path: "/repo/.agent-runs/r1/state.json" } }, { root })?.decision;
  assert.equal(write, "deny");
});

test("guard: generated files, harness files and read-only steps", () => {
  assert.equal(edit("envs/management/ap-northeast-1/keep/.terraform.lock.hcl"), "deny");
  assert.equal(edit("lambda/pnpm-lock.yaml"), "deny");
  assert.equal(edit("terraform.tfstate"), "deny");
  assert.equal(edit(".claude/settings.json"), "ask");
  assert.equal(edit(".claude/settings.local.json"), "ask"); // S3
  assert.equal(edit(".claude/hooks/guard.mjs"), "ask");
  assert.equal(edit(".github/workflows/ci.yml"), "ask");
  assert.equal(edit(".claude/agents/planner.md"), "allow");
  assert.equal(edit("modules/network/main.tf"), "allow");
  assert.equal(edit("modules/network/main.tf", true), "deny");
  assert.equal(edit(".agent-runs/20260927-x/03-reviewers/tester.md", true), "allow");
});

test("guard hook: emits a PreToolUse deny decision as JSON", () => {
  const r = spawnSync("node", [path.join(HOOKS, "guard.mjs")], {
    input: JSON.stringify({ tool_name: "Bash", tool_input: { command: "terraform apply" }, cwd: root }),
    encoding: "utf8",
  });
  assert.equal(r.status, 0);
  const out = JSON.parse(r.stdout);
  assert.equal(out.hookSpecificOutput.hookEventName, "PreToolUse");
  assert.equal(out.hookSpecificOutput.permissionDecision, "deny");
});

test("guard hook: fails closed on unreadable input", () => {
  const r = spawnSync("node", [path.join(HOOKS, "guard.mjs")], { input: "not json", encoding: "utf8" });
  assert.equal(r.status, 2);
});

// Guard hook process against a throwaway runs dir: the read-only lock comes from ACTIVE + state.json.
test("guard hook: the read-only lock also applies to subagents (agent_id), reports stay writable", () => {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "guard-"));
  const runs = path.join(repo, ".agent-runs");
  fs.mkdirSync(path.join(runs, "r1"), { recursive: true });
  fs.writeFileSync(path.join(runs, "ACTIVE"), "r1\n");
  const setSnapshot = (snapshot) => fs.writeFileSync(path.join(runs, "r1", "state.json"), JSON.stringify({ status: "running", step: "reviewers", snapshot }));
  const guard = (file, extra = {}) => {
    const env = { ...process.env, CLAUDE_PROJECT_DIR: repo, WORKFLOW_RUNS_DIR: runs };
    const input = { tool_name: "Edit", tool_input: { file_path: path.join(repo, file) }, cwd: repo, ...extra };
    const r = spawnSync("node", [path.join(HOOKS, "guard.mjs")], { input: JSON.stringify(input), encoding: "utf8", env });
    assert.equal(r.status, 0, r.stderr);
    return r.stdout ? JSON.parse(r.stdout).hookSpecificOutput.permissionDecision : "allow";
  };
  const sub = { agent_id: "agent-abc123", agent_type: "code-reviewer" };
  setSnapshot("fingerprint");
  assert.equal(guard("modules/network/main.tf", sub), "deny");
  assert.equal(guard("modules/network/main.tf"), "deny");
  assert.equal(guard(".agent-runs/r1/03-reviewers/tester.md", sub), "allow");
  setSnapshot(null);
  assert.equal(guard("modules/network/main.tf", sub), "allow");
});

test("post-edit hook: reports invalid JSON with exit 2", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pe-"));
  const bad = path.join(dir, "x.json");
  fs.writeFileSync(bad, "{ nope");
  const r = spawnSync("node", [path.join(HOOKS, "post-edit.mjs")], { input: JSON.stringify({ tool_input: { file_path: bad } }), encoding: "utf8" });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /invalid JSON/);
  fs.writeFileSync(bad, "{}");
  const ok = spawnSync("node", [path.join(HOOKS, "post-edit.mjs")], { input: JSON.stringify({ tool_input: { file_path: bad } }), encoding: "utf8" });
  assert.equal(ok.status, 0);
});

// Stop gate against a throwaway repo whose verify.sh exits with $FAKE_VERIFY_EXIT.
function gateRepo() {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "gate-"));
  execFileSync("git", ["init", "-q"], { cwd: repo });
  fs.mkdirSync(path.join(repo, ".claude/scripts"), { recursive: true });
  fs.writeFileSync(path.join(repo, ".claude/scripts/verify.sh"), '#!/bin/sh\necho "RESULT: fake"\nexit "${FAKE_VERIFY_EXIT:-0}"\n', { mode: 0o755 });
  return repo;
}
const gate = (repo, input, code, args = []) => {
  const env = { ...process.env, CLAUDE_PROJECT_DIR: repo, FAKE_VERIFY_EXIT: String(code) };
  delete env.WORKFLOW_RUNS_DIR;
  const r = spawnSync("node", [path.join(HOOKS, "stop-gate.mjs"), ...args], { input: JSON.stringify(input), encoding: "utf8", env });
  return r.stdout ? JSON.parse(r.stdout) : {};
};

test("stop gate: blocks on FAIL at most 3 times in a row, then escalates", () => {
  const repo = gateRepo();
  const input = { session_id: "s1", hook_event_name: "Stop" };
  for (let i = 1; i <= 3; i++) {
    const out = gate(repo, { ...input, stop_hook_active: i > 1 }, 1);
    assert.equal(out.decision, "block", `attempt ${i}`);
    assert.match(out.reason, new RegExp(`stop-gate ${i}/3`));
  }
  const last = gate(repo, { ...input, stop_hook_active: true }, 1);
  assert.equal(last.decision, undefined);
  assert.match(last.systemMessage, /NOT done/);
});

test("stop gate: PASS allows silently, UNVERIFIED allows with a warning", () => {
  const repo = gateRepo();
  assert.deepEqual(gate(repo, { session_id: "s" }, 0), {});
  assert.match(gate(repo, { session_id: "s" }, 3).systemMessage, /UNVERIFIED/);
});

// C1 / T2: during a running run, verification belongs to the implementer's SubagentStop gate,
// the tester and the supervisor - the main session's Stop hook only runs the (once) run check.
test("stop gate: main session does not run the verify gate while a run is running; --gate-only still does", () => {
  const repo = gateRepo();
  const runs = path.join(repo, ".agent-runs");
  fs.mkdirSync(path.join(runs, "r1"), { recursive: true });
  fs.writeFileSync(path.join(runs, "ACTIVE"), "r1\n");
  fs.writeFileSync(path.join(runs, "r1", "state.json"), JSON.stringify({ status: "running", step: "fix" }));
  for (let i = 0; i < 5; i++) assert.deepEqual(gate(repo, { session_id: "s", stop_hook_active: true }, 1), {}, `attempt ${i}`);
  const sub = gate(repo, { session_id: "s", agent_id: "impl-1", stop_hook_active: true }, 1, ["--gate-only"]);
  assert.equal(sub.decision, "block");
  assert.match(sub.reason, /stop-gate 1\/3/);
  // once the run is finished the main session is gated again
  fs.writeFileSync(path.join(runs, "r1", "state.json"), JSON.stringify({ status: "completed", step: "supervise" }));
  assert.equal(gate(repo, { session_id: "s" }, 1).decision, "block");
});

test("stop gate: the block budget is counted per session and agent_id", () => {
  const repo = gateRepo();
  const a = { session_id: "s", agent_id: "agent-a", stop_hook_active: true };
  const b = { session_id: "s", agent_id: "agent-b", stop_hook_active: true };
  assert.match(gate(repo, a, 1, ["--gate-only"]).reason, /stop-gate 1\/3/);
  assert.match(gate(repo, a, 1, ["--gate-only"]).reason, /stop-gate 2\/3/);
  assert.match(gate(repo, b, 1, ["--gate-only"]).reason, /stop-gate 1\/3/);
  assert.match(gate(repo, { session_id: "s" }, 1).reason, /stop-gate 1\/3/);
  assert.match(gate(repo, a, 1, ["--gate-only"]).reason, /stop-gate 3\/3/);
  assert.match(gate(repo, a, 1, ["--gate-only"]).systemMessage, /NOT done/);
  assert.match(gate(repo, b, 1, ["--gate-only"]).reason, /stop-gate 2\/3/);
});

test("stop gate: an unfinished workflow run blocks once, --gate-only skips it", () => {
  const repo = gateRepo();
  const runs = path.join(repo, ".agent-runs");
  fs.mkdirSync(path.join(runs, "r1"), { recursive: true });
  fs.writeFileSync(path.join(runs, "ACTIVE"), "r1\n");
  fs.writeFileSync(path.join(runs, "r1", "state.json"), JSON.stringify({ status: "running", step: "reviewers" }));
  const first = gate(repo, { session_id: "s" }, 0);
  assert.equal(first.decision, "block");
  assert.match(first.reason, /still at step "reviewers"/);
  assert.deepEqual(gate(repo, { session_id: "s", stop_hook_active: true }, 0), {});
  assert.deepEqual(gate(repo, { session_id: "s" }, 0, ["--gate-only"]), {});
});
