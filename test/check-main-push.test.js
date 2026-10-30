const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const { main, UNKNOWN, NONCOMPLIANT } = require("../scripts/check-main-push.js");

const SHA = "a".repeat(40);
const BEFORE = "c".repeat(40);
const API = "https://api.github.com/repos/acme/app-pilote";
const PULLS = `${API}/commits/${SHA}/pulls`;
const COMMIT = `${API}/commits/${SHA}`;
const PULL = `${API}/pulls/9`;

function liveAssociatedPull() {
  return {
    url: `${API}/pulls/9`,
    id: 1,
    number: 9,
    state: "closed",
    locked: false,
    title: "docs(plans): add the encode-workflow-rules plan",
    user: { login: "eliasprunaire" },
    body: "",
    created_at: "2026-10-17T13:22:00Z",
    updated_at: "2026-10-17T13:54:01Z",
    closed_at: "2026-10-17T13:54:01Z",
    merged_at: "2026-10-17T13:54:01Z",
    assignee: null,
    assignees: [],
    requested_reviewers: [],
    requested_teams: [],
    labels: [],
    milestone: null,
    draft: false,
    commits_url: `${API}/pulls/9/commits`,
    html_url: "https://github.com/acme/app-pilote/pull/9",
    base: { ref: "main", sha: BEFORE },
    head: { ref: "feat/encode-workflow-plan-c21c", sha: SHA },
  };
}

function response(status, body, jsonThrows = false) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => {
      if (jsonThrows) {
        throw new Error("bad json");
      }
      return body;
    },
  };
}

function mergedPull() {
  return {
    number: 9,
    merged_at: "2026-10-17T00:00:00Z",
    state: "closed",
    merge_commit_sha: SHA,
    base: { ref: "main" },
  };
}

function routeFetch(handlers) {
  return async (url, init) => {
    const href = String(url);
    if (href.includes("/commits/") && href.endsWith("/pulls")) {
      return handlers.pulls(url, init);
    }
    if (href === PULL && handlers.pull) {
      return handlers.pull(url, init);
    }
    if (href === COMMIT) {
      return handlers.commit(url, init);
    }
    throw new Error(`unexpected url ${url}`);
  };
}

function harness(fetch) {
  const stderr = [];
  const io = {
    env: {
      GITHUB_REPOSITORY: "acme/app-pilote",
      GITHUB_SHA: SHA,
      GITHUB_BEFORE: BEFORE,
      GITHUB_TOKEN: "test-token",
    },
    fetch,
    stderr(line) {
      stderr.push(line);
    },
  };
  return { io, stderr };
}

function assertCommonHeaders(init) {
  assert.equal(init.headers.Authorization, "Bearer test-token");
  assert.equal(init.headers.Accept, "application/vnd.github+json");
  assert.equal(init.headers["User-Agent"], "check-main-push");
  assert.equal(init.method, undefined);
}

function assertListRequest(init) {
  assertCommonHeaders(init);
  assert.equal(init.headers["X-GitHub-Api-Version"], "2026-03-10");
}

function assertPullDetailRequest(init) {
  assertCommonHeaders(init);
  assert.equal(init.headers["X-GitHub-Api-Version"], "2022-11-28");
}

test("a merged pull list exits 0", async () => {
  const seen = [];
  const { io, stderr } = harness(
    routeFetch({
      pulls: async (url, init) => {
        seen.push({ url, init });
        return response(200, [
          { number: 4, merged_at: null, state: "open", merge_commit_sha: null },
          mergedPull(),
        ]);
      },
      commit: async (url, init) => {
        seen.push({ url, init });
        return response(200, { parents: [{ sha: BEFORE }] });
      },
    }),
  );
  assert.equal(await main(io), 0);
  assert.deepEqual(stderr, []);
  assert.equal(seen.length, 2);
  assert.equal(seen[0].url, PULLS);
  assert.equal(seen[1].url, COMMIT);
  assert.equal(seen[0].url.includes("protection"), false);
  assertListRequest(seen[0].init);
  assertListRequest(seen[1].init);
});

