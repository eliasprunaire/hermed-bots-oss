"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdtempSync, readFileSync, writeFileSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const { decide: decideGate, main } = require("../scripts/verdict-gate.js");

const MARKER = "<!-- dev-lead-verifier -->";
const HEAD = "a".repeat(40);
const OTHER = "b".repeat(40);
const GITHUB_SHA = "c".repeat(40);
const API = "https://api.github.com/repos/acme/app-pilote";

function comment(id, createdAtMs, body, login = "cursor[bot]") {
  const row = { id, createdAtMs, body };
  if (login !== null) {
    row.user = { login };
  }
  return row;
}

function decide(input) {
  if (Object.prototype.hasOwnProperty.call(input, "authorLogin")) {
    return decideGate(input);
  }
  return decideGate({ ...input, authorLogin: "eliasprunaire" });
}

function marked(verdict, sha) {
  return `VERDICT: ${verdict} @ ${sha}\n${MARKER}`;
}

function rawComment(id, createdAt, body, updatedAt, user = { login: "cursor[bot]" }) {
  return {
    id,
    created_at: createdAt,
    updated_at: updatedAt,
    body,
    user,
  };
}

function response(status, body, link) {
  const ok = status >= 200 && status < 300;
  return {
    ok,
    status,
    headers: {
      get(name) {
        if (String(name).toLowerCase() === "link") {
          return link ?? null;
        }
        return null;
      },
    },
    json: async () => body,
    text: async () => JSON.stringify(body),
  };
}

function env(overrides = {}) {
  return {
    GITHUB_EVENT_NAME: "issue_comment",
    GITHUB_EVENT_PATH: "/event.json",
    GITHUB_REPOSITORY: "acme/app-pilote",
    GITHUB_TOKEN: "test-token",
    GITHUB_SHA,
    ...overrides,
  };
}

function assertApiHeaders(init) {
  assert.equal(init.headers.Authorization, "Bearer test-token");
  assert.equal(init.headers.Accept, "application/vnd.github+json");
  assert.equal(init.headers["X-GitHub-Api-Version"], "2026-03-10");
  assert.equal(init.headers["User-Agent"], "verdict-gate");
}

function harness({
  eventName = "issue_comment",
  payload,
  pull = {
    number: 7,
    head: { sha: HEAD },
    user: { login: "eliasprunaire" },
  },
  pages,
  postStatus = 201,
}) {
  const posts = [];
  const gets = [];
  const stderr = [];
  const pending = pages.slice();
  const fetch = async (url, init = {}) => {
    const method = init.method ?? "GET";
    if (method === "POST") {
      posts.push({ url, init, body: JSON.parse(init.body) });
      return response(postStatus, {});
    }
    gets.push({ url, init });
    if (url === `${API}/pulls/7`) {
      return response(200, pull);
    }
    const page = pending.shift();
    if (!page || url !== page.url) {
      throw new Error(`unexpected GET ${url}`);
    }
    return response(200, page.comments, page.link);
  };
  const io = {
    env: env({ GITHUB_EVENT_NAME: eventName }),
    readFile: () => JSON.stringify(payload),
    fetch,
    stderr: (line) => {
      stderr.push(line);
    },
    run() {
      return { status: 1, stdout: "" };
    },
  };
  return { io, posts, gets, stderr };
}

test("only decide and main are exported", () => {
  const gate = require("../scripts/verdict-gate.js");
  assert.deepEqual(Object.keys(gate).sort(), ["decide", "main"]);
});

test("the newest qualifying comment wins over an older PASS", () => {
  const decision = decide({
    headSha: HEAD,
    comments: [
      comment("1", 1, marked("PASS", HEAD)),
      comment("2", 2, marked("FAIL", HEAD)),
    ],
  });
  assert.deepEqual(decision, {
    kind: "fail",
    reason: { code: "verdict-fail", headSha: HEAD, commentId: "2" },
    description: `VERDICT FAIL @ ${HEAD}`,
  });
});

test("a later unmarked verdict does not hide the newest qualifying comment", () => {
  const decision = decide({
    headSha: HEAD,
    comments: [
      comment("10", Date.parse("2026-10-15T18:00:00Z"), marked("PASS", HEAD)),
      comment("11", Date.parse("2026-10-15T19:00:00Z"), marked("PASS", OTHER)),
      comment(
        "12",
        Date.parse("2026-10-15T20:00:00Z"),
        `VERDICT: FAIL @ ${HEAD}`,
      ),
    ],
  });
  assert.deepEqual(decision, {
    kind: "fail",
    reason: {
      code: "sha-mismatch",
      verdict: "PASS",
      citedSha: OTHER,
      headSha: HEAD,
      commentId: "11",
    },
    description: `VERDICT PASS @ ${OTHER} does not match head ${HEAD}`,
  });
});

