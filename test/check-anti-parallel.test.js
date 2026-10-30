"use strict";

const assert = require("node:assert/strict");
const { mkdtempSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const {
  decideExecutor,
  decideVerifier,
  main,
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

function comment(id, body, login = "app-pilote-verifier[bot]", type = "Bot") {
  return { id, body, user: { login, type } };
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

test("a copied marker from a User login does not count as a verifier", () => {
  const decision = decideV({
    headSha: HEAD,
    comments: [
      comment("1", marked("PASS", HEAD)),
      comment("2", marked("PASS", HEAD), "app-pilote-verifier[bot]", "User"),
      comment("3", marked("FAIL", HEAD), "spoof", "User"),
    ],
  });
  assert.equal(decision.kind, "pass");
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

test("a comment run titled pr-70 is not counted for PR 7", () => {
  const decision = decideVerifier({
    headSha: HEAD,
    number: 7,
    comments: [],
    runs: [
      {
        headSha: HEAD,
        status: "in_progress",
        path: VERIFIER_PATH,
        event: "pull_request",
      },
      {
        headSha: OTHER,
        status: "queued",
        path: VERIFIER_PATH,
        event: "issue_comment",
        displayTitle: "verdict-gate pr-70",
      },
    ],
  });
  assert.equal(decision.kind, "pass");
});

test("an issue_comment verifier run for the same PR is counted", () => {
  const decision = decideVerifier({
    headSha: HEAD,
    number: 70,
    comments: [],
    runs: [
      {
        headSha: HEAD,
        status: "in_progress",
        path: VERIFIER_PATH,
        event: "pull_request",
      },
      {
        headSha: OTHER,
        status: "queued",
        path: VERIFIER_PATH,
        event: "issue_comment",
        displayTitle: "verdict-gate pr-70",
      },
    ],
  });
  assert.equal(decision.kind, "fail");
  assert.equal(decision.reason.code, "verifier-in-progress");
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

test("workflows key verifier concurrency on the PR number", () => {
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
    /group: verdict-gate-\$\{\{ github\.event\.pull_request\.number \|\| github\.event\.issue\.number \}\}$/m,
  );
  assert.equal(
    /group: verdict-gate-.*github\.sha/.test(verdict),
    false,
  );
  assert.match(verdict, /cancel-in-progress:\s*false/);
  assert.match(
    lock,
    /group: verifier-\$\{\{ github\.event\.pull_request\.number \|\| github\.event\.issue\.number \}\}/,
  );
  assert.equal(lock.includes("github.event.pull_request.head.sha || github.sha"), false);
  assert.match(lock, /cancel-in-progress:\s*false/);
  assert.match(lock, /statuses:\s*write/);
  assert.match(lock, /git show "\$BASE_SHA:scripts\/check-anti-parallel\.js"/);
  assert.match(lock, /node "\$checker"/);
  assert.match(
    ci,
    /group: executor-\$\{\{ github\.event\.pull_request\.number \|\| github\.run_id \}\}/,
  );
  assert.match(ci, /cancel-in-progress:\s*false/);
});

function jsonResponse(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    headers: {
      get() {
        return null;
      },
    },
  };
}

test("an issue_comment fail posts a head status and exits 0", async () => {
  const dir = mkdtempSync(join(tmpdir(), "anti-parallel-"));
  const eventPath = join(dir, "event.json");
  writeFileSync(
    eventPath,
    JSON.stringify({
      issue: { number: 70, pull_request: { url: "https://api.github.com/repos/acme/app/pulls/70" } },
    }),
  );
  const posted = [];
  const stderr = [];
  const io = {
    env: {
      GITHUB_TOKEN: "test-token",
      GITHUB_EVENT_PATH: eventPath,
      GITHUB_REPOSITORY: "acme/app",
      GITHUB_EVENT_NAME: "issue_comment",
    },
    readFile(path) {
      return readFileSync(path, "utf8");
    },
    stderr(line) {
      stderr.push(line);
    },
    async fetch(url, init) {
      const href = String(url);
      if (href.endsWith("/pulls/70") && (init == null || init.method == null)) {
        return jsonResponse({
          number: 70,
          head: { sha: HEAD },
          base: { sha: OTHER },
        });
      }
      if (href.includes("/issues/70/comments")) {
        return jsonResponse([
          {
            body: marked("PASS", HEAD),
            user: { login: "app-pilote-verifier[bot]", type: "Bot" },
          },
          {
            body: marked("FAIL", HEAD),
            user: { login: "app-pilote-verifier[bot]", type: "Bot" },
          },
        ]);
      }
      if (href.includes("/actions/") && href.includes("/runs")) {
        return jsonResponse({ workflow_runs: [] });
      }
      if (href.includes(`/statuses/${HEAD}`) && init && init.method === "POST") {
        posted.push(JSON.parse(init.body));
        return jsonResponse({}, 201);
      }
      throw new Error(`unexpected url ${href}`);
    },
  };
  try {
    assert.equal(await main([], io), 0);
    assert.equal(posted.length, 1);
    assert.equal(posted[0].state, "failure");
    assert.equal(posted[0].context, "anti-parallel");
    assert.match(stderr.join("\n"), /multiple marked VERDICT comments/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a pull_request fail posts a head status and exits 1", async () => {
  const dir = mkdtempSync(join(tmpdir(), "anti-parallel-"));
  const eventPath = join(dir, "event.json");
  writeFileSync(
    eventPath,
    JSON.stringify({
      pull_request: {
        number: 70,
        head: { sha: HEAD },
        base: { sha: OTHER },
      },
    }),
  );
  const posted = [];
  const io = {
    env: {
      GITHUB_TOKEN: "test-token",
      GITHUB_EVENT_PATH: eventPath,
      GITHUB_REPOSITORY: "acme/app",
      GITHUB_EVENT_NAME: "pull_request",
    },
    readFile(path) {
      return readFileSync(path, "utf8");
    },
    stderr() {},
    run() {
      return { status: 0, stdout: "" };
    },
    async fetch(url, init) {
      const href = String(url);
      if (href.includes("/issues/70/comments")) {
        return jsonResponse([
          {
            body: marked("PASS", HEAD),
            user: { login: "app-pilote-verifier[bot]", type: "Bot" },
          },
          {
            body: marked("FAIL", HEAD),
            user: { login: "app-pilote-verifier[bot]", type: "Bot" },
          },
        ]);
      }
      if (href.includes("/actions/") && href.includes("/runs")) {
        return jsonResponse({ workflow_runs: [] });
      }
      if (href.includes(`/statuses/${HEAD}`) && init && init.method === "POST") {
        posted.push(JSON.parse(init.body));
        return jsonResponse({}, 201);
      }
      throw new Error(`unexpected url ${href}`);
    },
  };
  try {
    assert.equal(await main([], io), 1);
    assert.equal(posted.length, 1);
    assert.equal(posted[0].state, "failure");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("issue_comment still fails when executors overlap on the same head", async () => {
  const dir = mkdtempSync(join(tmpdir(), "anti-parallel-"));
  const eventPath = join(dir, "event.json");
  writeFileSync(
    eventPath,
    JSON.stringify({
      issue: { number: 70, pull_request: { url: "https://api.github.com/repos/acme/app/pulls/70" } },
    }),
  );
  const posted = [];
  const io = {
    env: {
      GITHUB_TOKEN: "test-token",
      GITHUB_EVENT_PATH: eventPath,
      GITHUB_REPOSITORY: "acme/app",
      GITHUB_EVENT_NAME: "issue_comment",
    },
    readFile(path) {
      return readFileSync(path, "utf8");
    },
    stderr() {},
    async fetch(url, init) {
      const href = String(url);
      if (href.endsWith("/pulls/70") && (init == null || init.method == null)) {
        return jsonResponse({
          number: 70,
          head: { sha: HEAD },
          base: { sha: OTHER },
        });
      }
      if (href.includes("/issues/70/comments")) {
        return jsonResponse([
          {
            body: marked("PASS", HEAD),
            user: { login: "app-pilote-verifier[bot]", type: "Bot" },
          },
        ]);
      }
      if (href.includes("/pulls/70/commits")) {
        return jsonResponse([
          {
            commit: {
              message: `fix\n\n${AGENT_A}\n`,
              author: { date: "2026-10-30T00:00:00Z" },
            },
          },
          {
            commit: {
              message: `also\n\n${AGENT_B}\n`,
              author: { date: "2026-10-30T00:00:00Z" },
            },
          },
        ]);
      }
      if (href.includes("/actions/") && href.includes("/runs")) {
        return jsonResponse({ workflow_runs: [] });
      }
      if (href.includes(`/statuses/${HEAD}`) && init && init.method === "POST") {
        posted.push(JSON.parse(init.body));
        return jsonResponse({}, 201);
      }
      throw new Error(`unexpected url ${href}`);
    },
  };
  try {
    assert.equal(await main([], io), 0);
    assert.equal(posted.length, 1);
    assert.equal(posted[0].state, "failure");
    assert.match(posted[0].description, /multiple executor identities/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("issue_comment fails closed when the pull commit list is truncated at 250", async () => {
  const dir = mkdtempSync(join(tmpdir(), "anti-parallel-"));
  const eventPath = join(dir, "event.json");
  writeFileSync(
    eventPath,
    JSON.stringify({
      issue: { number: 70, pull_request: { url: "https://api.github.com/repos/acme/app/pulls/70" } },
    }),
  );
  const posted = [];
  const oneAgent = Array.from({ length: 250 }, () => ({
    commit: {
      message: `fix\n\n${AGENT_A}\n`,
      author: { date: "2026-10-30T00:00:00Z" },
    },
  }));
  const io = {
    env: {
      GITHUB_TOKEN: "test-token",
      GITHUB_EVENT_PATH: eventPath,
      GITHUB_REPOSITORY: "acme/app",
      GITHUB_EVENT_NAME: "issue_comment",
    },
    readFile(path) {
      return readFileSync(path, "utf8");
    },
    stderr() {},
    run() {
      return { status: 1, stdout: "" };
    },
    async fetch(url, init) {
      const href = String(url);
      if (href.endsWith("/pulls/70") && (init == null || init.method == null)) {
        return jsonResponse({
          number: 70,
          commits: 251,
          head: { sha: HEAD },
          base: { sha: OTHER },
        });
      }
      if (href.includes("/issues/70/comments")) {
        return jsonResponse([
          {
            body: marked("PASS", HEAD),
            user: { login: "app-pilote-verifier[bot]", type: "Bot" },
          },
        ]);
      }
      if (href.includes("/pulls/70/commits")) {
        return jsonResponse(oneAgent);
      }
      if (href.includes("/actions/") && href.includes("/runs")) {
        return jsonResponse({ workflow_runs: [] });
      }
      if (href.includes(`/statuses/${HEAD}`) && init && init.method === "POST") {
        posted.push(JSON.parse(init.body));
        return jsonResponse({}, 201);
      }
      throw new Error(`unexpected url ${href}`);
    },
  };
  try {
    assert.equal(await main([], io), 0);
    assert.equal(posted.length, 1);
    assert.equal(posted[0].state, "failure");
    assert.match(posted[0].description, /could not read PR commits/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("issue_comment ignores a spoofed marker and keeps a single approved verdict", async () => {
  const dir = mkdtempSync(join(tmpdir(), "anti-parallel-"));
  const eventPath = join(dir, "event.json");
  writeFileSync(
    eventPath,
    JSON.stringify({
      issue: { number: 70, pull_request: { url: "https://api.github.com/repos/acme/app/pulls/70" } },
    }),
  );
  const posted = [];
  const io = {
    env: {
      GITHUB_TOKEN: "test-token",
      GITHUB_EVENT_PATH: eventPath,
      GITHUB_REPOSITORY: "acme/app",
      GITHUB_EVENT_NAME: "issue_comment",
    },
    readFile(path) {
      return readFileSync(path, "utf8");
    },
    stderr() {},
    async fetch(url, init) {
      const href = String(url);
      if (href.endsWith("/pulls/70") && (init == null || init.method == null)) {
        return jsonResponse({
          number: 70,
          head: { sha: HEAD },
          base: { sha: OTHER },
        });
      }
      if (href.includes("/issues/70/comments")) {
        return jsonResponse([
          {
            body: marked("PASS", HEAD),
            user: { login: "app-pilote-verifier[bot]", type: "Bot" },
          },
          {
            body: marked("PASS", HEAD),
            user: { login: "app-pilote-verifier[bot]", type: "User" },
          },
        ]);
      }
      if (href.includes("/pulls/70/commits")) {
        return jsonResponse([
          {
            commit: {
              message: `fix\n\n${AGENT_A}\n`,
              author: { date: "2026-10-30T00:00:00Z" },
            },
          },
        ]);
      }
      if (href.includes("/actions/") && href.includes("/runs")) {
        return jsonResponse({ workflow_runs: [] });
      }
      if (href.includes(`/statuses/${HEAD}`) && init && init.method === "POST") {
        posted.push(JSON.parse(init.body));
        return jsonResponse({}, 201);
      }
      throw new Error(`unexpected url ${href}`);
    },
  };
  try {
    assert.equal(await main([], io), 0);
    assert.equal(posted.length, 1);
    assert.equal(posted[0].state, "success");
    assert.match(posted[0].description, /one verifier/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
