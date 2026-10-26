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
const VERIFIER = "app-pilote-verifier[bot]";
const REAL_USER = { login: VERIFIER, type: "Bot" };

function comment(id, createdAtMs, body, user = REAL_USER) {
  const row = { id, createdAtMs, body };
  if (user !== null) {
    row.user = user;
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

function rawComment(id, createdAt, body, updatedAt, user = REAL_USER) {
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

function historyPayload({ commits = [], force = [] }) {
  return {
    data: {
      repository: {
        pullRequest: {
          commits: {
            pageInfo: { hasNextPage: false },
            nodes: commits.map((sha) => ({ commit: { oid: sha } })),
          },
          timelineItems: {
            pageInfo: { hasNextPage: false },
            nodes: force.map(([before, after]) => ({
              beforeCommit: { oid: before },
              afterCommit: { oid: after },
            })),
          },
        },
      },
    },
  };
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
  verifiers,
  routes = {},
}) {
  const posts = [];
  const gets = [];
  const stderr = [];
  const pending = pages.slice();
  const fetch = async (url, init = {}) => {
    const method = init.method ?? "GET";
    if (method === "POST" && url === "https://api.github.com/graphql") {
      gets.push({ url, init });
      if (!Object.prototype.hasOwnProperty.call(routes, "graphql")) {
        throw new Error("unexpected GRAPHQL");
      }
      return response(200, routes.graphql);
    }
    if (method === "POST") {
      posts.push({ url, init, body: JSON.parse(init.body) });
      return response(postStatus, {});
    }
    gets.push({ url, init });
    if (url === `${API}/pulls/7`) {
      return response(200, pull);
    }
    if (url === `${API}/pulls/7/commits?per_page=100`) {
      if (!Object.prototype.hasOwnProperty.call(routes, "commits")) {
        throw new Error(`unexpected GET ${url}`);
      }
      return response(200, routes.commits);
    }
    if (url === `${API}/issues/7/timeline?per_page=100`) {
      if (!Object.prototype.hasOwnProperty.call(routes, "timeline")) {
        throw new Error(`unexpected GET ${url}`);
      }
      return response(200, routes.timeline);
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
  };
  if (verifiers !== undefined) {
    io.verifiers = verifiers;
  }
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
    kind: "pass",
    verdict: "PASS",
    sha: HEAD,
    commentId: "10",
    description: `VERDICT PASS @ ${HEAD}`,
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

test("matchesHead and a patch-id in the comment body do not make a foreign SHA match", () => {
  const pid = "d".repeat(40);
  for (const verdict of ["PASS", "PASS+NOTES", "FAIL"]) {
    const decision = decide({
      headSha: HEAD,
      comments: [
        comment(
          "1",
          1,
          `${marked(verdict, OTHER)}\npid ${pid}\nmatchesHead true`,
        ),
      ],
      matchesHead: () => true,
      headPatchId: pid,
    });
    assert.deepEqual(decision, {
      kind: "fail",
      reason: {
        code: "sha-mismatch",
        verdict,
        citedSha: OTHER,
        headSha: HEAD,
        commentId: "1",
      },
      description: `VERDICT ${verdict} @ ${OTHER} does not match head ${HEAD}`,
    });
  }
});

test("a SHA that is a prefix of the head does not qualify", () => {
  for (const cited of [HEAD.slice(0, 7), HEAD.slice(0, 39)]) {
    const decision = decide({
      headSha: HEAD,
      comments: [comment("1", 1, `VERDICT: PASS @ ${cited}\n${MARKER}`)],
    });
    assert.equal(decision.kind, "fail");
    assert.equal(decision.reason.code, "none");
  }
});

test("git is invoked only through io.run as git argv, never from comment text", () => {
  const source = readFileSync(
    join(__dirname, "..", "scripts/verdict-gate.js"),
    "utf8",
  );
  assert.equal(source.includes("io.run([\"git\""), true);
  assert.equal(source.includes("patch-id"), true);
  assert.equal(source.includes("comment.patchId"), false);
  assert.equal(source.includes("PATCH_ID"), false);
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
  const viaPatch = decide({
    headSha: HEAD,
    headPatchId: "d".repeat(40),
    headExactId: "c".repeat(40),
    headReplayId: TID,
    onPull: [OTHER],
    patchIds: { [OTHER]: "d".repeat(40) },
    exactIds: { [OTHER]: "c".repeat(40) },
    replayIds: { [OTHER]: TID },
    comments: [comment("9", 9, marked("PASS+NOTES", OTHER))],
  });
  const cases = [
    notesOnOther,
    viaPatch,
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
  assert.equal(
    viaPatch.description,
    `VERDICT PASS+NOTES @ ${OTHER} pid ${"d".repeat(40)}`,
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
  assert.match(job, /node "\$checker"/);
  assert.equal(job.includes("node scripts/verdict-gate.js"), false);
  assert.match(job, /git show "\$BASE_SHA:scripts\/verdict-gate\.js"/);
  assert.match(job, /fetch-depth:\s*0/);
  assert.match(job, /persist-credentials:\s*false/);
  assert.equal(yaml.includes("pull_request_target"), false);
});

function initGitDir() {
  const dir = mkdtempSync(join(tmpdir(), "verdict-gate-git-"));
  const git = (args, input) =>
    spawnSync("git", args, { cwd: dir, encoding: "utf8", input });
  assert.equal(git(["init", "-q"]).status, 0);
  git(["config", "user.email", "dev@example.com"]);
  git(["config", "user.name", "dev"]);
  return { dir, git };
}

function patchIdAgainst(git, sha, base, flag = "--stable") {
  const mergeBase = git(["merge-base", sha, base]).stdout.trim();
  const diff = git(["diff", "--no-ext-diff", "--binary", mergeBase, sha]);
  return git(["patch-id", flag], diff.stdout).stdout.trim().split(/\s+/)[0];
}

function attachGit(io, dir) {
  io.run = (argv, input) => {
    assert.equal(argv[0], "git");
    const result = spawnSync("git", argv.slice(1), {
      cwd: dir,
      encoding: "utf8",
      input,
    });
    return { status: result.status ?? 1, stdout: result.stdout || "" };
  };
}

function featureRepo() {
  const { dir, git } = initGitDir();
  writeFileSync(join(dir, "note.txt"), "base\n");
  git(["add", "note.txt"]);
  assert.equal(git(["commit", "-qm", "base"]).status, 0);
  const baseSha = git(["rev-parse", "HEAD"]).stdout.trim();
  writeFileSync(join(dir, "note.txt"), "hello\n");
  git(["add", "note.txt"]);
  assert.equal(git(["commit", "-qm", "feature"]).status, 0);
  const sha1 = git(["rev-parse", "HEAD"]).stdout.trim();
  assert.equal(git(["reset", "--soft", "HEAD~1"]).status, 0);
  assert.equal(git(["commit", "-qm", "replay"]).status, 0);
  const sha2 = git(["rev-parse", "HEAD"]).stdout.trim();
  assert.notEqual(sha1, sha2);
  const patchId = patchIdAgainst(git, sha1, baseSha);
  assert.equal(patchId, patchIdAgainst(git, sha2, baseSha));
  assert.equal(patchId.length, 40);
  assert.equal(
    patchIdAgainst(git, sha1, baseSha, "--verbatim"),
    patchIdAgainst(git, sha2, baseSha, "--verbatim"),
  );
  return { dir, git, baseSha, sha1, sha2, patchId };
}

async function gateOnReplay({
  dir,
  baseSha,
  sha1,
  sha2,
  body,
  commits,
  force,
  timeline = [],
  extraComments = [],
}) {
  const { io, posts, stderr } = harness({
    eventName: "pull_request",
    payload: {
      action: "synchronize",
      pull_request: {
        number: 7,
        head: { sha: sha2 },
        base: { sha: baseSha },
        user: { login: "eliasprunaire" },
      },
    },
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        comments: [
          rawComment(1, "2026-10-15T18:00:00Z", body),
          ...extraComments,
        ],
      },
    ],
    routes: {
      commits: commits.map((sha) => ({ sha })),
      timeline: [
        ...force.map(([before, after]) => ({
          event: "head_ref_force_pushed",
          commit_id: after,
          before,
        })),
        ...timeline,
      ],
      graphql: historyPayload({ commits, force }),
    },
  });
  attachGit(io, dir);
  const code = await main([], io);
  return { code, posts, stderr };
}

const AUTHOR = { login: "eliasprunaire", type: "User" };
const PID = "e".repeat(40);
const XID = "a".repeat(40);
const TID = "9".repeat(40);

test("a clean rebase PASS with the same patch-id passes and names origin sha and patch-id", () => {
  const decision = decide({
    headSha: HEAD,
    headPatchId: PID,
    headExactId: XID,
    headReplayId: TID,
    onPull: [OTHER, HEAD],
    patchIds: { [OTHER]: PID },
    exactIds: { [OTHER]: XID },
    replayIds: { [OTHER]: TID },
    comments: [comment("1", 1, marked("PASS+NOTES", OTHER))],
  });
  assert.deepEqual(decision, {
    kind: "pass",
    verdict: "PASS+NOTES",
    sha: OTHER,
    commentId: "1",
    description: `VERDICT PASS+NOTES @ ${OTHER} pid ${PID}`,
  });
  assert.ok(decision.description.length <= 140);
});

test("a modified diff with a different patch-id is refused", () => {
  const decision = decide({
    headSha: HEAD,
    headPatchId: PID,
    headExactId: XID,
    headReplayId: TID,
    onPull: [OTHER, HEAD],
    patchIds: { [OTHER]: "f".repeat(40) },
    exactIds: { [OTHER]: XID },
    replayIds: { [OTHER]: TID },
    comments: [comment("1", 1, marked("PASS", OTHER))],
  });
  assert.equal(decision.kind, "fail");
  assert.equal(decision.reason.code, "sha-mismatch");
  assert.equal(
    decision.description,
    `VERDICT PASS @ ${OTHER} does not match head ${HEAD}`,
  );
});

test("the same patch-id with a different verbatim id is refused", () => {
  const decision = decide({
    headSha: HEAD,
    headPatchId: PID,
    headExactId: XID,
    headReplayId: TID,
    onPull: [OTHER, HEAD],
    patchIds: { [OTHER]: PID },
    exactIds: { [OTHER]: "b".repeat(40) },
    replayIds: { [OTHER]: TID },
    comments: [comment("1", 1, marked("PASS", OTHER))],
  });
  assert.equal(decision.kind, "fail");
  assert.equal(decision.reason.code, "sha-mismatch");
  assert.equal(
    decision.description,
    `VERDICT PASS @ ${OTHER} does not match head ${HEAD}`,
  );
});

test("a missing verbatim id on either side is refused", () => {
  const stableOnly = {
    headSha: HEAD,
    headPatchId: PID,
    onPull: [OTHER, HEAD],
    patchIds: { [OTHER]: PID },
    comments: [comment("1", 1, marked("PASS", OTHER))],
  };
  assert.equal(decide(stableOnly).kind, "fail");
  assert.equal(decide({ ...stableOnly, headExactId: XID }).kind, "fail");
  assert.equal(decide({ ...stableOnly, exactIds: { [OTHER]: XID } }).kind, "fail");
});

test("the same patch-ids with a different replay tree are refused", () => {
  const decision = decide({
    headSha: HEAD,
    headPatchId: PID,
    headExactId: XID,
    headReplayId: TID,
    onPull: [OTHER, HEAD],
    patchIds: { [OTHER]: PID },
    exactIds: { [OTHER]: XID },
    replayIds: { [OTHER]: "8".repeat(40) },
    comments: [comment("1", 1, marked("PASS", OTHER))],
  });
  assert.equal(decision.kind, "fail");
  assert.equal(decision.reason.code, "sha-mismatch");
  assert.equal(
    decision.description,
    `VERDICT PASS @ ${OTHER} does not match head ${HEAD}`,
  );
});

test("a missing replay tree on either side is refused", () => {
  const noReplay = {
    headSha: HEAD,
    headPatchId: PID,
    headExactId: XID,
    onPull: [OTHER, HEAD],
    patchIds: { [OTHER]: PID },
    exactIds: { [OTHER]: XID },
    comments: [comment("1", 1, marked("PASS", OTHER))],
  };
  assert.equal(decide(noReplay).kind, "fail");
  assert.equal(decide({ ...noReplay, headReplayId: TID }).kind, "fail");
  assert.equal(decide({ ...noReplay, replayIds: { [OTHER]: TID } }).kind, "fail");
  assert.equal(
    decide({ ...noReplay, headReplayId: TID, replayIds: { [OTHER]: TID } }).kind,
    "pass",
  );
});

test("author verdict is refused even with a matching patch-id", () => {
  const decision = decide({
    headSha: HEAD,
    authorLogin: "eliasprunaire",
    verifiers: [AUTHOR],
    headPatchId: PID,
    headExactId: XID,
    headReplayId: TID,
    onPull: [OTHER],
    patchIds: { [OTHER]: PID },
    exactIds: { [OTHER]: XID },
    replayIds: { [OTHER]: TID },
    comments: [comment("1", 1, marked("PASS", OTHER), AUTHOR)],
  });
  assert.equal(decision.reason.code, "author-match");
  assert.equal(decision.description, "author eliasprunaire wrote the marked VERDICT");
});

test("a SHA that is not on the pull is refused even with the same patch-id", () => {
  const decision = decide({
    headSha: HEAD,
    headPatchId: PID,
    headExactId: XID,
    headReplayId: TID,
    onPull: [HEAD],
    patchIds: { [OTHER]: PID },
    exactIds: { [OTHER]: XID },
    replayIds: { [OTHER]: TID },
    comments: [comment("1", 1, marked("PASS", OTHER))],
  });
  assert.equal(decision.reason.code, "not-on-pull");
  assert.equal(
    decision.description,
    `VERDICT PASS @ ${OTHER} is not on this pull`,
  );
});

test("a later FAIL on the same patch-id or on the head wins", () => {
  const older = comment("1", 1, marked("PASS", OTHER));
  const failHead = decide({
    headSha: HEAD,
    headPatchId: PID,
    headExactId: XID,
    headReplayId: TID,
    onPull: [OTHER, HEAD],
    patchIds: { [OTHER]: PID },
    exactIds: { [OTHER]: XID },
    replayIds: { [OTHER]: TID },
    comments: [older, comment("2", 2, marked("FAIL", HEAD))],
  });
  assert.equal(failHead.kind, "fail");
  assert.equal(failHead.reason.code, "verdict-fail");
  assert.equal(failHead.description, `VERDICT FAIL @ ${HEAD}`);
  const failPatch = decide({
    headSha: HEAD,
    headPatchId: PID,
    headExactId: XID,
    headReplayId: TID,
    onPull: [OTHER, HEAD],
    patchIds: { [OTHER]: PID },
    exactIds: { [OTHER]: XID },
    replayIds: { [OTHER]: TID },
    comments: [older, comment("3", 3, marked("FAIL", OTHER))],
  });
  assert.equal(failPatch.kind, "fail");
  assert.equal(failPatch.reason.code, "verdict-fail");
  assert.equal(failPatch.description, `VERDICT FAIL @ ${OTHER} pid ${PID}`);
});

test("an empty patch-id is refused even when both sides are empty", () => {
  const decision = decide({
    headSha: HEAD,
    headPatchId: "",
    headExactId: "",
    headReplayId: "",
    onPull: [OTHER, HEAD],
    patchIds: { [OTHER]: "" },
    exactIds: { [OTHER]: "" },
    replayIds: { [OTHER]: "" },
    comments: [comment("1", 1, marked("PASS", OTHER))],
  });
  assert.equal(decision.description, `empty patch-id refused for ${OTHER}`);
});

test("main accepts a clean rebase with the same patch-id computed from git objects", async () => {
  const repo = featureRepo();
  try {
    const { code, posts, stderr } = await gateOnReplay({
      ...repo,
      body: marked("PASS", repo.sha1),
      commits: [repo.sha1, repo.sha2],
      force: [[repo.sha1, repo.sha2]],
    });
    assert.equal(code, 0);
    const description = `VERDICT PASS @ ${repo.sha1} pid ${repo.patchId}`;
    assert.deepEqual(posts[0].body, {
      state: "success",
      context: "verdict-gate",
      description,
    });
    assert.deepEqual(stderr, [description]);
    assert.ok(description.includes(repo.sha1));
    assert.ok(description.includes(repo.patchId));
    assert.ok(description.length <= 140);
  } finally {
    rmSync(repo.dir, { recursive: true, force: true });
  }
});

test("main refuses a cited SHA whose diff against the current base changed", async () => {
  const repo = featureRepo();
  try {
    writeFileSync(join(repo.dir, "note.txt"), "changed\n");
    repo.git(["add", "note.txt"]);
    assert.equal(repo.git(["commit", "-qm", "edit"]).status, 0);
    const head = repo.git(["rev-parse", "HEAD"]).stdout.trim();
    const { io, posts } = harness({
      eventName: "pull_request",
      payload: {
        action: "synchronize",
        pull_request: {
          number: 7,
          head: { sha: head },
          base: { sha: repo.baseSha },
          user: { login: "eliasprunaire" },
        },
      },
      pages: [
        {
          url: `${API}/issues/7/comments?per_page=100`,
          comments: [rawComment(1, "2026-10-15T18:00:00Z", marked("PASS", repo.sha1))],
        },
      ],
      routes: {
        commits: [{ sha: repo.sha1 }, { sha: head }],
        timeline: [],
        graphql: historyPayload({
          commits: [repo.sha1, head],
          force: [[repo.sha1, head]],
        }),
      },
    });
    attachGit(io, repo.dir);
    assert.equal(await main([], io), 0);
    assert.equal(posts[0].body.state, "failure");
    assert.equal(
      posts[0].body.description,
      `VERDICT PASS @ ${repo.sha1} does not match head ${head}`,
    );
  } finally {
    rmSync(repo.dir, { recursive: true, force: true });
  }
});

test("main refuses a PASS when only the indentation changed behaviour", async () => {
  const { dir, git } = initGitDir();
  try {
    writeFileSync(join(dir, "app.py"), "x = 1\n");
    git(["add", "app.py"]);
    assert.equal(git(["commit", "-qm", "base"]).status, 0);
    const baseSha = git(["rev-parse", "HEAD"]).stdout.trim();
    // reviewed: print stays inside the dead branch
    writeFileSync(join(dir, "app.py"), 'x = 1\nif False:\n    pass\n    print("run")\n');
    git(["commit", "-aqm", "reviewed"]);
    const sha1 = git(["rev-parse", "HEAD"]).stdout.trim();
    assert.equal(git(["reset", "-q", "--hard", baseSha]).status, 0);
    // shipped: same tokens, print moved out of the branch
    writeFileSync(join(dir, "app.py"), 'x = 1\nif False:\n    pass\nprint("run")\n');
    git(["commit", "-aqm", "shipped"]);
    const sha2 = git(["rev-parse", "HEAD"]).stdout.trim();
    assert.equal(
      patchIdAgainst(git, sha1, baseSha),
      patchIdAgainst(git, sha2, baseSha),
    );
    assert.notEqual(
      patchIdAgainst(git, sha1, baseSha, "--verbatim"),
      patchIdAgainst(git, sha2, baseSha, "--verbatim"),
    );
    const { code, posts } = await gateOnReplay({
      dir,
      baseSha,
      sha1,
      sha2,
      body: marked("PASS", sha1),
      commits: [sha1, sha2],
      force: [[sha1, sha2]],
    });
    assert.equal(code, 0);
    assert.equal(posts[0].body.state, "failure");
    assert.equal(
      posts[0].body.description,
      `VERDICT PASS @ ${sha1} does not match head ${sha2}`,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

function twinFunctions(unusedValue, usedValue) {
  const body = (name, value) =>
    `def ${name}():\n    pass\n    pass\n    pass\n    value = "${value}"\n    pass\n    pass\n    pass\n    return value\n`;
  return `${body("unused", unusedValue)}\n${body("used", usedValue)}\nprint(used())\n`;
}

test("main refuses a PASS when the same hunk moved to another place in the file", async () => {
  const { dir, git } = initGitDir();
  try {
    writeFileSync(join(dir, "app.py"), twinFunctions("old", "old"));
    git(["add", "app.py"]);
    assert.equal(git(["commit", "-qm", "base"]).status, 0);
    const baseSha = git(["rev-parse", "HEAD"]).stdout.trim();
    // reviewed: only the function nobody calls changes (prints old)
    writeFileSync(join(dir, "app.py"), twinFunctions("new", "old"));
    git(["commit", "-aqm", "reviewed"]);
    const sha1 = git(["rev-parse", "HEAD"]).stdout.trim();
    assert.equal(git(["reset", "-q", "--hard", baseSha]).status, 0);
    // shipped: same hunk text, moved to the function that runs (prints new)
    writeFileSync(join(dir, "app.py"), twinFunctions("old", "new"));
    git(["commit", "-aqm", "shipped"]);
    const sha2 = git(["rev-parse", "HEAD"]).stdout.trim();
    // patch-id hashes hunk text and ignores line numbers, so both ids collide
    assert.equal(
      patchIdAgainst(git, sha1, baseSha),
      patchIdAgainst(git, sha2, baseSha),
    );
    assert.equal(
      patchIdAgainst(git, sha1, baseSha, "--verbatim"),
      patchIdAgainst(git, sha2, baseSha, "--verbatim"),
    );
    const { code, posts } = await gateOnReplay({
      dir,
      baseSha,
      sha1,
      sha2,
      body: marked("PASS", sha1),
      commits: [sha1, sha2],
      force: [[sha1, sha2]],
    });
    assert.equal(code, 0);
    assert.equal(posts[0].body.state, "failure");
    assert.equal(
      posts[0].body.description,
      `VERDICT PASS @ ${sha1} does not match head ${sha2}`,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("main accepts a rebase onto a moved base when the replay is exact", async () => {
  const { dir, git } = initGitDir();
  try {
    writeFileSync(join(dir, "app.py"), twinFunctions("old", "old"));
    git(["add", "app.py"]);
    assert.equal(git(["commit", "-qm", "base"]).status, 0);
    const baseSha = git(["rev-parse", "HEAD"]).stdout.trim();
    writeFileSync(join(dir, "app.py"), twinFunctions("old", "new"));
    git(["commit", "-aqm", "feature"]);
    const sha1 = git(["rev-parse", "HEAD"]).stdout.trim();
    // base moves: a line is added above the changed hunk in the same file
    assert.equal(git(["checkout", "-q", "-b", "moved", baseSha]).status, 0);
    writeFileSync(
      join(dir, "app.py"),
      `# header\n${twinFunctions("old", "old")}`,
    );
    git(["commit", "-aqm", "main moved"]);
    const newBase = git(["rev-parse", "HEAD"]).stdout.trim();
    assert.equal(git(["cherry-pick", sha1]).status, 0);
    const sha2 = git(["rev-parse", "HEAD"]).stdout.trim();
    assert.notEqual(sha1, sha2);
    const { code, posts } = await gateOnReplay({
      dir,
      baseSha: newBase,
      sha1,
      sha2,
      body: marked("PASS", sha1),
      commits: [sha1, sha2],
      force: [[sha1, sha2]],
    });
    assert.equal(code, 0);
    assert.equal(posts[0].body.state, "success");
    assert.match(posts[0].body.description, new RegExp(`^VERDICT PASS @ ${sha1} pid `));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("main refuses a matching patch-id from a SHA that never belonged to the pull", async () => {
  const repo = featureRepo();
  const other = initGitDir();
  try {
    writeFileSync(join(other.dir, "note.txt"), "base\n");
    other.git(["add", "note.txt"]);
    other.git(["commit", "-qm", "base"]);
    writeFileSync(join(other.dir, "note.txt"), "hello\n");
    other.git(["add", "note.txt"]);
    other.git(["commit", "-qm", "copy"]);
    const foreign = other.git(["rev-parse", "HEAD"]).stdout.trim();
    repo.git(["fetch", "-q", other.dir, "HEAD"]);
    const { io, posts } = harness({
      eventName: "pull_request",
      payload: {
        action: "synchronize",
        pull_request: {
          number: 7,
          head: { sha: repo.sha2 },
          base: { sha: repo.baseSha },
          user: { login: "eliasprunaire" },
        },
      },
      pages: [
        {
          url: `${API}/issues/7/comments?per_page=100`,
          comments: [rawComment(1, "2026-10-15T18:00:00Z", marked("PASS", foreign))],
        },
      ],
      routes: {
        commits: [{ sha: repo.sha2 }],
        timeline: [],
        graphql: historyPayload({ commits: [repo.sha2], force: [] }),
      },
    });
    attachGit(io, repo.dir);
    assert.equal(await main([], io), 0);
    assert.equal(posts[0].body.state, "failure");
    assert.equal(
      posts[0].body.description,
      `VERDICT PASS @ ${foreign} is not on this pull`,
    );
  } finally {
    rmSync(repo.dir, { recursive: true, force: true });
    rmSync(other.dir, { recursive: true, force: true });
  }
});

test("main lets a later FAIL on the head beat an older same-patch PASS", async () => {
  const repo = featureRepo();
  try {
    const { code, posts } = await gateOnReplay({
      ...repo,
      body: marked("PASS", repo.sha1),
      extraComments: [
        rawComment(2, "2026-10-15T19:00:00Z", marked("FAIL", repo.sha2)),
      ],
      commits: [repo.sha1, repo.sha2],
      force: [[repo.sha1, repo.sha2]],
    });
    assert.equal(code, 0);
    assert.equal(posts[0].body.state, "failure");
    assert.equal(posts[0].body.description, `VERDICT FAIL @ ${repo.sha2}`);
  } finally {
    rmSync(repo.dir, { recursive: true, force: true });
  }
});

test("main refuses a SHA reachable from the base even if it is an ancestor of the head", async () => {
  const repo = featureRepo();
  try {
    const { io, posts } = harness({
      eventName: "pull_request",
      payload: {
        action: "synchronize",
        pull_request: {
          number: 7,
          head: { sha: repo.sha2 },
          base: { sha: repo.baseSha },
          user: { login: "eliasprunaire" },
        },
      },
      pages: [
        {
          url: `${API}/issues/7/comments?per_page=100`,
          comments: [rawComment(1, "2026-10-15T18:00:00Z", marked("PASS", repo.baseSha))],
        },
      ],
      routes: {
        commits: [{ sha: repo.baseSha }, { sha: repo.sha2 }],
        timeline: [],
        graphql: historyPayload({
          commits: [repo.baseSha, repo.sha2],
          force: [],
        }),
      },
    });
    attachGit(io, repo.dir);
    assert.equal(await main([], io), 0);
    assert.equal(posts[0].body.state, "failure");
    assert.equal(
      posts[0].body.description,
      `VERDICT PASS @ ${repo.baseSha} is not on this pull`,
    );
  } finally {
    rmSync(repo.dir, { recursive: true, force: true });
  }
});

test("main refuses an ancestor of the head that never appears on the pull timeline", async () => {
  const { dir, git } = initGitDir();
  try {
    writeFileSync(join(dir, "note.txt"), "base\n");
    git(["add", "note.txt"]);
    git(["commit", "-qm", "base"]);
    const baseSha = git(["rev-parse", "HEAD"]).stdout.trim();
    writeFileSync(join(dir, "note.txt"), "one\n");
    git(["add", "note.txt"]);
    git(["commit", "-qm", "one"]);
    const mid = git(["rev-parse", "HEAD"]).stdout.trim();
    writeFileSync(join(dir, "note.txt"), "two\n");
    git(["add", "note.txt"]);
    git(["commit", "-qm", "two"]);
    const head = git(["rev-parse", "HEAD"]).stdout.trim();
    const ancestor = git(["merge-base", "--is-ancestor", mid, head]);
    assert.equal(ancestor.status, 0);
    const { io, posts } = harness({
      eventName: "pull_request",
      payload: {
        action: "synchronize",
        pull_request: {
          number: 7,
          head: { sha: head },
          base: { sha: baseSha },
          user: { login: "eliasprunaire" },
        },
      },
      pages: [
        {
          url: `${API}/issues/7/comments?per_page=100`,
          comments: [rawComment(1, "2026-10-15T18:00:00Z", marked("PASS", mid))],
        },
      ],
      routes: {
        commits: [{ sha: head }],
        timeline: [],
        graphql: historyPayload({ commits: [head], force: [] }),
      },
    });
    attachGit(io, dir);
    assert.equal(await main([], io), 0);
    assert.equal(posts[0].body.state, "failure");
    assert.equal(
      posts[0].body.description,
      `VERDICT PASS @ ${mid} is not on this pull`,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("main refuses a SHA that only a referenced or closed timeline event names", async () => {
  const repo = featureRepo();
  try {
    for (const event of ["referenced", "closed", "merged"]) {
      const { code, posts } = await gateOnReplay({
        ...repo,
        body: marked("PASS", repo.sha1),
        commits: [repo.sha2],
        force: [],
        timeline: [{ event, commit_id: repo.sha1 }],
      });
      assert.equal(code, 0);
      assert.equal(posts[0].body.state, "failure", event);
      assert.equal(
        posts[0].body.description,
        `VERDICT PASS @ ${repo.sha1} is not on this pull`,
        event,
      );
    }
  } finally {
    rmSync(repo.dir, { recursive: true, force: true });
  }
});

test("main accepts a SHA that a committed timeline event names", async () => {
  const repo = featureRepo();
  try {
    const { code, posts } = await gateOnReplay({
      ...repo,
      body: marked("PASS", repo.sha1),
      commits: [repo.sha2],
      force: [],
      timeline: [{ event: "committed", sha: repo.sha1 }],
    });
    assert.equal(code, 0);
    assert.equal(posts[0].body.state, "success");
    assert.equal(
      posts[0].body.description,
      `VERDICT PASS @ ${repo.sha1} pid ${repo.patchId}`,
    );
  } finally {
    rmSync(repo.dir, { recursive: true, force: true });
  }
});

test("main fetches the old head with its ancestors into a fresh clone", async () => {
  const repo = featureRepo();
  const cloneDir = mkdtempSync(join(tmpdir(), "verdict-gate-clone-"));
  try {
    assert.equal(
      repo.git(["config", "uploadpack.allowAnySHA1InWant", "true"]).status,
      0,
    );
    const clone = spawnSync(
      "git",
      ["clone", "-q", "--no-local", repo.dir, cloneDir],
      { encoding: "utf8" },
    );
    assert.equal(clone.status, 0);
    const probe = spawnSync("git", ["cat-file", "-t", repo.sha1], {
      cwd: cloneDir,
      encoding: "utf8",
    });
    assert.notEqual(probe.status, 0);
    const { code, posts } = await gateOnReplay({
      ...repo,
      dir: cloneDir,
      body: marked("PASS", repo.sha1),
      commits: [repo.sha1, repo.sha2],
      force: [[repo.sha1, repo.sha2]],
    });
    assert.equal(code, 0);
    assert.equal(posts[0].body.state, "success");
    assert.equal(
      posts[0].body.description,
      `VERDICT PASS @ ${repo.sha1} pid ${repo.patchId}`,
    );
  } finally {
    rmSync(repo.dir, { recursive: true, force: true });
    rmSync(cloneDir, { recursive: true, force: true });
  }
});

test("main refuses an empty diff even when both patch-ids would match", async () => {
  const { dir, git } = initGitDir();
  try {
    writeFileSync(join(dir, "note.txt"), "base\n");
    git(["add", "note.txt"]);
    git(["commit", "-qm", "base"]);
    const baseSha = git(["rev-parse", "HEAD"]).stdout.trim();
    assert.equal(git(["commit", "--allow-empty", "-qm", "empty-one"]).status, 0);
    const sha1 = git(["rev-parse", "HEAD"]).stdout.trim();
    assert.equal(git(["commit", "--allow-empty", "-qm", "empty-two"]).status, 0);
    const sha2 = git(["rev-parse", "HEAD"]).stdout.trim();
    const { io, posts } = harness({
      eventName: "pull_request",
      payload: {
        action: "synchronize",
        pull_request: {
          number: 7,
          head: { sha: sha2 },
          base: { sha: baseSha },
          user: { login: "eliasprunaire" },
        },
      },
      pages: [
        {
          url: `${API}/issues/7/comments?per_page=100`,
          comments: [rawComment(1, "2026-10-15T18:00:00Z", marked("PASS", sha1))],
        },
      ],
      routes: {
        commits: [{ sha: sha1 }, { sha: sha2 }],
        timeline: [],
        graphql: historyPayload({ commits: [sha1, sha2], force: [] }),
      },
    });
    attachGit(io, dir);
    assert.equal(await main([], io), 0);
    assert.equal(posts[0].body.state, "failure");
    assert.equal(
      posts[0].body.description,
      `empty patch-id refused for ${sha1}`,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a marked PASS from the pull request author fails even when listed", () => {
  const decision = decide({
    headSha: HEAD,
    authorLogin: "eliasprunaire",
    verifiers: [AUTHOR],
    comments: [comment("1", 1, marked("PASS", HEAD), AUTHOR)],
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

test("a marked PASS from the pull request author is ignored when not listed", () => {
  const decision = decide({
    headSha: HEAD,
    authorLogin: "eliasprunaire",
    comments: [comment("1", 1, marked("PASS", HEAD), AUTHOR)],
  });
  assert.deepEqual(decision, {
    kind: "fail",
    reason: { code: "none", headSha: HEAD, hint: "neither" },
    description: `no marked VERDICT for ${HEAD}`,
  });
});

test("a listed login different from the author passes", () => {
  const ada = { login: "ada", type: "Bot" };
  const decision = decide({
    headSha: HEAD,
    authorLogin: "eliasprunaire",
    verifiers: [ada],
    comments: [comment("1", 1, marked("PASS", HEAD), ada)],
  });
  assert.deepEqual(decision, {
    kind: "pass",
    verdict: "PASS",
    sha: HEAD,
    commentId: "1",
    description: `VERDICT PASS @ ${HEAD}`,
  });
});

test("a verdict with no comment login is ignored and fails closed", () => {
  const entries = [
    comment("1", 1, marked("PASS", HEAD), null),
    comment("2", 2, marked("PASS", HEAD), { login: "", type: "Bot" }),
    comment("3", 3, marked("PASS", HEAD), { type: "Bot" }),
  ];
  for (const entry of entries) {
    const decision = decideGate({
      headSha: HEAD,
      authorLogin: "eliasprunaire",
      comments: [entry],
    });
    assert.deepEqual(decision, {
      kind: "fail",
      reason: { code: "none", headSha: HEAD, hint: "neither" },
      description: `no marked VERDICT for ${HEAD}`,
    });
  }
});

test("a matching verdict with no pull author login fails closed", () => {
  const withNull = decide({
    headSha: HEAD,
    authorLogin: null,
    comments: [comment("1", 1, marked("PASS", HEAD))],
  });
  const omitted = decideGate({
    headSha: HEAD,
    comments: [comment("2", 2, marked("PASS", HEAD))],
  });
  for (const decision of [withNull, omitted]) {
    assert.equal(decision.kind, "fail");
    assert.equal(decision.reason.code, "missing-login");
    assert.equal(decision.reason.side, "pull");
    assert.equal(decision.description, "pull request has no author login");
  }
});

test("author login match is case insensitive", () => {
  const upper = { login: "EliasPrunaire", type: "User" };
  const decision = decide({
    headSha: HEAD,
    authorLogin: "eliasprunaire",
    verifiers: [upper],
    comments: [comment("1", 1, marked("PASS+NOTES", HEAD), upper)],
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
    verifiers: [AUTHOR],
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        comments: [
          rawComment(
            1,
            "2026-10-15T18:00:00Z",
            marked("PASS", HEAD),
            undefined,
            AUTHOR,
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
    verifiers: [AUTHOR],
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        comments: [
          rawComment(
            1,
            "2026-10-15T18:00:00Z",
            marked("PASS", HEAD),
            undefined,
            AUTHOR,
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
    `no marked VERDICT for ${HEAD}`,
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

const THIRD_USER = { login: "mallory-evil", type: "User" };
const THIRD_BOT = { login: "mallory-evil[bot]", type: "Bot" };
const NOT_RECORDED = {
  kind: "fail",
  reason: { code: "none", headSha: HEAD, hint: "neither" },
  description: `no marked VERDICT for ${HEAD}`,
};

test("a third-party PASS on the exact head fails", () => {
  for (const user of [THIRD_USER, THIRD_BOT]) {
    const decision = decide({
      headSha: HEAD,
      comments: [comment("1", 1, marked("PASS", HEAD), user)],
    });
    assert.deepEqual(decision, NOT_RECORDED);
  }
});

test("a listed Bot passes with PASS and PASS+NOTES", () => {
  for (const verdict of ["PASS", "PASS+NOTES"]) {
    const decision = decide({
      headSha: HEAD,
      comments: [comment("1", 1, marked(verdict, HEAD))],
    });
    assert.deepEqual(decision, {
      kind: "pass",
      verdict,
      sha: HEAD,
      commentId: "1",
      description: `VERDICT ${verdict} @ ${HEAD}`,
    });
  }
});

test("a login or type that is not exactly the listed pair fails", () => {
  const users = [
    { login: "app-pilote-verifier", type: "User" },
    { login: VERIFIER, type: "User" },
    { login: VERIFIER },
    { login: VERIFIER, type: null },
    { login: VERIFIER, type: "bot" },
    { login: "app-pilote-verifier-x[bot]", type: "Bot" },
    { login: "x-app-pilote-verifier[bot]", type: "Bot" },
    { login: "app-pilote-verifier", type: "Bot" },
    { login: "App-Pilote-Verifier[bot]", type: "Bot" },
    { login: VERIFIER.toUpperCase(), type: "Bot" },
    { login: `${VERIFIER} `, type: "Bot" },
  ];
  for (const user of users) {
    const decision = decide({
      headSha: HEAD,
      comments: [comment("1", 1, marked("PASS", HEAD), user)],
    });
    assert.deepEqual(decision, NOT_RECORDED, JSON.stringify(user));
  }
});

test("third-party comments never win, never hint, and never hide the verifier", () => {
  const real = comment("1", 1, marked("PASS+NOTES", HEAD));
  const fakeFail = comment("2", 2, marked("FAIL", HEAD), THIRD_USER);
  const fakePass = comment("3", 3, marked("PASS", OTHER), THIRD_BOT);
  const markerOnly = comment("4", 4, `look\n${MARKER}`, THIRD_USER);
  for (const comments of [
    [real, fakeFail, fakePass, markerOnly],
    [markerOnly, fakePass, fakeFail, real],
  ]) {
    assert.deepEqual(decide({ headSha: HEAD, comments }), {
      kind: "pass",
      verdict: "PASS+NOTES",
      sha: HEAD,
      commentId: "1",
      description: `VERDICT PASS+NOTES @ ${HEAD}`,
    });
  }
  const hinted = decide({
    headSha: HEAD,
    comments: [markerOnly, comment("5", 5, `VERDICT: PASS @ ${HEAD}`, THIRD_BOT)],
  });
  assert.deepEqual(hinted, NOT_RECORDED);
});

test("an empty verifier list refuses every verdict", () => {
  const decision = decide({
    headSha: HEAD,
    verifiers: [],
    comments: [comment("1", 1, marked("PASS", HEAD))],
  });
  assert.deepEqual(decision, NOT_RECORDED);
});

test("an invalid verifier list refuses every verdict", () => {
  const good = { login: VERIFIER, type: "Bot" };
  const lists = [
    "app-pilote-verifier[bot]",
    VERIFIER,
    {},
    { login: VERIFIER, type: "Bot" },
    0,
    false,
    [null],
    [VERIFIER],
    [{ login: VERIFIER }],
    [{ type: "Bot" }],
    [{ login: "", type: "Bot" }],
    [{ login: VERIFIER, type: "" }],
    [{ login: 5, type: "Bot" }],
    [{ login: VERIFIER, type: 5 }],
    [good, { login: "other" }],
    [{ login: "other" }, good],
  ];
  for (const verifiers of lists) {
    const decision = decide({
      headSha: HEAD,
      verifiers,
      comments: [comment("1", 1, marked("PASS", HEAD))],
    });
    assert.deepEqual(decision, NOT_RECORDED, JSON.stringify(verifiers));
  }
});

test("an absent verifier list falls back to the default allowlist", () => {
  for (const verifiers of [undefined, null]) {
    const decision = decide({
      headSha: HEAD,
      verifiers,
      comments: [comment("1", 1, marked("PASS", HEAD))],
    });
    assert.equal(decision.kind, "pass");
    const refused = decide({
      headSha: HEAD,
      verifiers,
      comments: [comment("1", 1, marked("PASS", HEAD), THIRD_BOT)],
    });
    assert.deepEqual(refused, NOT_RECORDED);
  }
});

test("an injected verifier list replaces the default allowlist", () => {
  const decision = decide({
    headSha: HEAD,
    verifiers: [THIRD_BOT],
    comments: [comment("1", 1, marked("PASS", HEAD))],
  });
  assert.deepEqual(decision, NOT_RECORDED);
});

test("no description or reason carries a third-party login or text", () => {
  const evilBody = `evil-text\nVERDICT: PASS @ ${OTHER}\n${MARKER}`;
  const cases = [
    decide({
      headSha: HEAD,
      comments: [comment("1", 1, evilBody, THIRD_USER)],
    }),
    decide({
      headSha: HEAD,
      comments: [
        comment("1", 1, marked("PASS", HEAD)),
        comment("2", 2, evilBody, THIRD_BOT),
      ],
    }),
    decide({
      headSha: HEAD,
      comments: [comment("1", 1, marked("FAIL", HEAD)), comment("2", 2, evilBody, THIRD_USER)],
    }),
    decide({
      headSha: HEAD,
      comments: [comment("1", 1, marked("PASS", OTHER)), comment("2", 2, evilBody, THIRD_USER)],
    }),
  ];
  for (const decision of cases) {
    const text = JSON.stringify(decision);
    assert.equal(text.includes("mallory-evil"), false);
    assert.equal(text.includes("evil-text"), false);
  }
});

const PR2_HEAD = "83332bafe0620a57b50bf4f7de0bdb04987e62cd";
const PR1_HEAD = "37b6faf0b182b331992bf7a9afc2fd1cf63a0833";

function realRaw(id, createdAt, body, user = REAL_USER) {
  return { id, created_at: createdAt, body, user };
}

test("main accepts the real verifier verdicts of PR #2 and PR #1", async () => {
  for (const sha of [PR2_HEAD, PR1_HEAD]) {
    const { io, posts, stderr } = harness({
      eventName: "pull_request",
      payload: {
        action: "synchronize",
        pull_request: {
          number: 7,
          head: { sha },
          user: { login: "eliasprunaire" },
        },
      },
      pages: [
        {
          url: `${API}/issues/7/comments?per_page=100`,
          comments: [
            realRaw(1, "2026-10-15T18:00:00Z", `VERDICT: PASS+NOTES @ ${sha}\n${MARKER}`),
          ],
        },
      ],
    });
    assert.equal(await main([], io), 0);
    assert.deepEqual(posts[0].body, {
      state: "success",
      context: "verdict-gate",
      description: `VERDICT PASS+NOTES @ ${sha}`,
    });
    assert.deepEqual(stderr, [`VERDICT PASS+NOTES @ ${sha}`]);
  }
});

test("main across pages keeps the real verdict and drops third-party ones", async () => {
  const page2 = `${API}/issues/7/comments?per_page=100&page=2`;
  const page3 = `${API}/issues/7/comments?per_page=100&page=3`;
  const { io, posts, stderr } = harness({
    eventName: "pull_request",
    payload: {
      action: "synchronize",
      pull_request: {
        number: 7,
        head: { sha: PR2_HEAD },
        user: { login: "eliasprunaire" },
      },
    },
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        link: `<${page2}>; rel="next"`,
        comments: [
          realRaw(
            1,
            "2026-10-15T18:00:00Z",
            `VERDICT: PASS+NOTES @ ${PR2_HEAD}\n${MARKER}`,
          ),
        ],
      },
      {
        url: page2,
        link: `<${page3}>; rel="next"`,
        comments: [
          realRaw(2, "2026-10-15T19:00:00Z", marked("FAIL", PR2_HEAD), THIRD_USER),
        ],
      },
      {
        url: page3,
        comments: [
          realRaw(3, "2026-10-15T20:00:00Z", marked("FAIL", PR2_HEAD), THIRD_BOT),
        ],
      },
    ],
  });
  assert.equal(await main([], io), 0);
  assert.equal(posts.length, 1);
  assert.deepEqual(posts[0].body, {
    state: "success",
    context: "verdict-gate",
    description: `VERDICT PASS+NOTES @ ${PR2_HEAD}`,
  });
  assert.deepEqual(stderr, [`VERDICT PASS+NOTES @ ${PR2_HEAD}`]);
});

test("main refuses a third-party PASS and leaks nothing about it", async () => {
  for (const user of [THIRD_USER, THIRD_BOT, { login: VERIFIER }, null]) {
    const raw = realRaw(1, "2026-10-15T18:00:00Z", `evil-text\n${marked("PASS", PR2_HEAD)}`, user);
    if (user === null) {
      delete raw.user;
    }
    const { io, posts, stderr } = harness({
      eventName: "pull_request",
      payload: {
        action: "synchronize",
        pull_request: {
          number: 7,
          head: { sha: PR2_HEAD },
          user: { login: "eliasprunaire" },
        },
      },
      pages: [{ url: `${API}/issues/7/comments?per_page=100`, comments: [raw] }],
    });
    assert.equal(await main([], io), 0);
    assert.deepEqual(posts[0].body, {
      state: "failure",
      context: "verdict-gate",
      description: `no marked VERDICT for ${PR2_HEAD}`,
    });
    const logged = JSON.stringify([posts, stderr]);
    assert.equal(logged.includes("mallory-evil"), false);
    assert.equal(logged.includes("evil-text"), false);
  }
});

test("main uses an injected verifier list and never reads the environment for it", async () => {
  const injected = harness({
    eventName: "pull_request",
    payload: {
      action: "synchronize",
      pull_request: { number: 7, head: { sha: HEAD }, user: { login: "eliasprunaire" } },
    },
    verifiers: [THIRD_BOT],
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        comments: [realRaw(1, "2026-10-15T18:00:00Z", marked("PASS", HEAD), THIRD_BOT)],
      },
    ],
  });
  assert.equal(await main([], injected.io), 0);
  assert.equal(injected.posts[0].body.state, "success");

  const fromEnv = harness({
    eventName: "pull_request",
    payload: {
      action: "synchronize",
      pull_request: { number: 7, head: { sha: HEAD }, user: { login: "eliasprunaire" } },
    },
    pages: [
      {
        url: `${API}/issues/7/comments?per_page=100`,
        comments: [realRaw(1, "2026-10-15T18:00:00Z", marked("PASS", HEAD), THIRD_BOT)],
      },
    ],
  });
  fromEnv.io.env.VERIFIERS = JSON.stringify([THIRD_BOT]);
  fromEnv.io.env.VERDICT_GATE_VERIFIERS = JSON.stringify([THIRD_BOT]);
  assert.equal(await main([], fromEnv.io), 0);
  assert.equal(fromEnv.posts[0].body.state, "failure");
});