test("equal timestamps pick the greater decimal id past MAX_SAFE_INTEGER", () => {
  const smaller = "9007199254740992";
  const greater = "9007199254740993";
  const createdAtMs = Date.parse("2026-10-15T18:00:00Z");
  const olderId = comment(smaller, createdAtMs, marked("FAIL", HEAD));
  const newerId = comment(greater, createdAtMs, marked("PASS", HEAD));
  for (const comments of [
    [olderId, newerId],
    [newerId, olderId],
  ]) {
    const decision = decide({ headSha: HEAD, comments });
    assert.equal(decision.kind, "pass");
    assert.equal(decision.verdict, "PASS");
    assert.equal(decision.commentId, greater);
    assert.equal(decision.sha, HEAD);
  }
});

test("comment array order does not change the decision", () => {
  const comments = [
    comment("10", 1, marked("PASS", HEAD)),
    comment("11", 2, marked("PASS+NOTES", HEAD)),
    comment("12", 3, `VERDICT: FAIL @ ${HEAD}`),
  ];
  const forward = decide({ headSha: HEAD, comments });
  const reverse = decide({ headSha: HEAD, comments: comments.slice().reverse() });
  assert.deepEqual(forward, reverse);
  assert.equal(forward.kind, "pass");
  assert.equal(forward.verdict, "PASS+NOTES");
  assert.equal(forward.commentId, "11");
});

test("an exact head SHA still passes when matchesHead is false", () => {
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, marked("PASS", HEAD))],
    matchesHead: () => false,
  });
  assert.equal(decision.kind, "pass");
  assert.equal(decision.sha, HEAD);
});

test("two git commits with the same diff share a patch-id so the gate passes", () => {
  const dir = mkdtempSync(join(tmpdir(), "verdict-patch-"));
  const git = (args, input) =>
    spawnSync("git", args, { cwd: dir, encoding: "utf8", input });
  try {
    assert.equal(git(["init", "-q"]).status, 0);
    git(["config", "user.email", "dev@example.com"]);
    git(["config", "user.name", "dev"]);
    writeFileSync(join(dir, "note.txt"), "hello\n");
    git(["add", "note.txt"]);
    assert.equal(git(["commit", "-qm", "first"]).status, 0);
    const sha1 = git(["rev-parse", "HEAD"]).stdout.trim();
    assert.equal(git(["commit", "--amend", "-qm", "second"]).status, 0);
    const sha2 = git(["rev-parse", "HEAD"]).stdout.trim();
    assert.notEqual(sha1, sha2);
    const patchId = (sha) => {
      const shown = git(["show", sha]);
      assert.equal(shown.status, 0);
      const patched = git(["patch-id", "--stable"], shown.stdout);
      assert.equal(patched.status, 0);
      return patched.stdout.trim().split(/\s+/)[0];
    };
    assert.equal(patchId(sha1), patchId(sha2));
    const decision = decide({
      headSha: sha2,
      comments: [comment("1", 1, marked("PASS", sha1))],
      matchesHead: (citedSha, headSha) => patchId(citedSha) === patchId(headSha),
    });
    assert.equal(decision.kind, "pass");
    assert.equal(decision.sha, sha1);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a cited SHA that matchesHead accepts is the same patch as the head", () => {
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, marked("PASS", OTHER))],
    matchesHead: (citedSha, headSha) => citedSha === OTHER && headSha === HEAD,
  });
  assert.deepEqual(decision, {
    kind: "pass",
    verdict: "PASS",
    sha: OTHER,
    commentId: "1",
    description: `VERDICT PASS @ ${OTHER}`,
  });
});

test("a cited SHA that matchesHead rejects still mismatches", () => {
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, marked("PASS", OTHER))],
    matchesHead: () => false,
  });
  assert.equal(decision.kind, "fail");
  assert.equal(decision.reason.code, "sha-mismatch");
});

test("FAIL on a same-patch SHA still fails the gate", () => {
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, marked("FAIL", OTHER))],
    matchesHead: () => true,
  });
  assert.equal(decision.kind, "fail");
  assert.equal(decision.reason.code, "verdict-fail");
  assert.equal(decision.description, `VERDICT FAIL @ ${HEAD}`);
});

test("PASS and PASS+NOTES at the head SHA pass", () => {
  const pass = decide({
    headSha: HEAD,
    comments: [comment("1", 1, marked("PASS", HEAD))],
  });
  const notes = decide({
    headSha: HEAD,
    comments: [comment("2", 2, marked("PASS+NOTES", HEAD))],
  });
  assert.deepEqual(pass, {
    kind: "pass",
    verdict: "PASS",
    sha: HEAD,
    commentId: "1",
    description: `VERDICT PASS @ ${HEAD}`,
  });
  assert.deepEqual(notes, {
    kind: "pass",
    verdict: "PASS+NOTES",
    sha: HEAD,
    commentId: "2",
    description: `VERDICT PASS+NOTES @ ${HEAD}`,
  });
});

test("FAIL at the head SHA fails with the head in the description", () => {
  const decision = decide({
    headSha: HEAD,
    comments: [comment("4", 4, marked("FAIL", HEAD))],
  });
  assert.deepEqual(decision, {
    kind: "fail",
    reason: { code: "verdict-fail", headSha: HEAD, commentId: "4" },
    description: `VERDICT FAIL @ ${HEAD}`,
  });
});

