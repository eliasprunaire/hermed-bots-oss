"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const script = path.resolve(__dirname, "../../docs/spike/hd19-instruments/vm-install.sh");

// Runs the script with fake curl, brew, spctl, codesign, xcrun and PlistBuddy: each fake logs its name, prints it, then exits with its code
// The fake brew also records the Homebrew mirror variables it received
function run(codes, env = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vm-install-"));
  const calls = path.join(dir, "calls");
  const mirror = path.join(dir, "mirror");
  const work = path.join(dir, "work");
  for (const name of ["curl", "brew", "spctl", "codesign", "xcrun", "PlistBuddy"]) {
    const record = name === "brew" ? `echo "\${HOMEBREW_ARTIFACT_DOMAIN:-}|\${HOMEBREW_ARTIFACT_DOMAIN_NO_FALLBACK:-}" > ${mirror}\n` : "";
    fs.writeFileSync(path.join(dir, name), `#!/bin/sh\necho ${name} >> ${calls}\n${record}echo ${name}-out\nexit ${codes[name] ?? 0}\n`, { mode: 0o755 });
  }
  const base = { ...process.env, PATH: `${dir}:${process.env.PATH}`, PLISTBUDDY: path.join(dir, "PlistBuddy"), HV_WORK: work };
  delete base.HV_MIRROR_URL;
  const res = spawnSync("bash", [script], { encoding: "utf8", env: { ...base, ...env } });
  assert.ifError(res.error);
  const called = fs.existsSync(calls) ? fs.readFileSync(calls, "utf8").trim().split("\n") : [];
  const domain = fs.existsSync(mirror) ? fs.readFileSync(mirror, "utf8").trim() : null;
  return { res, called, domain, work };
}

test("an unreachable github.com does not stop the script before brew; a failed brew install exits 1", () => {
  const { res, called } = run({ curl: 28, brew: 1 });
  assert.equal(res.status, 1);
  assert.match(res.stdout, /github\.com: unreachable/);
  assert.match(res.stdout, /brew install rc=1/);
  assert.deepEqual(called, ["curl", "brew"]);
});

test("a Gatekeeper refusal exits non-zero and stops before codesign", () => {
  const { res, called } = run({ spctl: 3 });
  assert.notEqual(res.status, 0);
  assert.deepEqual(called, ["curl", "brew", "spctl"]);
});

test("a codesign refusal exits non-zero and stops before stapler", () => {
  const { res, called } = run({ codesign: 1 });
  assert.notEqual(res.status, 0);
  assert.deepEqual(called, ["curl", "brew", "spctl", "codesign"]);
});

test("a stapler refusal exits non-zero", () => {
  const { res, called } = run({ xcrun: 65 });
  assert.notEqual(res.status, 0);
  assert.deepEqual(called, ["curl", "brew", "spctl", "codesign", "xcrun"]);
});

test("a PlistBuddy failure exits non-zero", () => {
  const { res, called } = run({ PlistBuddy: 1 });
  assert.notEqual(res.status, 0);
  assert.deepEqual(called, ["curl", "brew", "spctl", "codesign", "xcrun", "PlistBuddy"]);
});

test("every step accepted: exit 0 after both bundle versions are read", () => {
  const { res, called } = run({});
  assert.equal(res.status, 0, res.stderr);
  assert.deepEqual(called, ["curl", "brew", "spctl", "codesign", "xcrun", "PlistBuddy", "PlistBuddy"]);
});

test("HV_MIRROR_URL becomes the Homebrew artifact domain without fallback; without it brew gets none", () => {
  assert.equal(run({}, { HV_MIRROR_URL: "http://127.0.0.1:18765" }).domain, "http://127.0.0.1:18765|1");
  assert.equal(run({}).domain, "|");
});

test("the output is also saved as install.txt in a new evidence directory, and a failure keeps its exit code", () => {
  for (const [codes, status] of [[{}, 0], [{ spctl: 3 }, 3]]) {
    const { res, work } = run(codes);
    assert.equal(res.status, status, res.stderr);
    const evidence = path.join(work, "evidence");
    const [dir, ...others] = fs.readdirSync(evidence);
    assert.match(dir, /^hd19-\d{8}-\d{6}$/);
    assert.deepEqual(others, []);
    assert.equal(fs.readFileSync(path.join(evidence, dir, "install.txt"), "utf8"), res.stdout);
  }
});