test("a merged pull with a different merge commit exits 1", async () => {
  const { io, stderr } = harness(async () => {
    return response(200, [
      {
        number: 9,
        merged_at: "2026-10-17T00:00:00Z",
        state: "closed",
        merge_commit_sha: "b".repeat(40),
      },
    ]);
  });
  assert.equal(await main(io), 1);
  assert.match(stderr.join("\n"), new RegExp(`no merged pull request for ${SHA}`));
});

test("an empty pull list exits 1", async () => {
  const { io, stderr } = harness(async (url) => {
    assert.equal(url, PULLS);
    return response(200, []);
  });
  assert.equal(await main(io), 1);
  assert.match(stderr.join("\n"), new RegExp(`no merged pull request for ${SHA}`));
});

test("an open pull request is not a merged pull", async () => {
  const { io, stderr } = harness(async () => {
    return response(200, [{ number: 3, merged_at: null, state: "open" }]);
  });
  assert.equal(await main(io), 1);
  assert.match(stderr.join("\n"), /no merged pull request/);
});

test("a malformed pull list exits 1", async () => {
  const objectBody = harness(async () => response(200, { message: "Not Found" }));
  assert.equal(await main(objectBody.io), 1);
  assert.match(objectBody.stderr.join("\n"), /malformed pull request list/);

  const thrown = harness(async () => response(200, null, true));
  assert.equal(await main(thrown.io), 1);
  assert.match(thrown.stderr.join("\n"), /malformed pull request list/);

  const row = harness(async () => response(200, ["nope"]));
  assert.equal(await main(row.io), 1);
  assert.match(row.stderr.join("\n"), /malformed pull request list/);
});

test("missing token, sha, and repository exit 1 before any fetch", async () => {
  let fetched = false;
  const fetch = async () => {
    fetched = true;
    throw new Error("fetch");
  };
  const base = {
    GITHUB_REPOSITORY: "acme/app-pilote",
    GITHUB_SHA: SHA,
    GITHUB_BEFORE: BEFORE,
    GITHUB_TOKEN: "test-token",
  };
  const cases = [
    { GITHUB_TOKEN: "" },
    { GITHUB_SHA: "abc" },
    { GITHUB_SHA: "" },
    { GITHUB_BEFORE: "" },
    { GITHUB_BEFORE: "abc" },
    { GITHUB_REPOSITORY: "acme" },
    { GITHUB_REPOSITORY: "" },
  ];
  for (const override of cases) {
    const stderr = [];
    const code = await main({
      env: { ...base, ...override },
      fetch,
      stderr(line) {
        stderr.push(line);
      },
    });
    assert.equal(code, 1);
    assert.equal(stderr.length, 1);
    assert.equal(stderr[0].includes("test-token"), false);
  }
  assert.equal(fetched, false);
});

test("a failed pull request read exits 1", async () => {
  const missing = harness(async () => response(404, { message: "Not Found" }));
  assert.equal(await main(missing.io), 1);
  assert.match(missing.stderr.join("\n"), /could not read pull requests for the commit/);

  const broken = harness(async () => {
    throw new Error("network");
  });
  assert.equal(await main(broken.io), 1);
  assert.match(broken.stderr.join("\n"), /could not read pull requests for the commit/);
  assert.equal(broken.stderr.join("\n").includes("test-token"), false);
});

test("main-push runs on push to main and not on pull_request", () => {
  const yaml = readFileSync(
    join(__dirname, "..", ".github", "workflows", "main-push.yml"),
    "utf8",
  );
  assert.match(yaml, /push:\n\s+branches: \[main\]/);
  assert.equal(yaml.includes("pull_request"), false);
  assert.equal(yaml.includes("protection"), false);
  assert.match(yaml, /node scripts\/check-main-push\.js/);
  assert.equal(yaml.includes("GITHUB_BEFORE: ${{ github.event.before }}"), true);
});