test("a different SHA fails with both SHAs in the description", () => {
  const pass = decide({
    headSha: HEAD,
    comments: [comment("1", 1, marked("PASS", OTHER))],
  });
  const fail = decide({
    headSha: HEAD,
    comments: [comment("2", 2, marked("FAIL", OTHER))],
  });
  assert.equal(
    pass.description,
    `VERDICT PASS @ ${OTHER} does not match head ${HEAD}`,
  );
  assert.equal(pass.reason.code, "sha-mismatch");
  assert.equal(pass.reason.citedSha, OTHER);
  assert.equal(pass.reason.verdict, "PASS");
  assert.equal(fail.reason.code, "sha-mismatch");
  assert.equal(fail.reason.verdict, "FAIL");
  assert.equal(
    fail.description,
    `VERDICT FAIL @ ${OTHER} does not match head ${HEAD}`,
  );
});

test("uppercase hex in the verdict line matches a lowercase head", () => {
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, marked("PASS", HEAD.toUpperCase()))],
  });
  assert.equal(decision.kind, "pass");
  assert.equal(decision.sha, HEAD);
  assert.equal(decision.description, `VERDICT PASS @ ${HEAD}`);
});

test("a short SHA, a mid-sentence verdict, and a trailing space do not qualify", () => {
  const bodies = [
    `VERDICT: PASS @ ${"a".repeat(7)}\n${MARKER}`,
    `Ship VERDICT: PASS @ ${HEAD} now\n${MARKER}`,
    `VERDICT: PASS @ ${HEAD} \n${MARKER}`,
  ];
  for (const body of bodies) {
    const decision = decide({
      headSha: HEAD,
      comments: [comment("1", 1, body)],
    });
    assert.equal(decision.kind, "fail");
    assert.equal(decision.reason.code, "none");
    assert.equal(decision.reason.hint, "marker-without-line");
  }
});

test("a fenced verdict line and a fenced marker do not qualify", () => {
  const sha = HEAD;
  const fenced = [
    "```",
    `VERDICT: PASS @ ${sha}`,
    MARKER,
    "```",
    marked("FAIL", sha),
  ].join("\n");
  const decision = decide({
    headSha: sha,
    comments: [comment("1", 1, fenced)],
  });
  assert.equal(decision.kind, "fail");
  assert.equal(decision.reason.code, "verdict-fail");
});

test("a verdict inside a fence leaves only the outside marker", () => {
  const body = ["```", `VERDICT: PASS @ ${HEAD}`, "```", MARKER].join("\n");
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, body)],
  });
  assert.equal(decision.reason.code, "none");
  assert.equal(decision.reason.hint, "marker-without-line");
});

test("a marker inside a fence leaves only the outside verdict line", () => {
  const body = [`VERDICT: PASS @ ${HEAD}`, "```", MARKER, "```"].join("\n");
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, body)],
  });
  assert.equal(decision.reason.code, "none");
  assert.equal(decision.reason.hint, "line-without-marker");
});

test("a blockquote marker and a blockquote verdict line do not qualify", () => {
  const body = [
    `> VERDICT: PASS @ ${HEAD}`,
    `> ${MARKER}`,
    `VERDICT: PASS @ ${OTHER}`,
  ].join("\n");
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, body)],
  });
  assert.equal(decision.reason.code, "none");
  assert.equal(decision.reason.hint, "neither");
});

test("a verdict continued from a blockquote without a blank line does not qualify", () => {
  const body = [`> quoted context`, `VERDICT: PASS @ ${HEAD}`, MARKER].join("\n");
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, body)],
  });
  assert.equal(decision.reason.code, "none");
  assert.equal(decision.reason.hint, "neither");
});

test("a blank line ends a blockquote so the following verdict counts", () => {
  const body = [`> quoted context`, "", marked("PASS", HEAD)].join("\n");
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, body)],
  });
  assert.equal(decision.kind, "pass");
  assert.equal(decision.verdict, "PASS");
  assert.equal(decision.sha, HEAD);
});

test("a fence opener ends a blockquote and a later verdict still counts", () => {
  const body = [
    "> quoted context",
    "```",
    "quoted sample",
    "```",
    marked("PASS", HEAD),
  ].join("\n");
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, body)],
  });
  assert.equal(decision.kind, "pass");
  assert.equal(decision.verdict, "PASS");
});

test("a marker inside a multiline code span does not count", () => {
  const body = [`VERDICT: PASS @ ${HEAD}`, "`sample starts", MARKER, "`"].join(
    "\n",
  );
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, body)],
  });
  assert.equal(decision.reason.code, "none");
  assert.equal(decision.reason.hint, "line-without-marker");
});

test("a verdict line inside a multiline code span does not count", () => {
  const body = ["`span", `VERDICT: PASS @ ${HEAD}`, "`", MARKER].join("\n");
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, body)],
  });
  assert.equal(decision.reason.code, "none");
  assert.equal(decision.reason.hint, "marker-without-line");
});

