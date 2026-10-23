"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const script = path.resolve(__dirname, "../../docs/spike/hd19-instruments/vm-install.sh");
const cask = "eliasprunaire/tap/hermed-bots";
const mirror = "http://127.0.0.1:18765";
const archive = `${mirror}/github.com/eliasprunaire/hermed-bots-releases/releases/download/v0.1.0/HermedBots-0.1.0.zip`;

// Runs the script with fake tools: each fake logs its command line, prints out[name], then exits with its code
// A list of codes gives one exit code per call; the last one repeats
// The fake brew also records HOMEBREW_CASK_OPTS in the file "cask-opts" when it installs
function run({ codes = {}, out = {}, env = {}, args = ["0.1.0"], ticket = "s8ch", missingApps = false } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vm-install-"));
  const calls = path.join(dir, "calls");
  const cache = path.join(dir, "cache", "abc--HermedBots-0.1.0.zip");
  const home = path.join(dir, "home");
  const apps = path.join(dir, "apps");
  const appdir = missingApps ? path.join(dir, "missing") : apps;
  const installed = path.join(missingApps ? path.join(home, "Applications") : apps, "HermedBots.app", "Contents");
  fs.mkdirSync(installed, { recursive: true });
  fs.writeFileSync(path.join(installed, "CodeResources"), `${ticket}-ticket`);
  const outputs = { brew: cache, PlistBuddy: "0.1.0", ...out };
  for (const name of ["curl", "brew", "spctl", "codesign", "xcrun", "PlistBuddy"]) {
    const list = [].concat(codes[name] ?? 0);
    const exits = list.map((code, i) => `${i + 1}) exit ${code};;`).join(" ");
    const record = name === "brew" ? `[ "$1" = install ] && echo "\${HOMEBREW_CASK_OPTS:-}" > ${dir}/cask-opts` : ":";
    const body = [
      "#!/bin/sh",
      `printf '%s\\n' "${name} $*" >> ${calls}`,
      `n=$(cat ${dir}/n-${name} 2>/dev/null || echo 0); n=$((n + 1)); echo $n > ${dir}/n-${name}`,
      record,
      outputs[name] && name !== "brew" ? `printf '%s\\n' '${outputs[name]}'` : ":",
      name === "brew" ? `[ "$1" = --cache ] && echo '${outputs.brew}'` : ":",
      `case $n in ${exits} *) exit ${list.at(-1)};; esac`,
    ].join("\n");
    fs.writeFileSync(path.join(dir, name), `${body}\n`, { mode: 0o755 });
  }
  const base = {
    ...process.env, PATH: `${dir}:${process.env.PATH}`, PLISTBUDDY: path.join(dir, "PlistBuddy"),
    HOME: home, HV_WORK: path.join(dir, "work"), HV_APPDIR: appdir,
  };
  delete base.HV_MIRROR_URL;
  const res = spawnSync("bash", [script, ...args], { encoding: "utf8", env: { ...base, ...env } });
  assert.ifError(res.error);
  const lines = fs.existsSync(calls) ? fs.readFileSync(calls, "utf8").trim().split("\n") : [];
  const opts = path.join(dir, "cask-opts");
  return {
    res, lines, called: lines.map((line) => line.split(" ")[0]), cache, work: path.join(dir, "work"),
    caskOpts: fs.existsSync(opts) ? fs.readFileSync(opts, "utf8").trim() : null,
  };
}

const checks = ["curl", "brew", "spctl", "codesign", "xcrun", "PlistBuddy", "PlistBuddy"];

test("every step accepted: install, Gatekeeper, signature, staple and both versions, then one summary line", () => {
  const { res, lines, called } = run();
  assert.equal(res.status, 0, res.stderr);
  assert.deepEqual(called, checks);
  assert.ok(lines.includes(`brew install --cask ${cask}`));
  assert.ok(lines.some((line) => line.startsWith("codesign --verify --deep --strict")));
  assert.match(res.stdout, /^HOMEBREW-PROOF version=0\.1\.0 install=pass gatekeeper=pass signature=pass staple=validated versions=pass$/m);
});

test("a missing version argument exits 2 before any tool runs", () => {
  const { res, called } = run({ args: [] });
  assert.equal(res.status, 2);
  assert.deepEqual(called, []);
});

test("a reachable github.com leaves the Homebrew download cache alone, even with a mirror", () => {
  const { res, called } = run({ env: { HV_MIRROR_URL: mirror } });
  assert.equal(res.status, 0, res.stderr);
  assert.deepEqual(called, checks);
});

