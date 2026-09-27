#!/usr/bin/env node
// PostToolUse (Edit|Write|MultiEdit): the innermost loop. Formats what the agent just wrote and
// reports syntax errors immediately (exit 2 feeds stderr back to Claude), so broken HCL / shell /
// JSON never waits for the Stop gate or a reviewer.
//   *.tf, *.tfvars, *.tftest.hcl -> terraform fmt <file>   (skipped when terraform is missing)
//   *.sh                         -> bash -n <file>
//   *.json                       -> JSON.parse

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

let raw = "";
for await (const chunk of process.stdin) raw += chunk;
const input = JSON.parse(raw || "{}");
const file = input.tool_input?.file_path;
if (!file || !fs.existsSync(file)) process.exit(0);

const fail = (msg) => {
  process.stderr.write(`[post-edit] ${path.basename(file)}: ${msg}\n`);
  process.exit(2);
};

const run = (cmd, args) => execFileSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });

if (/\.(tf|tfvars)$|\.tftest\.hcl$/.test(file)) {
  try {
    run("terraform", ["fmt", file]);
  } catch (err) {
    if (err.code !== "ENOENT") fail(`terraform fmt failed (syntax error?)\n${err.stderr || err.message}`);
  }
} else if (file.endsWith(".sh")) {
  try {
    run("bash", ["-n", file]);
  } catch (err) {
    fail(`bash -n failed\n${err.stderr || err.message}`);
  }
} else if (file.endsWith(".json")) {
  try {
    JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (err) {
    fail(`invalid JSON: ${err.message}`);
  }
}
