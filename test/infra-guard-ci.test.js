"use strict";
// Positive samples are built by concatenation so this file never contains a real-looking value.
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");
const { scanText, scanDiff, scanEvent } = require("../scripts/infra-guard-ci.js");

const j = (...p) => p.join("");
const types = (f) => f.map((x) => x.split(": ")[1]);
const positives = [
  [j("cd /Us", "ers/", "someone/src"), "HOME_PATH"],
  [j("cd /ho", "me/", "someone/src"), "HOME_PATH"],
  [j("ssh 10", ".1.2.3"), "PRIVATE_IP"],
  [j("db 172", ".20.0.5:5432"), "PRIVATE_IP"],
  [j("nas 192", ".168.1.20"), "PRIVATE_IP"],
  [j("open http://nas", ".local/"), "INTERNAL_HOST"],
  [j("ping nas", ".local."), "INTERNAL_HOST"],
  [j("ping vm.lab", ".local."), "INTERNAL_HOST"],
  [j("Developer ID ", "Application: Jane Doe"), "APPLE_SIGNING_IDENTITY"],
  [j("DEVELOPMENT_TEAM = ", "AB12", "CD34EF"), "APPLE_TEAM_ID"],
  [j("team_id: ", "AB12", "CD34EF"), "APPLE_TEAM_ID"],
];
const negatives = [
  "cd ~/src && open <HOME>/x", "/Users/<USER>/x", "host <HOST> ip <IP>", "public 8.8.8.8 and 172.32.0.1 and 192.169.1.1",
  "version 10.2.3", "git config --local core.x", "secrets.APPLE_TEAM_ID", "example.com localhost 127.0.0.1",
  "THISISTEN1 without context", "Developer ID Installer", j("edit app", ".local", ".json"), j("edit app.lab", ".local", ".json"),
];

for (const [text, type] of positives) {
  test(`flags ${type}: ${text.slice(0, 12)}…`, () => assert.deepEqual(types(scanText("t", text)), [type]));
}
test("accepts redacted or generic text", () => {
  for (const t of negatives) assert.deepEqual(scanText("t", t), [], t);
});
test("findings never echo the matched value", () => {
  const f = scanText("body", j("x /Us", "ers/", "secretname/y"));
  assert.equal(f.length, 1);
  assert.ok(!f[0].includes("secretname"));
  assert.equal(f[0], "body:1: HOME_PATH");
});
test("diff scan reports only added lines, with new-file line numbers", () => {
  const diff = ["--- a/f.md", "+++ b/f.md", "@@ -1,2 +10,3 @@", " ctx", j("-old /Us", "ers/a/x"), "+clean", j("+ip 192", ".168.0.9")].join("\n");
  assert.deepEqual(scanDiff(diff), ["f.md:12: PRIVATE_IP"]);
});
test("pull_request event scans title, body and diff", () => {
  const ev = { pull_request: { title: "ok", body: j("see /ho", "me/x/y"), base: { sha: "b" }, head: { sha: "h" } } };
  const f = scanEvent("pull_request", ev, (b, h) => (b === "b" && h === "h" ? j("+++ b/a\n@@ -0,0 +1 @@\n+host nas", ".local") : ""));
  assert.deepEqual(f, ["(pr body):1: HOME_PATH", "a:1: INTERNAL_HOST"]);
});
test("issue_comment event scans the comment and the PR body", () => {
  const ev = { comment: { body: j("10", ".0.0.1") }, issue: { pull_request: {}, body: "clean" } };
  assert.deepEqual(scanEvent("issue_comment", ev), ["(comment):1: PRIVATE_IP"]);
});
test("push event scans commit messages and the pushed diff", () => {
  const ev = { before: "a", after: "b", commits: [{ id: "c".repeat(40), message: j("Developer ID ", "Application: x") }] };
  assert.deepEqual(scanEvent("push", ev, () => ""), ["(commit cccccccccccc):1: APPLE_SIGNING_IDENTITY"]);
});
test("CLI exits 1 on a finding and 0 when clean, from a GitHub event file", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "igci-"));
  const run = (body) => {
    const p = path.join(dir, "ev.json");
    fs.writeFileSync(p, JSON.stringify({ comment: { body }, issue: {} }));
    return spawnSync(process.execPath, [path.join(__dirname, "..", "scripts", "infra-guard-ci.js")], {
      encoding: "utf8", env: { ...process.env, GITHUB_EVENT_NAME: "issue_comment", GITHUB_EVENT_PATH: p },
    });
  };
  const bad = run(j("ssh 192", ".168.3.4"));
  assert.equal(bad.status, 1);
  assert.match(bad.stdout, /\(comment\):1: PRIVATE_IP/);
  assert.ok(!bad.stdout.includes("168.3.4"));
  assert.equal(run("all good").status, 0);
});
