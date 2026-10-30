"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

const helper = path.resolve(__dirname, "..", "scripts", "dev-lead-runner", "publish.sh");

// Runs a zsh snippet with stub log/notify/gh and a stub app-token.sh in a temp runner dir
function run(snippet, { token = "ok", ghReply = "77 app-pilote-verifier[bot]", ghRc = 0, files = {}, ghPost = "stub", headSha = SHA, headRc = 0 } = {}) {
  const R = fs.mkdtempSync(path.join(os.tmpdir(), "runner-publish-"));
  const S = path.join(R, "state");
  fs.mkdirSync(S);
  for (const [name, body] of Object.entries(files)) fs.writeFileSync(path.join(S, name), body);
  fs.writeFileSync(
    path.join(R, "app-token.sh"),
    token === "ok" ? "#!/bin/zsh\nprint tok\n" : "#!/bin/zsh\nexit 1\n",
    { mode: 0o755 },
  );
  // gh-post.sh of the runner dir: publish.sh sources it when gh_post is not defined (rule 13)
  fs.writeFileSync(
    path.join(R, "gh-post.sh"),
    'gh_post(){ print -r -- "$*" >> "$R/ghpost-calls"; gh "$@"; }\n',
  );
  const ghPostStub = ghPost === "stub" ? 'gh_post(){ print -r -- "$*" >> "$R/ghpost-calls"; gh "$@"; }' : "";
  const script = `
R=${R}; S=${S}; NAME=demo; REPO=o/demo; LOG=${R}/log
log(){ print -r -- "$*" >> "$LOG"; }
notify(){ print -r -- "$*" >> "$R/notified"; }
gh(){ print -r -- "$*" >> "$R/gh-calls"; case "$*" in *DELETE*) return 0;; *"pulls/"*) print -r -- ${JSON.stringify(headSha)}; return ${headRc};; *) print -r -- ${JSON.stringify(ghReply)}; return ${ghRc};; esac; }
${ghPostStub}
source ${helper}
${snippet}
`;
  const res = spawnSync("zsh", ["-c", script], { encoding: "utf8" });
  assert.ifError(res.error); // launch failure (zsh missing) must be explicit, not seven opaque assertion errors
  const read = (f) => (fs.existsSync(path.join(R, f)) ? fs.readFileSync(path.join(R, f), "utf8") : "");
  return { res, R, S, read, has: (f) => fs.existsSync(path.join(S, f)) };
}

const SHA = "a".repeat(40);
const good = `VERDICT: PASS+NOTES @ ${SHA}\n<!-- dev-lead-verifier -->\nbody\n`;

test("valid_verdict accepts a matching header with the marker", () => {
  const t = run(`valid_verdict $S/v ${SHA}; print rc=$?`, { files: { v: good } });
  assert.match(t.res.stdout, /rc=0/);
});

test("valid_verdict rejects another sha, a missing marker and a missing file", () => {
  const t = run(`
valid_verdict $S/v ${"b".repeat(40)}; print a=$?
valid_verdict $S/w ${SHA}; print b=$?
valid_verdict $S/none ${SHA}; print c=$?`, { files: { v: good, w: `VERDICT: FAIL @ ${SHA}\n` } });
  assert.match(t.res.stdout, /a=1/);
  assert.match(t.res.stdout, /b=1/);
  assert.match(t.res.stdout, /c=1/);
});

test("transient_retry doubles the delay, caps it at 1800 s and notifies from the 3rd failure", () => {
  const t = run(`
for i in 1 2 3 4 5 6; do transient_retry 61 ${SHA} token-transient "detail"; print "n=$tn dl=$dl"; done`);
  assert.equal(t.res.status, 0, t.res.stderr);
  assert.deepEqual(t.res.stdout.trim().split("\n"), [
    "n=1 dl=120", "n=2 dl=240", "n=3 dl=480", "n=4 dl=960", "n=5 dl=1800", "n=6 dl=1800",
  ]);
  const until = Number(fs.readFileSync(path.join(t.S, `${SHA}.transient-until`), "utf8"));
  assert.ok(until > Date.now() / 1000);
  assert.equal(t.read("notified").trim().split("\n").length, 4);
  assert.ok(!t.has("../PAUSE-demo"));
});

test("transient_retry keeps the 1800 s cap past 57 consecutive failures (no shift overflow)", () => {
  const t = run(`
print 57 > $S/${SHA}.transient
for i in 1 2 3; do transient_retry 61 ${SHA} token-transient "detail"; print "n=$tn dl=$dl"; done`);
  assert.deepEqual(t.res.stdout.trim().split("\n"), ["n=58 dl=1800", "n=59 dl=1800", "n=60 dl=1800"]);
  const until = Number(fs.readFileSync(path.join(t.S, `${SHA}.transient-until`), "utf8"));
  assert.ok(until > Date.now() / 1000);
});

test("publish_verdict with a failing token retries later: no PAUSE, verdict kept", () => {
  const t = run(`
publish_verdict 61 ${SHA} $S/${SHA}.verdict; print rc=$?`, { token: "ko", files: { [`${SHA}.verdict`]: good } });
  assert.match(t.res.stdout, /rc=1/);
  assert.ok(t.has(`${SHA}.verdict`));
  assert.ok(t.has(`${SHA}.transient-until`));
  assert.ok(!t.has(`${SHA}.posted`));
  assert.ok(!fs.existsSync(path.join(t.R, "PAUSE-demo")));
});

