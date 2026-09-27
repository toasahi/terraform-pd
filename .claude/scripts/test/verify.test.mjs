import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const VERIFY = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../verify.sh");

// C3 / T1: a failing harness test must be named in verify.sh's FAIL output, even when many passing
// tests follow it (the log is truncated to its tail).
test("verify.sh: the name of a failing harness test appears in the FAIL output", () => {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "verify-"));
  execFileSync("git", ["init", "-q"], { cwd: repo });
  execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "init"], { cwd: repo });
  fs.mkdirSync(path.join(repo, ".claude/scripts/test"), { recursive: true });
  fs.copyFileSync(VERIFY, path.join(repo, ".claude/scripts/verify.sh"));
  fs.chmodSync(path.join(repo, ".claude/scripts/verify.sh"), 0o755);
  fs.writeFileSync(
    path.join(repo, ".claude/scripts/test/fixture.test.mjs"),
    [
      'import assert from "node:assert/strict";',
      'import { test } from "node:test";',
      'test("fixture: the failing case is named in the output", () => assert.equal(1, 2));',
      "for (let i = 0; i < 60; i++) test(`fixture: passing case ${i}`, () => {});",
      "",
    ].join("\n"),
  );
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT; // run the fixture as a top-level node --test, not as a child of this one
  const r = spawnSync(path.join(repo, ".claude/scripts/verify.sh"), ["--level", "fast", "--base", "HEAD"], { cwd: repo, encoding: "utf8", env });
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.match(r.stdout, /FAIL harness test/);
  assert.match(r.stdout, /fixture: the failing case is named in the output/);
  assert.match(r.stdout, /RESULT: FAIL/);
});
