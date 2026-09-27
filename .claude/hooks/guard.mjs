#!/usr/bin/env node
// PreToolUse guard: the deterministic part of the harness policy. CLAUDE.md and rules are advisory;
// this hook is what actually stops an action. It is not a sandbox (a determined command can evade
// string matching) - it catches the mistakes an agent realistically makes.
//
//   deny  terraform apply/destroy/import/state mutation, any aws CLI operation outside the read-only
//         allowlist, force push, push to main, --no-verify / commit -n (git rules also see through
//         git's global options such as -C / -c), editing state / lock files or the workflow engine's
//         control files (.agent-runs/ACTIVE, .stop-gate.json, <run>/state.json) by hand, and code edits
//         while the active workflow run is on a read-only step - by the main session and by subagents
//         alike (reports under .agent-runs/ are allowed)
//   ask   edits to the harness itself (.claude/settings.json, settings.local.json, .claude/hooks/,
//         .claude/workflows/, .claude/scripts/), to CI (.github/workflows/), terraform init -upgrade,
//         git reset --hard
//
// Input: PreToolUse JSON on stdin. Output: hookSpecificOutput.permissionDecision (exit 0).

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

// Matches a command only in command position, so text such as a commit message mentioning
// "terraform apply" mid-line is not blocked. Command position = start of the string or after ; & | ( or
// a newline, followed by any mix of VAR=x assignments, the shell words that precede a command
// (then do else elif if while until { !) and the prefix commands time / env / sudo / nice / xargs /
// command / exec (with their flags, e.g. time -p, sudo -E) and timeout <duration>. The shell words
// count only in command position themselves ("echo then git push" is text).
// Accepted side effect (safe side): a heredoc or multi-line string line that starts with a command,
// e.g. "cat <<EOF\nterraform apply\nEOF", is read as that command and denied.
const PREFIX = String.raw`(?:\w+=\S*\s+|(?:then|do|else|elif|if|while|until|\{|!)\s+|(?:time|env|sudo|nice|xargs|command|exec)(?:\s+-\S+)*\s+|timeout\s+\S+\s+)*`;
const cmd = (body) => new RegExp(String.raw`(?:^|[;&|(\n]\s*)` + PREFIX + String.raw`(?:\S*/)?` + body);
// terraform subcommand = first word after the global options (-chdir=..., -help, ...)
const TF = String.raw`terraform(?:\s+-\S+)*\s+`;
// git subcommand = first word after the global options: -C <dir>, -c <k=v>, --git-dir[=| ]<dir>,
// --work-tree / --namespace / --config-env with a value, and flags such as --no-pager, -P, --bare.
const GIT_ARG = String.raw`(?:"[^"]*"|'[^']*'|\S+)`;
const GIT = String.raw`git(?:\s+(?:-[Cc]\s+${GIT_ARG}|--(?:git-dir|work-tree|namespace|config-env)(?:=|\s+)${GIT_ARG}|--?[\w-]+(?:=${GIT_ARG})?))*\s+`;

const DENY_BASH = [
  [cmd(TF + String.raw`(apply|destroy|import|taint|untaint|force-unlock)\b`), "terraform apply/destroy/import are run by a human after review, never by the agent (docs/implementation-plan.md §6.2)"],
  [cmd(TF + String.raw`state\s+(rm|mv|push|replace-provider)\b`), "terraform state mutation is a human operation"],
  // push: -f alone or inside combined short flags (-fu, -uf)
  [cmd(GIT + String.raw`push\b[^|;&]*?(\s--force\b|\s--force-with-lease\b|\s-[a-zA-Z]*f[a-zA-Z]*\b|\s\+\S)`), "force push rewrites shared history; ask the user"],
  [cmd(GIT + String.raw`push\b[^|;&]*?(\s|:)(main|master)(\s|$)`), "never push to the default branch; push the feature branch"],
  [cmd(GIT + String.raw`(commit|push)\b[^|;&]*?\s--no-verify\b`), "--no-verify skips the repository's checks"],
  // commit -n is --no-verify (push -n is --dry-run): a whole token of commit's boolean short flags that
  // contains n (-n, -an, -nq), optionally ending in -m / -F with an attached value (-nm"msg"). Tokens that
  // start with a value option (-mnote, -uno) or are words (-input=false) are not read as -n.
  [cmd(GIT + String.raw`commit\b[^|;&]*?\s-[aeinopqsvz]*n[aeinopqsvz]*(?:[mF]\S*)?(?=\s|$)`), "commit -n is --no-verify, which skips the repository's checks"],
  [cmd(String.raw`rm\s+-[a-zA-Z]*r[a-zA-Z]*\s+(/|~|\$HOME|\.\.)(\s|$)`), "refusing recursive delete outside the repository"],
];

const ASK_BASH = [
  [cmd(TF + String.raw`init\b[^|;&]*?\s-upgrade\b`), "init -upgrade rewrites .terraform.lock.hcl (provider upgrade): confirm it is intended"],
  [cmd(GIT + String.raw`reset\s+--hard\b`), "git reset --hard discards uncommitted work"],
];

