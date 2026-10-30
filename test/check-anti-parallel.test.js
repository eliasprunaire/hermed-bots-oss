"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const {
  decideExecutor,
  decideVerifier,
} = require("../scripts/check-anti-parallel.js");

const MARKER = "<!-- dev-lead-verifier -->";
const HEAD = "a".repeat(40);
const OTHER = "b".repeat(40);
const AGENT_A = "bc-4fa94a52-04cd-579c-817b-27ae10b9c21c";
const AGENT_B = "bc-73475f93-cfd4-56ea-92c6-fc82e54f4818";
const VERIFIER_PATH = ".github/workflows/verdict-gate.yml";

function marked(verdict, sha) {
  return `VERDICT: ${verdict} @ ${sha}\n${MARKER}`;
}

function comment(id, body, login = "app-pilote-verifier[bot]") {
  return { id, body, user: { login } };
}

function decideV(input) {
  if (Object.prototype.hasOwnProperty.call(input, "runs")) {
    return decideVerifier(input);
  }
  return decideVerifier({ ...input, runs: [] });
}

test("single verdict passes", () => {
  const decision = decideV({
    headSha: HEAD,
    comments: [comment("1", marked("PASS", HEAD))],
  });
  assert.equal(decision.kind, "pass");
  assert.equal(decision.description, `one verifier for ${HEAD}`);
});

test("two verdicts for the same sha fail", () => {
  const decision = decideV({
    headSha: HEAD,
    comments: [
      comment("1", marked("PASS", HEAD)),
      comment("2", marked("PASS+NOTES", HEAD)),
    ],
  });
  assert.equal(decision.kind, "fail");
  assert.equal(decision.reason.code, "parallel-verdicts");
  assert.equal(decision.reason.count, 2);
  assert.equal(
    decision.description,
    `multiple marked VERDICT comments for ${HEAD}`,
  );
});

test("verdicts on old shas are ignored", () => {
  const decision = decideV({
    headSha: HEAD,
    comments: [
      comment("1", marked("PASS", OTHER)),
      comment("2", marked("FAIL", OTHER)),
      comment("3", marked("PASS", HEAD)),
    ],
  });
  assert.equal(decision.kind, "pass");
});

test("a second in-progress verifier run for the head SHA fails", () => {
  const decision = decideVerifier({
    headSha: HEAD,
    comments: [comment("1", marked("PASS", HEAD))],
    runs: [
      {
        headSha: HEAD,
        status: "in_progress",
        path: VERIFIER_PATH,
      },
      {
        headSha: HEAD,
        status: "queued",
        path: VERIFIER_PATH,
      },
    ],
  });
  assert.equal(decision.kind, "fail");
  assert.equal(decision.reason.code, "verifier-in-progress");
  assert.equal(decision.description, `concurrent verifier runs for ${HEAD}`);
});

test("one in-progress verifier run for the head SHA passes", () => {
  const decision = decideVerifier({
    headSha: HEAD,
    comments: [],
    runs: [
      {
        headSha: HEAD,
        status: "in_progress",
        path: VERIFIER_PATH,
      },
      {
        headSha: OTHER,
        status: "in_progress",
        path: VERIFIER_PATH,
      },
      {
        headSha: HEAD,
        status: "in_progress",
        path: ".github/workflows/anti-parallel.yml",
      },
    ],
  });
  assert.equal(decision.kind, "pass");
});

test("single executor passes", () => {
  const decision = decideExecutor({
    commits: [
      { message: `fix the lock\n\n${AGENT_A}\n`, authoredAtMs: 1 },
      { message: `docs for the lock\n\n${AGENT_A}\n`, authoredAtMs: 2 },
    ],
  });
  assert.equal(decision.kind, "pass");
  assert.equal(decision.description, "one executor");
});

test("two executors fail", () => {
  const decision = decideExecutor({
    commits: [
      { message: `fix the lock\n\n${AGENT_A}\n`, authoredAtMs: 10 },
      { message: `also fix the lock\n\n${AGENT_B}\n`, authoredAtMs: 10 },
    ],
  });
  assert.equal(decision.kind, "fail");
  assert.equal(decision.reason.code, "parallel-executors");
  assert.equal(
    decision.description,
    "multiple executor identities in one run window",
  );
});

test("commits without an agent id pass as a single executor", () => {
  const decision = decideExecutor({
    commits: [{ message: "fix the lock\n", authoredAtMs: 1 }],
  });
  assert.equal(decision.kind, "pass");
});

test("unreadable comments fail closed", () => {
  const decision = decideV({ headSha: HEAD, comments: null });
  assert.equal(decision.kind, "fail");
  assert.equal(decision.reason.code, "unreadable");
});

test("unreadable runs fail closed", () => {
  const decision = decideVerifier({
    headSha: HEAD,
    comments: [],
    runs: null,
  });
  assert.equal(decision.kind, "fail");
  assert.equal(decision.reason.code, "unreadable-runs");
});

test("workflows key verifier concurrency on PR and head SHA", () => {
  const verdict = readFileSync(
    join(__dirname, "..", ".github/workflows/verdict-gate.yml"),
    "utf8",
  );
  const lock = readFileSync(
    join(__dirname, "..", ".github/workflows/anti-parallel.yml"),
    "utf8",
  );
  const ci = readFileSync(join(__dirname, "..", ".github/workflows/ci.yml"), "utf8");
  assert.match(
    verdict,
    /group: verdict-gate-\$\{\{ github\.event\.pull_request\.number \|\| github\.event\.issue\.number \}\}-\$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}/,
  );
  assert.match(verdict, /cancel-in-progress:\s*false/);
  assert.match(
    lock,
    /group: verifier-\$\{\{ github\.event\.pull_request\.number \|\| github\.event\.issue\.number \}\}-\$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}/,
  );
  assert.match(lock, /cancel-in-progress:\s*false/);
  assert.match(
    ci,
    /group: executor-\$\{\{ github\.event\.pull_request\.number \|\| github\.run_id \}\}/,
  );
  assert.match(ci, /cancel-in-progress:\s*false/);
  assert.match(lock, /node scripts\/check-anti-parallel\.js/);
});