test("a 2026-03-10 associated pull without merge_commit_sha still matches the squash", async () => {
  const listed = liveAssociatedPull();
  assert.equal(Object.hasOwn(listed, "merge_commit_sha"), false);
  const seen = [];
  const { io, stderr } = harness(
    routeFetch({
      pulls: async (url, init) => {
        seen.push({ url, init });
        return response(200, [listed]);
      },
      pull: async (url, init) => {
        seen.push({ url, init });
        return response(200, {
          number: 9,
          merged_at: "2026-10-17T13:54:01Z",
          merge_commit_sha: SHA,
          base: { ref: "main" },
        });
      },
      commit: async (url, init) => {
        seen.push({ url, init });
        return response(200, { parents: [{ sha: BEFORE }] });
      },
    }),
  );
  assert.equal(await main(io), 0);
  assert.deepEqual(stderr, []);
  assert.equal(seen.length, 3);
  assert.equal(seen[0].url, PULLS);
  assert.equal(seen[1].url, PULL);
  assert.equal(seen[2].url, COMMIT);
  assertListRequest(seen[0].init);
  assertPullDetailRequest(seen[1].init);
  assertListRequest(seen[2].init);
});

test("a 2026-03-10 associated pull for a PR head is not the squash", async () => {
  const listed = liveAssociatedPull();
  const { io, stderr } = harness(
    routeFetch({
      pulls: async () => response(200, [listed]),
      pull: async () =>
        response(200, {
          number: 9,
          merged_at: "2026-10-17T13:54:01Z",
          merge_commit_sha: "b".repeat(40),
          base: { ref: "main" },
        }),
      commit: async () => {
        throw new Error("commit should not be read");
      },
    }),
  );
  assert.equal(await main(io), 1);
  assert.match(stderr.join("\n"), /no merged pull request/);
});

test("a merged pull that did not target main exits 1", async () => {
  const { io, stderr } = harness(async () => {
    return response(200, [
      {
        number: 9,
        merged_at: "2026-10-17T00:00:00Z",
        state: "closed",
        merge_commit_sha: SHA,
        base: { ref: "feat/parent" },
      },
    ]);
  });
  assert.equal(await main(io), 1);
  assert.match(stderr.join("\n"), /no merged pull request/);
});

test("a historical merge whose first parent is not the before sha exits 1", async () => {
  const { io, stderr } = harness(
    routeFetch({
      pulls: async () => response(200, [mergedPull()]),
      commit: async () => response(200, { parents: [{ sha: "d".repeat(40) }] }),
    }),
  );
  assert.equal(await main(io), 1);
  assert.match(stderr.join("\n"), /before sha is not the first parent/);
});

test("a zero before sha exits 1", async () => {
  const { io, stderr } = harness(async () => {
    throw new Error("fetch");
  });
  io.env.GITHUB_BEFORE = "0".repeat(40);
  assert.equal(await main(io), 1);
  assert.match(stderr.join("\n"), /GITHUB_BEFORE must be a non-zero sha/);
});

test("API unreadability is UNKNOWN and a missing merge is NONCOMPLIANT", async () => {
  const unread = harness(async () => response(503, { message: "unavailable" }));
  assert.equal(await main(unread.io), 1);
  assert.equal(unread.stderr.join("\n"), `${UNKNOWN}: could not read pull requests for the commit`);

  const unmatched = harness(async () => response(200, []));
  assert.equal(await main(unmatched.io), 1);
  assert.equal(
    unmatched.stderr.join("\n"),
    `${NONCOMPLIANT}: no merged pull request for ${SHA}`,
  );
});

test("missing context is UNKNOWN and a non-parent before sha is NONCOMPLIANT", async () => {
  const missing = harness(async () => {
    throw new Error("fetch");
  });
  missing.io.env.GITHUB_TOKEN = "";
  assert.equal(await main(missing.io), 1);
  assert.equal(missing.stderr.join("\n"), `${UNKNOWN}: GITHUB_TOKEN is required`);

  const parent = harness(
    routeFetch({
      pulls: async () => response(200, [mergedPull()]),
      commit: async () => response(200, { parents: [{ sha: "d".repeat(40) }] }),
    }),
  );
  assert.equal(await main(parent.io), 1);
  assert.equal(parent.stderr.join("\n"), `${NONCOMPLIANT}: before sha is not the first parent`);
});