// aws CLI: allowlist of read-only operations; every other operation is denied.
// Global options that take a value (AWS CLI v2 "Global Options"); other options are treated as flags,
// which can only make a call parse as "not read-only" (deny), never the other way round.
const AWS_CALL = new RegExp(cmd(String.raw`aws(?=\s|$)`).source, "g");
const AWS_VALUE_OPTS = new Set(["--endpoint-url", "--output", "--query", "--profile", "--region", "--color", "--ca-bundle", "--cli-read-timeout", "--cli-connect-timeout", "--cli-binary-format"]);
const AWS_READ_OP = /^(describe|list|get|head|lookup|search|filter|batch-get|query|scan|simulate|validate|wait)(-|$)/;

// args: the words after "aws" up to the end of that command. true = allowed (read-only or harmless).
export function awsIsReadOnly(args) {
  const positional = [];
  for (let i = 0; i < args.length && positional.length < 2; i++) {
    const a = args[i];
    if (a.startsWith("-")) {
      if (AWS_VALUE_OPTS.has(a)) i++;
    } else positional.push(a);
  }
  const [service, op] = positional;
  if (service === undefined || service === "help" || op === undefined || op === "help") return true; // --version, usage, help
  if (service === "s3") return op === "ls";
  return AWS_READ_OP.test(op);
}

function awsDenied(command) {
  for (const m of command.matchAll(AWS_CALL)) {
    const rest = command.slice(m.index + m[0].length);
    const args = [];
    for (const [tok] of rest.matchAll(/"[^"]*"|'[^']*'|[;&|)\n]|[^\s;&|)]+/g)) {
      if (/^[;&|)\n]$/.test(tok)) break;
      args.push(tok.replace(/^(["'])(.*)\1$/, "$2"));
    }
    if (!awsIsReadOnly(args)) return true;
  }
  return false;
}

const DENY_PATHS = [
  [/(^|\/)[^/]*\.tfstate(\.[^/]*)?$/, "state files are never edited by hand"],
  [/(^|\/)\.terraform\//, ".terraform/ is generated by terraform init"],
  [/(^|\/)\.terraform\.lock\.hcl$/, "lock files are written by terraform init / providers lock, not by hand"],
  [/(^|\/)pnpm-lock\.yaml$/, "pnpm-lock.yaml is written by pnpm, not by hand"],
  [/(^|\/)\.agent-runs\/(ACTIVE|\.stop-gate\.json|[^/]+\/state\.json)$/, "workflow engine control files are written by workflow.mjs / stop-gate.mjs only; reports in the step directories stay writable"],
];

const ASK_PATHS = [
  [/^\.claude\/(settings(\.local)?\.json|hooks\/|workflows\/|scripts\/)/, "this edits the agent harness itself (its guardrails / loop rules)"],
  [/^\.github\/workflows\//, "this edits CI"],
];

const EDIT_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit"]);

export function evaluate(input, { root, activeStepIsReadOnly = () => false } = {}) {
  const tool = input.tool_name;
  const ti = input.tool_input ?? {};
  if (tool === "Bash") {
    const cmd = String(ti.command ?? "");
    for (const [re, why] of DENY_BASH) if (re.test(cmd)) return { decision: "deny", reason: why };
    if (awsDenied(cmd)) {
      return { decision: "deny", reason: "the aws CLI is read-only for the agent: describe/list/get/head/lookup/search/filter/batch-get/query/scan/simulate/validate/wait, s3 ls" };
    }
    for (const [re, why] of ASK_BASH) if (re.test(cmd)) return { decision: "ask", reason: why };
    return null;
  }
  if (EDIT_TOOLS.has(tool)) {
    const abs = path.resolve(root ?? input.cwd ?? ".", String(ti.file_path ?? ti.notebook_path ?? ""));
    const rel = root ? path.relative(root, abs).split(path.sep).join("/") : abs;
    for (const [re, why] of DENY_PATHS) if (re.test(rel)) return { decision: "deny", reason: why };
    const inRuns = rel === ".agent-runs" || rel.startsWith(".agent-runs/");
    if (!inRuns && activeStepIsReadOnly()) {
      return { decision: "deny", reason: "the active workflow run is on a read-only step (plan / review / supervise); finish it with workflow.mjs next before editing" };
    }
    for (const [re, why] of ASK_PATHS) if (re.test(rel)) return { decision: "ask", reason: why };
  }
  return null;
}

async function main() {
  let raw = "";
  for await (const chunk of process.stdin) raw += chunk;
  const input = JSON.parse(raw || "{}");
  const root = process.env.CLAUDE_PROJECT_DIR || input.cwd || process.cwd();
  const activeStepIsReadOnly = () => {
    // Applies to subagents too (input.agent_id): a read-only step may run through a general-purpose
    // agent whose tools are not restricted. Edit steps have snapshot null, so the implementer is unaffected.
    try {
      const runsDir = process.env.WORKFLOW_RUNS_DIR ?? path.join(root, ".agent-runs");
      const id = fs.readFileSync(path.join(runsDir, "ACTIVE"), "utf8").trim();
      const state = JSON.parse(fs.readFileSync(path.join(runsDir, id, "state.json"), "utf8"));
      return state.snapshot != null;
    } catch {
      return false;
    }
  };
  const result = evaluate(input, { root, activeStepIsReadOnly });
  if (result) {
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: result.decision,
          permissionDecisionReason: `[harness guard] ${result.reason}`,
        },
      }),
    );
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  main().catch((err) => {
    // Fail closed for policy hooks: an unreadable input blocks the call instead of allowing it.
    process.stderr.write(`[harness guard] ${err.message}\n`);
    process.exit(2);
  });
}
