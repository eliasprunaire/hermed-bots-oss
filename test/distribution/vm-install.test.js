"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const script = path.resolve(__dirname, "../../docs/spike/hd19-instruments/vm-install.sh");

// Runs the script with fake curl, brew, spctl, xcrun and PlistBuddy: each fake logs its name, then exits with its code
function run(codes) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vm-install-"));
  const calls = path.join(dir, "calls");
  for (const name of ["curl", "brew", "spctl", "xcrun", "PlistBuddy"]) {
    fs.writeFileSync(path.join(dir, name), `#!/bin/sh\necho ${name} >> ${calls}\nexit ${codes[name] ?? 0}\n`, { mode: 0o755 });
  }
  const env = { ...process.env, PATH: `${dir}:${process.env.PATH}`, PLISTBUDDY: path.join(dir, "PlistBuddy") };
  const res = spawnSync("bash", [script], { encoding: "utf8", env });
  assert.ifError(res.error);
  const called = fs.existsSync(calls) ? fs.readFileSync(calls, "utf8").trim().split("\n") : [];
  return { res, called };
}

test("an unreachable github.com does not stop the script before brew; a failed brew install exits 1", () => {
  const { res, called } = run({ curl: 28, brew: 1 });
  assert.equal(res.status, 1);
  assert.match(res.stdout, /github\.com: unreachable/);
  assert.match(res.stdout, /brew install rc=1/);
  assert.deepEqual(called, ["curl", "brew"]);
});

test("a Gatekeeper refusal exits non-zero and stops before stapler", () => {
  const { res, called } = run({ spctl: 3 });
  assert.notEqual(res.status, 0);
  assert.deepEqual(called, ["curl", "brew", "spctl"]);
});

test("a stapler refusal exits non-zero", () => {
  const { res, called } = run({ xcrun: 65 });
  assert.notEqual(res.status, 0);
  assert.deepEqual(called, ["curl", "brew", "spctl", "xcrun"]);
});

test("a PlistBuddy failure exits non-zero", () => {
  const { res, called } = run({ PlistBuddy: 1 });
  assert.notEqual(res.status, 0);
  assert.deepEqual(called, ["curl", "brew", "spctl", "xcrun", "PlistBuddy"]);
});

test("every step accepted: exit 0 after both bundle versions are read", () => {
  const { res, called } = run({});
  assert.equal(res.status, 0, res.stderr);
  assert.deepEqual(called, ["curl", "brew", "spctl", "xcrun", "PlistBuddy", "PlistBuddy"]);
});
