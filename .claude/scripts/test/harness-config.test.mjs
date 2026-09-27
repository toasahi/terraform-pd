// Cross-checks the workflow definition against the agent definitions it names, so that a renamed
// persona or a read-only agent that gained an edit tool fails CI instead of failing mid-run.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const CLAUDE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const EDIT_TOOLS = ["Edit", "Write", "MultiEdit", "NotebookEdit"];

// Minimal frontmatter reader for the two keys checked here: `name` and `tools`
// (comma-separated string or YAML list). tools === undefined means "inherits every tool".
export function parseFrontmatter(text) {
  const m = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/.exec(text);
  if (!m) return null;
  const lines = m[1].split(/\r?\n/);
  const out = {};
  for (let i = 0; i < lines.length; i++) {
    const kv = /^(name|tools):\s*(.*)$/.exec(lines[i]);
    if (!kv) continue;
    if (kv[1] === "name") out.name = kv[2].trim().replace(/^["']|["']$/g, "");
    else if (kv[2].trim()) out.tools = kv[2].split(",").map((t) => t.trim()).filter(Boolean);
    else {
      out.tools = [];
      while (i + 1 < lines.length && /^\s+-\s+/.test(lines[i + 1])) out.tools.push(lines[++i].replace(/^\s+-\s+/, "").trim());
    }
  }
  return out;
}

// Every agent the workflow launches, with whether it runs in a read-only context
// (steps with edit: false, and loop-monitor judges, which the engine always runs read-only).
export function referencedAgents(def) {
  const refs = [];
  for (const [name, step] of Object.entries(def.steps ?? {})) {
    const agents = step.parallel ?? (step.agent ? [step.agent] : []);
    for (const agent of agents) refs.push({ agent, where: `step ${name}`, readOnly: step.edit === false });
  }
  for (const m of def.loop_monitors ?? []) {
    if (m.judge?.agent) refs.push({ agent: m.judge.agent, where: `judge ${m.name}`, readOnly: true });
  }
  return refs;
}

// agents: Map<agent name, file text | undefined>. Returns a list of problems (empty = consistent).
export function checkAgents(def, agents) {
  const problems = [];
  for (const { agent, where, readOnly } of referencedAgents(def)) {
    const text = agents.get(agent);
    if (text === undefined) {
      problems.push(`${where}: .claude/agents/${agent}.md does not exist`);
      continue;
    }
    const fm = parseFrontmatter(text);
    if (!fm) {
      problems.push(`${where}: ${agent}.md has no frontmatter`);
      continue;
    }
    if (fm.name !== agent) problems.push(`${where}: ${agent}.md has name "${fm.name}", expected "${agent}"`);
    if (readOnly) {
      if (fm.tools === undefined) problems.push(`${where}: read-only agent ${agent} has no tools allowlist (inherits edit tools)`);
      else {
        const edits = fm.tools.filter((t) => EDIT_TOOLS.includes(t));
        if (edits.length) problems.push(`${where}: read-only agent ${agent} has edit tools: ${edits.join(", ")}`);
      }
    }
  }
  return problems;
}

function loadAgents(dir) {
  const agents = new Map();
  for (const f of fs.readdirSync(dir)) if (f.endsWith(".md")) agents.set(f.slice(0, -3), fs.readFileSync(path.join(dir, f), "utf8"));
  return agents;
}

test("harness config: develop.json names existing agents, and read-only agents cannot edit", () => {
  const def = JSON.parse(fs.readFileSync(path.join(CLAUDE, "workflows/develop.json"), "utf8"));
  const agents = loadAgents(path.join(CLAUDE, "agents"));
  assert.ok(referencedAgents(def).length >= 7, "expected plan, implement, 4 reviewers, fix, supervise and the judge");
  assert.deepEqual(checkAgents(def, agents), []);
});

test("harness config: the checks catch broken definitions", () => {
  const fm = (name, tools) => `---\nname: ${name}\n${tools === undefined ? "" : `tools: ${tools}\n`}model: inherit\n---\nbody\n`;
  const def = {
    steps: {
      plan: { agent: "planner", edit: false },
      implement: { agent: "implementer", edit: true },
      reviewers: { parallel: ["code-reviewer"], edit: false },
    },
    loop_monitors: [{ name: "review-fix", judge: { agent: "supervisor" } }],
  };
  const good = new Map([
    ["planner", fm("planner", "Read, Grep, Glob, Bash, WebFetch")],
    ["implementer", fm("implementer", "Read, Edit, Write, Bash")],
    ["code-reviewer", `---\nname: code-reviewer\ntools:\n  - Read\n  - Grep\n---\n`],
    ["supervisor", fm("supervisor", "Read, Bash")],
  ]);
  assert.deepEqual(checkAgents(def, good), []);

  const broken = (key, text) => checkAgents(def, new Map([...good, [key, text]]));
  const missing = new Map(good);
  missing.delete("code-reviewer");
  assert.match(checkAgents(def, missing).join("\n"), /code-reviewer\.md does not exist/);
  assert.match(broken("planner", fm("plan-agent", "Read")).join("\n"), /name "plan-agent", expected "planner"/);
  assert.match(broken("planner", "no frontmatter").join("\n"), /no frontmatter/);
  assert.match(broken("planner", fm("planner", "Read, Edit")).join("\n"), /read-only agent planner has edit tools: Edit/);
  assert.match(broken("code-reviewer", `---\nname: code-reviewer\ntools:\n  - Read\n  - Write\n---\n`).join("\n"), /edit tools: Write/);
  assert.match(broken("supervisor", fm("supervisor", "Read, NotebookEdit")).join("\n"), /judge review-fix: .*edit tools: NotebookEdit/);
  assert.match(broken("supervisor", fm("supervisor")).join("\n"), /no tools allowlist/);
  // Edit steps may carry edit tools, and may omit the allowlist.
  assert.deepEqual(broken("implementer", fm("implementer")), []);
});