test("an unclosed backtick leaves a later marker intact", () => {
  const body = [`VERDICT: PASS @ ${HEAD}`, "`sample starts", MARKER].join("\n");
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, body)],
  });
  assert.equal(decision.kind, "pass");
  assert.equal(decision.verdict, "PASS");
});

test("a verdict and a marker outside a multiline code span still count", () => {
  const body = ["`span", "hidden", "`", marked("PASS", HEAD)].join("\n");
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, body)],
  });
  assert.equal(decision.kind, "pass");
  assert.equal(decision.verdict, "PASS");
});

test("an inline-code marker does not count", () => {
  const body = `VERDICT: PASS @ ${HEAD}\n\`${MARKER}\``;
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, body)],
  });
  assert.equal(decision.reason.code, "none");
  assert.equal(decision.reason.hint, "line-without-marker");
});

test("an indented code marker does not count", () => {
  const body = `VERDICT: PASS @ ${HEAD}\n    ${MARKER}`;
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, body)],
  });
  assert.equal(decision.reason.code, "none");
  assert.equal(decision.reason.hint, "line-without-marker");
});

test("a tilde fence hides the verdict and the real line outside still wins", () => {
  const body = [
    "~~~",
    `VERDICT: FAIL @ ${HEAD}`,
    "~~~",
    marked("PASS", HEAD),
  ].join("\n");
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, body)],
  });
  assert.equal(decision.kind, "pass");
  assert.equal(decision.verdict, "PASS");
});

test("an unclosed fence hides a later verdict line", () => {
  const body = ["```", `VERDICT: PASS @ ${HEAD}`, MARKER].join("\n");
  const decision = decide({
    headSha: HEAD,
    comments: [comment("1", 1, body)],
  });
  assert.equal(decision.reason.code, "none");
  assert.equal(decision.reason.hint, "neither");
});

test("conflicting lines on the newest marked comment do not fall through", () => {
  const decision = decide({
    headSha: HEAD,
    comments: [
      comment("1", 1, marked("PASS", HEAD)),
      comment(
        "2",
        2,
        `VERDICT: PASS @ ${HEAD}\nVERDICT: FAIL @ ${HEAD}\n${MARKER}`,
      ),
    ],
  });
  assert.deepEqual(decision, {
    kind: "fail",
    reason: { code: "conflicting-lines", headSha: HEAD, commentId: "2" },
    description: "latest marked comment has conflicting VERDICT lines",
  });
});

test("two identical verdict lines count as one verdict", () => {
  const decision = decide({
    headSha: HEAD,
    comments: [
      comment("7", 7, `VERDICT: PASS @ ${HEAD}\nVERDICT: PASS @ ${HEAD}\n${MARKER}`),
    ],
  });
  assert.deepEqual(decision, {
    kind: "pass",
    verdict: "PASS",
    sha: HEAD,
    commentId: "7",
    description: `VERDICT PASS @ ${HEAD}`,
  });
});

test("marker alone, a verdict line alone, and an empty list are the three none results", () => {
  const markerOnly = decide({
    headSha: HEAD,
    comments: [comment("1", 1, `look here\n${MARKER}`)],
  });
  const lineOnly = decide({
    headSha: HEAD,
    comments: [comment("2", 2, `VERDICT: PASS @ ${HEAD}`)],
  });
  const empty = decide({ headSha: HEAD, comments: [] });
  assert.deepEqual(markerOnly, {
    kind: "fail",
    reason: { code: "none", headSha: HEAD, hint: "marker-without-line" },
    description: `marker present but no VERDICT line for ${HEAD}`,
  });
  assert.deepEqual(lineOnly, {
    kind: "fail",
    reason: { code: "none", headSha: HEAD, hint: "line-without-marker" },
    description: `VERDICT line missing ${MARKER} for ${HEAD}`,
  });
  assert.deepEqual(empty, {
    kind: "fail",
    reason: { code: "none", headSha: HEAD, hint: "neither" },
    description: `no marked VERDICT for ${HEAD}`,
  });
});

test("every description is at most 140 characters", () => {
  const notesOnOther = decide({
    headSha: HEAD,
    comments: [comment("1", 1, marked("PASS+NOTES", OTHER))],
  });
  const cases = [
    notesOnOther,
    decide({ headSha: HEAD, comments: [] }),
    decide({
      headSha: HEAD,
      comments: [comment("2", 2, `VERDICT: PASS @ ${HEAD}`)],
    }),
    decide({
      headSha: HEAD,
      comments: [comment("3", 3, MARKER)],
    }),
    decide({
      headSha: HEAD,
      comments: [comment("4", 4, marked("FAIL", HEAD))],
    }),
    decide({
      headSha: HEAD,
      comments: [
        comment("5", 5, `VERDICT: PASS @ ${HEAD}\nVERDICT: PASS @ ${OTHER}\n${MARKER}`),
      ],
    }),
    decide({
      headSha: HEAD,
      comments: [comment("6", 6, marked("PASS", HEAD))],
    }),
  ];
  assert.equal(
    notesOnOther.description,
    `VERDICT PASS+NOTES @ ${OTHER} does not match head ${HEAD}`,
  );
  for (const decision of cases) {
    assert.ok(decision.description.length <= 140);
    assert.equal(decision.description.length > 0, true);
  }
});