test("an unreachable github.com with a mirror downloads the archive into the Homebrew cache before the install", () => {
  const { res, lines, called, cache } = run({ codes: { curl: [28, 0] }, env: { HV_MIRROR_URL: mirror } });
  assert.equal(res.status, 0, res.stderr);
  assert.deepEqual(called, ["curl", "brew", "curl", ...checks.slice(1)]);
  assert.equal(lines[1], `brew --cache --cask ${cask}`);
  assert.equal(lines[2], `curl -fsS -o ${cache} ${archive}`);
  assert.equal(lines[3], `brew install --cask ${cask}`);
  assert.ok(fs.existsSync(path.dirname(cache)));
  assert.match(res.stdout, /archive: copied from the local mirror/);
});

test("a failed mirror download exits non-zero before the install", () => {
  const { res, called } = run({ codes: { curl: [28, 22] }, env: { HV_MIRROR_URL: mirror } });
  assert.notEqual(res.status, 0);
  assert.deepEqual(called, ["curl", "brew", "curl"]);
});

test("an unreachable github.com without a mirror still tries the install, and a failed install exits 1", () => {
  const { res, called } = run({ codes: { curl: 28, brew: 1 } });
  assert.equal(res.status, 1);
  assert.match(res.stdout, /github\.com: unreachable/);
  assert.match(res.stdout, /brew install rc=1/);
  assert.deepEqual(called, ["curl", "brew"]);
});

test("without write access to the applications directory, the install goes to ~/Applications through --appdir", () => {
  const { res, caskOpts } = run({ missingApps: true });
  assert.equal(res.status, 0, res.stderr);
  assert.match(caskOpts, /^--appdir=.*\/home\/Applications$/);
  assert.equal(run().caskOpts, "");
});

test("a Gatekeeper refusal exits non-zero and stops before codesign", () => {
  const { res, called } = run({ codes: { spctl: 3 } });
  assert.notEqual(res.status, 0);
  assert.deepEqual(called, ["curl", "brew", "spctl"]);
});

test("a codesign refusal exits non-zero and stops before stapler", () => {
  const { res, called } = run({ codes: { codesign: 1 } });
  assert.notEqual(res.status, 0);
  assert.deepEqual(called, ["curl", "brew", "spctl", "codesign"]);
});

test("a stapler failure falls back to the stapled ticket file and says so in the summary", () => {
  const { res, called } = run({ codes: { xcrun: 68 } });
  assert.equal(res.status, 0, res.stderr);
  assert.deepEqual(called, checks);
  assert.match(res.stdout, /stapler: online validation failed/);
  assert.match(res.stdout, /staple=ticket-file-only/);
});

// 65 invalid ticket, 66 missing or invalid ticket, 77 revoked ticket: a ticket file that starts with s8ch must not hide them
for (const [code, meaning] of [[65, "invalid"], [66, "missing"], [77, "revoked"]]) {
  test(`a stapler refusal with code ${code} (${meaning} ticket) exits with that code, even when the ticket file starts with s8ch`, () => {
    const { res, called } = run({ codes: { xcrun: code } });
    assert.equal(res.status, code, res.stderr);
    assert.deepEqual(called, ["curl", "brew", "spctl", "codesign", "xcrun"]);
    assert.match(res.stdout, new RegExp(`stapler: refused with exit ${code}`));
    assert.doesNotMatch(res.stdout, /ticket-file-only|HOMEBREW-PROOF/);
  });
}

test("a stapler failure with no ticket file in the bundle exits non-zero", () => {
  const { res, called } = run({ codes: { xcrun: 68 }, ticket: "none" });
  assert.notEqual(res.status, 0);
  assert.deepEqual(called, ["curl", "brew", "spctl", "codesign", "xcrun"]);
});

test("a PlistBuddy failure exits non-zero", () => {
  const { res, called } = run({ codes: { PlistBuddy: 1 } });
  assert.notEqual(res.status, 0);
  assert.deepEqual(called, ["curl", "brew", "spctl", "codesign", "xcrun", "PlistBuddy"]);
});

test("a bundle version other than the published one exits non-zero", () => {
  const { res, called } = run({ out: { PlistBuddy: "0.0.9" } });
  assert.notEqual(res.status, 0);
  assert.match(res.stdout, /CFBundleShortVersionString is 0\.0\.9, expected 0\.1\.0/);
  assert.deepEqual(called, ["curl", "brew", "spctl", "codesign", "xcrun", "PlistBuddy"]);
});

test("the output is also saved as install.txt in a new evidence directory, and a failure keeps its exit code", () => {
  for (const [codes, status] of [[{}, 0], [{ spctl: 3 }, 3]]) {
    const { res, work } = run({ codes });
    assert.equal(res.status, status, res.stderr);
    const evidence = path.join(work, "evidence");
    const [dir, ...others] = fs.readdirSync(evidence);
    assert.match(dir, /^hd19-\d{8}-\d{6}$/);
    assert.deepEqual(others, []);
    assert.equal(fs.readFileSync(path.join(evidence, dir, "install.txt"), "utf8"), res.stdout);
  }
});