test("publish_verdict with an empty API reply (403 invalid token) retries later", () => {
  const t = run(`
publish_verdict 61 ${SHA} $S/${SHA}.verdict; print rc=$?`, { ghReply: "", files: { [`${SHA}.verdict`]: good } });
  assert.match(t.res.stdout, /rc=1/);
  assert.ok(t.has(`${SHA}.transient-until`));
  assert.ok(!fs.existsSync(path.join(t.R, "PAUSE-demo")));
  assert.ok(!t.read("gh-calls").includes("DELETE"));
});

test("publish_verdict with gh rc!=0 and a non-empty error body (403, 503) retries later", () => {
  for (const body of ['{"message":"Bad credentials","status":"403"}', '{"message":"Service Unavailable","status":"503"}']) {
    const t = run(`
publish_verdict 61 ${SHA} $S/${SHA}.verdict; print rc=$?`, { ghReply: body, ghRc: 1, files: { [`${SHA}.verdict`]: good } });
    assert.match(t.res.stdout, /rc=1/);
    assert.ok(t.has(`${SHA}.verdict`));
    assert.ok(t.has(`${SHA}.transient-until`));
    assert.ok(!t.has(`${SHA}.posted`));
    assert.ok(!fs.existsSync(path.join(t.R, "PAUSE-demo")));
    assert.ok(!t.read("gh-calls").includes("DELETE"));
  }
});

test("publish_verdict success marks posted and clears the retry state", () => {
  const t = run(`
print 2 > $S/${SHA}.transient; print 1 > $S/${SHA}.transient-until
publish_verdict 61 ${SHA} $S/${SHA}.verdict; print rc=$?`, { files: { [`${SHA}.verdict`]: good } });
  assert.match(t.res.stdout, /rc=0/);
  assert.ok(t.has(`${SHA}.posted`));
  assert.ok(!t.has(`${SHA}.transient`));
  assert.ok(!t.has(`${SHA}.transient-until`));
  assert.match(t.read("log"), /verdict publié par l'app : VERDICT: PASS\+NOTES/);
});

test("publish_verdict under another author deletes the comment, alerts and sets PAUSE", () => {
  const t = run(`
( publish_verdict 61 ${SHA} $S/${SHA}.verdict ); print rc=$?`, { ghReply: "55 someone-else", files: { [`${SHA}.verdict`]: good } });
  assert.match(t.res.stdout, /rc=1/);
  assert.ok(fs.existsSync(path.join(t.R, "PAUSE-demo")));
  assert.match(t.read("gh-calls"), /-X DELETE repos\/o\/demo\/issues\/comments\/55/);
  assert.match(t.read("notified"), /paused 61/);
  assert.ok(!t.has(`${SHA}.posted`));
});

test("publish_verdict posts the verdict through gh_post (redaction wrapper), never raw gh", () => {
  const t = run(`
publish_verdict 61 ${SHA} $S/${SHA}.verdict; print rc=$?`, { files: { [`${SHA}.verdict`]: good } });
  assert.match(t.res.stdout, /rc=0/);
  assert.match(t.read("ghpost-calls"), /api repos\/o\/demo\/issues\/61\/comments -F body=@/);
  assert.match(t.read("gh-calls"), /issues\/61\/comments/);
});

test("publish.sh sources gh-post.sh from the runner dir when gh_post is not defined", () => {
  const t = run(`
whence -w gh_post; publish_verdict 61 ${SHA} $S/${SHA}.verdict; print rc=$?`, { ghPost: "none", files: { [`${SHA}.verdict`]: good } });
  assert.match(t.res.stdout, /gh_post: function/);
  assert.match(t.res.stdout, /rc=0/);
  assert.match(t.read("ghpost-calls"), /issues\/61\/comments/);
});

test("publish_verdict is STALE and posts nothing when the PR head moved", () => {
  const t = run(`
publish_verdict 61 ${SHA} $S/${SHA}.verdict; print rc=$?`, {
    headSha: "b".repeat(40),
    files: { [`${SHA}.verdict`]: good },
  });
  assert.match(t.res.stdout, /STALE/);
  assert.match(t.res.stdout, /rc=2/);
  assert.ok(t.has(`${SHA}.verdict`));
  assert.ok(!t.has(`${SHA}.posted`));
  assert.ok(!t.has(`${SHA}.transient-until`));
  assert.ok(!fs.existsSync(path.join(t.R, "PAUSE-demo")));
  assert.match(t.read("ghpost-calls"), /api repos\/o\/demo\/pulls\/61/);
  assert.equal(t.read("gh-calls").includes("issues/61/comments"), false);
  assert.match(t.read("log"), /STALE/);
});

test("publish_verdict is UNKNOWN and posts nothing when the current head cannot be read", () => {
  const t = run(`
publish_verdict 61 ${SHA} $S/${SHA}.verdict; print rc=$?`, {
    headRc: 1,
    headSha: "",
    files: { [`${SHA}.verdict`]: good },
  });
  assert.match(t.res.stdout, /UNKNOWN: cannot read current PR head/);
  assert.match(t.res.stdout, /rc=1/);
  assert.ok(t.has(`${SHA}.verdict`));
  assert.ok(!t.has(`${SHA}.posted`));
  assert.ok(t.has(`${SHA}.transient-until`));
  assert.ok(!fs.existsSync(path.join(t.R, "PAUSE-demo")));
  assert.equal(t.read("gh-calls").includes("issues/61/comments"), false);
});