test("issue_comment posts verdict-gate on the pull head and never on GITHUB_SHA", async () => {
  const { io, posts, gets, stderr } = harness({
    payload: {
      action: "created",
      issue: { number: 7, pull_request: { url: `${API}/pulls/7` } },
    },
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        comments: [
          rawComment(10, "2026-10-15T18:00:00Z", marked("PASS", HEAD)),
        ],
      },
    ],
  });
  const code = await main([], io);
  assert.equal(code, 0);
  assert.equal(posts.length, 1);
  assert.equal(posts[0].url, `${API}/statuses/${HEAD}`);
  assert.equal(posts[0].url.includes(GITHUB_SHA), false);
  assert.deepEqual(posts[0].body, {
    state: "success",
    context: "verdict-gate",
    description: `VERDICT PASS @ ${HEAD}`,
  });
  assert.equal(gets[0].url, `${API}/pulls/7`);
  assert.deepEqual(stderr, [`VERDICT PASS @ ${HEAD}`]);
  assert.equal(stderr.some((line) => line.includes("test-token")), false);
  for (const call of [...gets, ...posts]) {
    assertApiHeaders(call.init);
  }
});

test("a failing predicate returns 0 and posts failure", async () => {
  const { io, posts, stderr } = harness({
    payload: {
      action: "created",
      issue: { number: 7, pull_request: {} },
    },
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        comments: [
          rawComment(
            1,
            "2026-10-15T18:00:00Z",
            marked("PASS", HEAD),
            "2026-10-15T23:00:00Z",
          ),
          rawComment(
            2,
            "2026-10-15T20:00:00Z",
            marked("FAIL", HEAD),
            "2026-10-15T20:00:00Z",
          ),
        ],
      },
    ],
  });
  const code = await main([], io);
  assert.equal(code, 0);
  assert.equal(posts.length, 1);
  assert.deepEqual(posts[0].body, {
    state: "failure",
    context: "verdict-gate",
    description: `VERDICT FAIL @ ${HEAD}`,
  });
  assert.deepEqual(stderr, [`VERDICT FAIL @ ${HEAD}`]);
});

test("a non-pull-request issue comment returns 0 and does not fetch", async () => {
  let fetched = false;
  const code = await main([], {
    env: env(),
    readFile: () =>
      JSON.stringify({
        action: "created",
        issue: { number: 3 },
      }),
    fetch: async () => {
      fetched = true;
      throw new Error("fetch");
    },
    stderr: () => {},
  });
  assert.equal(code, 0);
  assert.equal(fetched, false);
});

test("a qualifying comment on the second page counts", async () => {
  const page2 = `${API}/issues/7/comments?per_page=100&page=2`;
  const { io, posts, gets } = harness({
    payload: {
      action: "created",
      issue: { number: 7, pull_request: {} },
    },
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        link: `<${page2}>; rel="next"`,
        comments: [rawComment(1, "2026-10-15T18:00:00Z", "no verdict")],
      },
      {
        url: page2,
        comments: [rawComment(2, "2026-10-15T19:00:00Z", marked("PASS", HEAD))],
      },
    ],
  });
  const code = await main([], io);
  assert.equal(code, 0);
  assert.deepEqual(
    gets.map((call) => call.url),
    [`${API}/pulls/7`, `${API}/issues/7/comments?per_page=100`, page2],
  );
  assert.equal(posts[0].body.state, "success");
  assert.equal(posts[0].body.description, `VERDICT PASS @ ${HEAD}`);
});

test("pull_request uses head.sha and ignores merge_commit_sha", async () => {
  const { io, posts, gets } = harness({
    eventName: "pull_request",
    payload: {
      action: "synchronize",
      pull_request: {
        number: 7,
        head: { sha: HEAD },
        merge_commit_sha: OTHER,
        user: { login: "eliasprunaire" },
      },
    },
    pull: { number: 7, head: { sha: GITHUB_SHA } },
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        comments: [rawComment(1, "2026-10-15T18:00:00Z", marked("PASS", HEAD))],
      },
    ],
  });
  const code = await main([], io);
  assert.equal(code, 0);
  assert.equal(
    gets.some((call) => call.url.includes("/pulls/")),
    false,
  );
  assert.equal(posts[0].url, `${API}/statuses/${HEAD}`);
  assert.equal(posts[0].body.state, "success");
});

test("a non-201 status POST returns 1", async () => {
  const { io, posts, stderr } = harness({
    payload: {
      action: "created",
      issue: { number: 7, pull_request: {} },
    },
    postStatus: 200,
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        comments: [rawComment(1, "2026-10-15T18:00:00Z", marked("PASS", HEAD))],
      },
    ],
  });
  const code = await main([], io);
  assert.equal(code, 1);
  assert.equal(posts.length, 1);
  assert.deepEqual(stderr, []);
});

test("non-empty argv prints usage and returns 1", async () => {
  const stderr = [];
  let fetched = false;
  const code = await main(["--sha"], {
    env: env(),
    readFile: () => {
      throw new Error("read");
    },
    fetch: async () => {
      fetched = true;
      throw new Error("fetch");
    },
    stderr: (line) => {
      stderr.push(line);
    },
  });
  assert.equal(code, 1);
  assert.deepEqual(stderr, ["usage: verdict-gate.js"]);
  assert.equal(fetched, false);
});

test("a failed comment GET is retried once and the second failure is unreadable", async () => {
  const stderr = [];
  const posts = [];
  const commentUrls = [];
  let commentAttempts = 0;
  const code = await main([], {
    env: env(),
    readFile: () =>
      JSON.stringify({
        action: "created",
        issue: { number: 7, pull_request: {} },
      }),
    fetch: async (url, init = {}) => {
      const method = init.method ?? "GET";
      if (method === "POST") {
        posts.push({ url, body: JSON.parse(init.body) });
        return response(201, {});
      }
      if (url === `${API}/pulls/7`) {
        return response(200, { number: 7, head: { sha: HEAD } });
      }
      commentAttempts += 1;
      commentUrls.push(url);
      if (commentAttempts === 1) {
        throw new Error("socket hang up");
      }
      return response(503, { message: "unavailable" });
    },
    stderr: (line) => {
      stderr.push(line);
    },
  });
  assert.equal(commentAttempts, 2);
  assert.deepEqual(commentUrls, [
    `${API}/issues/7/comments?per_page=100`,
    `${API}/issues/7/comments?per_page=100`,
  ]);
  assert.equal(code, 0);
  assert.equal(posts.length, 1);
  assert.equal(posts[0].url, `${API}/statuses/${HEAD}`);
  assert.deepEqual(posts[0].body, {
    state: "failure",
    context: "verdict-gate",
    description: "could not read PR comments",
  });
  assert.deepEqual(stderr, ["could not read PR comments"]);
  assert.equal(stderr.some((line) => line.includes("test-token")), false);
});

test("a failed comment GET succeeds on the second try", async () => {
  const stderr = [];
  const posts = [];
  let commentAttempts = 0;
  const code = await main([], {
    env: env(),
    readFile: () =>
      JSON.stringify({
        action: "created",
        issue: { number: 7, pull_request: {} },
      }),
    fetch: async (url, init = {}) => {
      const method = init.method ?? "GET";
      if (method === "POST") {
        posts.push({ url, body: JSON.parse(init.body) });
        return response(201, {});
      }
      if (url === `${API}/pulls/7`) {
        return response(200, {
          number: 7,
          head: { sha: HEAD },
          user: { login: "eliasprunaire" },
        });
      }
      commentAttempts += 1;
      if (commentAttempts === 1) {
        throw new Error("socket hang up");
      }
      return response(200, [
        rawComment(1, "2026-10-15T18:00:00Z", marked("PASS", HEAD)),
      ]);
    },
    stderr: (line) => {
      stderr.push(line);
    },
  });
  assert.equal(commentAttempts, 2);
  assert.equal(code, 0);
  assert.equal(posts[0].body.state, "success");
  assert.deepEqual(stderr, [`VERDICT PASS @ ${HEAD}`]);
});

test("the workflow records a status from record-verdict", () => {
  const yaml = readFileSync(
    join(__dirname, "..", ".github/workflows/verdict-gate.yml"),
    "utf8",
  );
  const jobAt = yaml.indexOf("\n  record-verdict:\n");
  assert.notEqual(jobAt, -1);
  const job = yaml.slice(jobAt);
  const prelude = yaml.slice(0, jobAt);
  assert.match(yaml, /^jobs:\n {2}record-verdict:\n/m);
  assert.equal(/^ {2}verdict-gate:\n/m.test(job), false);
  assert.match(job, /statuses:\s*write/);
  assert.equal(job.includes("issues: read"), false);
  assert.match(yaml, /cancel-in-progress:\s*false/);
  assert.equal(yaml.includes("cancel-in-progress: true"), false);
  assert.equal(yaml.includes("checks: write"), false);
  assert.equal(yaml.includes("contents: write"), false);
  assert.equal(yaml.includes("pull-requests: write"), false);
  assert.equal(yaml.includes("npm ci"), false);
  assert.match(prelude, /contents:\s*read/);
  assert.match(prelude, /pull-requests:\s*read/);
  assert.equal(prelude.includes("statuses:"), false);
  assert.match(job, /node scripts\/verdict-gate\.js/);
  assert.match(job, /fetch-depth:\s*0/);
});

test("main posts success when git patch-id of the cited SHA matches the head", async () => {
  const dir = mkdtempSync(join(tmpdir(), "verdict-gate-git-"));
  const git = (args, input) =>
    spawnSync("git", args, { cwd: dir, encoding: "utf8", input });
  try {
    assert.equal(git(["init", "-q"]).status, 0);
    git(["config", "user.email", "dev@example.com"]);
    git(["config", "user.name", "dev"]);
    writeFileSync(join(dir, "note.txt"), "base\n");
    git(["add", "note.txt"]);
    assert.equal(git(["commit", "-qm", "base"]).status, 0);
    writeFileSync(join(dir, "note.txt"), "hello\n");
    git(["add", "note.txt"]);
    assert.equal(git(["commit", "-qm", "feature"]).status, 0);
    const sha1 = git(["rev-parse", "HEAD"]).stdout.trim();
    assert.equal(git(["reset", "--soft", "HEAD~1"]).status, 0);
    assert.equal(git(["commit", "-qm", "replay"]).status, 0);
    const sha2 = git(["rev-parse", "HEAD"]).stdout.trim();
    assert.notEqual(sha1, sha2);
    const posts = [];
    const stderr = [];
    const code = await main([], {
      env: env({ GITHUB_EVENT_NAME: "pull_request" }),
      readFile: () =>
        JSON.stringify({
          action: "synchronize",
          pull_request: {
            number: 7,
            head: { sha: sha2 },
            user: { login: "eliasprunaire" },
          },
        }),
      fetch: async (url, init = {}) => {
        const method = init.method ?? "GET";
        if (method === "POST") {
          posts.push({ url, body: JSON.parse(init.body) });
          return response(201, {});
        }
        if (url === `${API}/issues/7/comments?per_page=100`) {
          return response(200, [
            rawComment(1, "2026-10-15T18:00:00Z", marked("PASS", sha1)),
          ]);
        }
        throw new Error(`unexpected GET ${url}`);
      },
      stderr: (line) => {
        stderr.push(line);
      },
      run(command, args, stdin) {
        return spawnSync(command, args, {
          cwd: dir,
          encoding: "utf8",
          input: stdin,
          maxBuffer: 32 * 1024 * 1024,
        });
      },
    });
    assert.equal(code, 0);
    assert.equal(posts[0].url, `${API}/statuses/${sha2}`);
    assert.deepEqual(posts[0].body, {
      state: "success",
      context: "verdict-gate",
      description: `VERDICT PASS @ ${sha1}`,
    });
    assert.deepEqual(stderr, [`VERDICT PASS @ ${sha1}`]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a missing cited SHA has an empty patch-id and does not match the head", async () => {
  const dir = mkdtempSync(join(tmpdir(), "verdict-gate-empty-"));
  const git = (args, input) =>
    spawnSync("git", args, { cwd: dir, encoding: "utf8", input });
  const missing = "d".repeat(40);
  try {
    assert.equal(git(["init", "-q"]).status, 0);
    git(["config", "user.email", "dev@example.com"]);
    git(["config", "user.name", "dev"]);
    writeFileSync(join(dir, "note.txt"), "hello\n");
    git(["add", "note.txt"]);
    assert.equal(git(["commit", "-qm", "only"]).status, 0);
    const head = git(["rev-parse", "HEAD"]).stdout.trim();
    const posts = [];
    const code = await main([], {
      env: env({ GITHUB_EVENT_NAME: "pull_request" }),
      readFile: () =>
        JSON.stringify({
          action: "synchronize",
          pull_request: { number: 7, head: { sha: head } },
        }),
      fetch: async (url, init = {}) => {
        const method = init.method ?? "GET";
        if (method === "POST") {
          posts.push({ body: JSON.parse(init.body) });
          return response(201, {});
        }
        if (url === `${API}/issues/7/comments?per_page=100`) {
          return response(200, [
            rawComment(1, "2026-10-15T18:00:00Z", marked("PASS", missing)),
          ]);
        }
        throw new Error(`unexpected GET ${url}`);
      },
      stderr: () => {},
      run(command, args, stdin) {
        return spawnSync(command, args, {
          cwd: dir,
          encoding: "utf8",
          input: stdin,
          maxBuffer: 32 * 1024 * 1024,
        });
      },
    });
    assert.equal(code, 0);
    assert.equal(posts.length, 1);
    assert.equal(posts[0].body.state, "failure");
    assert.equal(
      posts[0].body.description,
      `VERDICT PASS @ ${missing} does not match head ${head}`,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a marked PASS from the pull request author fails", () => {
  const decision = decide({
    headSha: HEAD,
    authorLogin: "eliasprunaire",
    comments: [comment("1", 1, marked("PASS", HEAD), "eliasprunaire")],
  });
  assert.deepEqual(decision, {
    kind: "fail",
    reason: {
      code: "author-match",
      headSha: HEAD,
      commentId: "1",
      authorLogin: "eliasprunaire",
    },
    description: "author eliasprunaire wrote the marked VERDICT",
  });
});

test("a marked PASS from a different login still passes", () => {
  const decision = decide({
    headSha: HEAD,
    authorLogin: "eliasprunaire",
    comments: [comment("1", 1, marked("PASS", HEAD), "ada")],
  });
  assert.deepEqual(decision, {
    kind: "pass",
    verdict: "PASS",
    sha: HEAD,
    commentId: "1",
    description: `VERDICT PASS @ ${HEAD}`,
  });
});

test("a matching verdict with no comment login fails closed", () => {
  const comments = [
    comment("1", 1, marked("PASS", HEAD), null),
    { id: "2", createdAtMs: 2, body: marked("PASS", HEAD), user: { login: "" } },
    { id: "3", createdAtMs: 3, body: marked("PASS", HEAD), user: {} },
  ];
  for (const entry of comments) {
    const decision = decideGate({
      headSha: HEAD,
      authorLogin: "eliasprunaire",
      comments: [entry],
    });
    assert.deepEqual(decision, {
      kind: "fail",
      reason: {
        code: "missing-login",
        headSha: HEAD,
        commentId: entry.id,
        side: "comment",
      },
      description: "marked comment has no login",
    });
  }
});

test("a matching verdict with no pull author login fails closed", () => {
  const withNull = decide({
    headSha: HEAD,
    authorLogin: null,
    comments: [comment("1", 1, marked("PASS", HEAD), "ada")],
  });
  const omitted = decideGate({
    headSha: HEAD,
    comments: [comment("2", 2, marked("PASS", HEAD), "ada")],
  });
  for (const decision of [withNull, omitted]) {
    assert.equal(decision.kind, "fail");
    assert.equal(decision.reason.code, "missing-login");
    assert.equal(decision.reason.side, "pull");
    assert.equal(decision.description, "pull request has no author login");
  }
});

test("author login match is case insensitive", () => {
  const decision = decide({
    headSha: HEAD,
    authorLogin: "eliasprunaire",
    comments: [comment("1", 1, marked("PASS+NOTES", HEAD), "EliasPrunaire")],
  });
  assert.deepEqual(decision, {
    kind: "fail",
    reason: {
      code: "author-match",
      headSha: HEAD,
      commentId: "1",
      authorLogin: "eliasprunaire",
    },
    description: "author eliasprunaire wrote the marked VERDICT",
  });
});

test("issue_comment fails when the comment login matches the pull author", async () => {
  const { io, posts } = harness({
    payload: {
      action: "created",
      issue: { number: 7, pull_request: {} },
    },
    pull: {
      number: 7,
      head: { sha: HEAD },
      user: { login: "eliasprunaire" },
    },
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        comments: [
          rawComment(
            1,
            "2026-10-15T18:00:00Z",
            marked("PASS", HEAD),
            undefined,
            { login: "eliasprunaire" },
          ),
        ],
      },
    ],
  });
  const code = await main([], io);
  assert.equal(code, 0);
  assert.equal(posts.length, 1);
  assert.equal(posts[0].body.state, "failure");
  assert.equal(posts[0].body.context, "verdict-gate");
  assert.equal(
    posts[0].body.description,
    "author eliasprunaire wrote the marked VERDICT",
  );
});

test("pull_request reads the author from the event payload", async () => {
  const { io, posts, gets } = harness({
    eventName: "pull_request",
    payload: {
      action: "synchronize",
      pull_request: {
        number: 7,
        head: { sha: HEAD },
        user: { login: "EliasPrunaire" },
      },
    },
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        comments: [
          rawComment(
            1,
            "2026-10-15T18:00:00Z",
            marked("PASS", HEAD),
            undefined,
            { login: "eliasprunaire" },
          ),
        ],
      },
    ],
  });
  const code = await main([], io);
  assert.equal(code, 0);
  assert.equal(gets.some((call) => call.url.includes("/pulls/")), false);
  assert.equal(posts[0].body.state, "failure");
  assert.equal(
    posts[0].body.description,
    "author eliasprunaire wrote the marked VERDICT",
  );
});

test("issue_comment fails closed when the comment or the pull has no login", async () => {
  const missingComment = harness({
    payload: {
      action: "created",
      issue: { number: 7, pull_request: {} },
    },
    pull: {
      number: 7,
      head: { sha: HEAD },
      user: { login: "eliasprunaire" },
    },
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        comments: [
          { id: 1, created_at: "2026-10-15T18:00:00Z", body: marked("PASS", HEAD) },
        ],
      },
    ],
  });
  assert.equal(await main([], missingComment.io), 0);
  assert.equal(missingComment.posts[0].body.state, "failure");
  assert.equal(
    missingComment.posts[0].body.description,
    "marked comment has no login",
  );

  const missingAuthor = harness({
    payload: {
      action: "created",
      issue: { number: 7, pull_request: {} },
    },
    pull: { number: 7, head: { sha: HEAD } },
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        comments: [rawComment(1, "2026-10-15T18:00:00Z", marked("PASS", HEAD))],
      },
    ],
  });
  assert.equal(await main([], missingAuthor.io), 0);
  assert.equal(
    missingAuthor.posts[0].body.description,
    "pull request has no author login",
  );
});
