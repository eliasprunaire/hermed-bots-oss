const assert = require("node:assert/strict");
const { mkdtempSync, readFileSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");
const {
  authoredPrBody,
  checkSources,
  explicitSquashBody,
  hitsIn,
  main,
} = require("../scripts/check-pr-attribution.js");

const REAL_BC_ID = "bc-4fa94a52-04cd-579c-817b-27ae10b9c21c";

function runMain(argv) {
  const error = console.error;
  const chunks = [];
  console.error = (...args) => {
    chunks.push(args.map(String).join(" "));
  };
  try {
    return { code: main(argv), err: chunks.join("\n") };
  } finally {
    console.error = error;
  }
}

test("clean text has no hits", () => {
  assert.deepEqual(hitsIn("Fix the greeting page"), []);
});

test("empty text has no hits", () => {
  assert.deepEqual(hitsIn(""), []);
  assert.deepEqual(hitsIn(null), []);
});

test("detects a co-author trailer", () => {
  assert.deepEqual(hitsIn("Co-authored-by: Bot <bot@example.com>"), [
    "Co-authored-by",
  ]);
});

test("detects an Open in Cursor footer", () => {
  assert.deepEqual(hitsIn("See Open in Cursor for the agent"), [
    "Open in Cursor",
  ]);
});

test("detects a cursor.com/agents URL", () => {
  assert.deepEqual(hitsIn("https://cursor.com/agents/abc"), [
    "cursor.com/agents",
  ]);
});

test("matching is case-insensitive", () => {
  assert.deepEqual(hitsIn("co-authored-by: x\nOPEN IN CURSOR"), [
    "Co-authored-by",
    "Open in Cursor",
  ]);
});

test("checkSources names the failing label", () => {
  const failures = checkSources([
    { label: "PR body", text: "ok" },
    { label: "commit messages", text: "Co-authored-by: x" },
  ]);
  assert.deepEqual(failures, ["commit messages contains Co-authored-by"]);
});

test("main exits 0 for clean files", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(
    body,
    [
      "## Why",
      "Ship the merge rule.",
      "",
      "## Agents",
      "",
      `- \`${REAL_BC_ID}\``,
      "",
    ].join("\n"),
  );
  writeFileSync(commits, "docs(rules): allow squash merge\n");
  assert.equal(main(["--body-file", body, "--commits-file", commits]), 0);
});

test("authoredPrBody keeps the briefing and drops the injected footer", () => {
  const body = [
    "<!-- CURSOR_AGENT_PR_BODY_BEGIN -->",
    "## Why",
    "Ship the merge rule.",
    "<!-- CURSOR_AGENT_PR_BODY_END -->",
    "",
    '<div><a href="https://cursor.com/agents/abc"><img alt="Open in Cursor"></a></div>',
    "",
  ].join("\n");
  assert.equal(hitsIn(authoredPrBody(body)).length, 0);
  assert.match(authoredPrBody(body), /Ship the merge rule/);
});

test("authored briefing still fails when it names a forbidden footer", () => {
  const body = [
    "<!-- CURSOR_AGENT_PR_BODY_BEGIN -->",
    "See Open in Cursor",
    "<!-- CURSOR_AGENT_PR_BODY_END -->",
  ].join("\n");
  assert.deepEqual(hitsIn(authoredPrBody(body)), ["Open in Cursor"]);
});

const HOST_PR_FOOTER =
  '<div><a href="https://cursor.com/agents/bc-73475f93-cfd4-56ea-92c6-fc82e54f4818?cursor_ref=pr_footer&cursor_cta=open_in_web"><picture><source media="(prefers-color-scheme: dark)" srcset="https://cursor.com/assets/images/open-in-web-dark.png"><source media="(prefers-color-scheme: light)" srcset="https://cursor.com/assets/images/open-in-web-light.png"><img alt="Open in Web" width="114" height="28" src="https://cursor.com/assets/images/open-in-web-dark.png"></picture></a>&nbsp;<a href="https://cursor.com/background-agent?bcId=bc-73475f93-cfd4-56ea-92c6-fc82e54f4818&cursor_ref=pr_footer&cursor_cta=open_in_cursor"><picture><source media="(prefers-color-scheme: dark)" srcset="https://cursor.com/assets/images/open-in-cursor-dark.png"><source media="(prefers-color-scheme: light)" srcset="https://cursor.com/assets/images/open-in-cursor-light.png"><img alt="Open in Cursor" width="131" height="28" src="https://cursor.com/assets/images/open-in-cursor-dark.png"></picture></a>&nbsp;</div>';

test("a real bc- id footer still strips", () => {
  const body = ["## Why", "Ship the merge rule.", "", HOST_PR_FOOTER, ""].join(
    "\n",
  );
  assert.equal(hitsIn(body).includes("Open in Cursor"), true);
  assert.deepEqual(checkSources([{ label: "PR body", text: body }]), []);
});

test("a trailer planted in the first agent slot stays a hit", () => {
  const smuggled = HOST_PR_FOOTER.replace(
    "bc-73475f93-cfd4-56ea-92c6-fc82e54f4818",
    "bc-73475f93-cfd4-56ea-92c6-fc82e54f4818\nCo-authored-by: Bot bot@example.com",
  );
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(
    body,
    ["## Why", "Ship the merge rule.", "", smuggled, ""].join("\n"),
  );
  writeFileSync(commits, "docs(rules): allow squash merge\n");
  const { code, err } = runMain([
    "--body-file",
    body,
    "--commits-file",
    commits,
  ]);
  assert.equal(code, 1);
  assert.match(err, /PR body contains Co-authored-by/);
});

test("a trailer split by a unicode line separator in the agent slot stays a hit", () => {
  for (const sep of ["\u2028", "\u2029"]) {
    const smuggled = HOST_PR_FOOTER.replace(
      "bc-73475f93-cfd4-56ea-92c6-fc82e54f4818",
      `bc-73475f93-cfd4-56ea-92c6-fc82e54f4818${sep}Co-authored-by: Bot bot@example.com`,
    );
    const dir = mkdtempSync(join(tmpdir(), "attr-"));
    const body = join(dir, "body.txt");
    const commits = join(dir, "commits.txt");
    writeFileSync(
      body,
      ["## Why", "Ship the merge rule.", "", smuggled, ""].join("\n"),
    );
    writeFileSync(commits, "docs(rules): allow squash merge\n");
    const { code, err } = runMain([
      "--body-file",
      body,
      "--commits-file",
      commits,
    ]);
    assert.equal(code, 1, `separator ${sep.codePointAt(0).toString(16)}`);
    assert.match(err, /PR body contains Co-authored-by/);
  }
});

test("main exits 0 when the PR body ends with the host footer", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(
    body,
    [
      "## Why",
      "Ship the merge rule.",
      "",
      "## Agents",
      "",
      `- \`${REAL_BC_ID}\``,
      "",
      HOST_PR_FOOTER,
      "",
    ].join("\n"),
  );
  writeFileSync(commits, "docs(rules): allow squash merge\n");
  assert.equal(main(["--body-file", body, "--commits-file", commits]), 0);
});

test("main exits 1 when a co-author trailer sits inside the trailing div", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(
    body,
    [
      "## Why",
      "Ship the merge rule.",
      "<div>",
      "Co-authored-by: Bot <bot@example.com>",
      '<a href="https://cursor.com/background-agent?bcId=abc">details</a>',
      "</div>",
      "",
    ].join("\n"),
  );
  writeFileSync(commits, "docs(rules): allow squash merge\n");
  const { code, err } = runMain([
    "--body-file",
    body,
    "--commits-file",
    commits,
  ]);
  assert.equal(code, 1);
  assert.match(err, /PR body contains Co-authored-by/);
});

test("main exits 1 when the trailing div contains an authored footer phrase", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(
    body,
    [
      "## Why",
      "Ship the merge rule.",
      "<div>",
      "See Open in Cursor",
      '<a href="https://cursor.com/background-agent?bcId=abc">details</a>',
      "</div>",
      "",
    ].join("\n"),
  );
  writeFileSync(commits, "docs(rules): allow squash merge\n");
  const { code, err } = runMain([
    "--body-file",
    body,
    "--commits-file",
    commits,
  ]);
  assert.equal(code, 1);
  assert.match(err, /PR body contains Open in Cursor/);
});

test("main exits 1 when the PR body is dirty", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(body, "Open in Cursor\n");
  writeFileSync(commits, "docs(rules): allow squash merge\n");
  const { code } = runMain(["--body-file", body, "--commits-file", commits]);
  assert.equal(code, 1);
});

test("a co-author trailer after the END marker fails the PR body", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(
    body,
    [
      "<!-- CURSOR_AGENT_PR_BODY_BEGIN -->",
      "## Why",
      "Ship the merge rule.",
      "<!-- CURSOR_AGENT_PR_BODY_END -->",
      "",
      "Co-authored-by: Bot <bot@example.com>",
      "",
      '<div><a href="https://cursor.com/agents/abc"><img alt="Open in Cursor"></a></div>',
      "",
    ].join("\n"),
  );
  writeFileSync(commits, "docs(rules): allow squash merge\n");
  const { code, err } = runMain([
    "--body-file",
    body,
    "--commits-file",
    commits,
  ]);
  assert.equal(code, 1);
  assert.match(err, /PR body contains Co-authored-by/);
});

test("main errors when a required flag is missing", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const commits = join(dir, "commits.txt");
  writeFileSync(commits, "docs(rules): allow squash merge\n");
  const none = runMain([]);
  assert.notEqual(none.code, 0);
  assert.match(none.err, /--body-file/);
  const half = runMain(["--commits-file", commits]);
  assert.notEqual(half.code, 0);
  assert.match(half.err, /--body-file/);
  const empty = runMain(["--body-file", "--commits-file", commits]);
  assert.notEqual(empty.code, 0);
});

test("main errors with a clear message when a file is missing", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const commits = join(dir, "commits.txt");
  writeFileSync(commits, "docs(rules): allow squash merge\n");
  const missing = join(dir, "no-such-body.txt");
  const { code, err } = runMain([
    "--body-file",
    missing,
    "--commits-file",
    commits,
  ]);
  assert.notEqual(code, 0);
  assert.match(err, /missing file/);
  assert.match(err, /no-such-body/);
  assert.doesNotMatch(err, /ENOENT/);
});

test("does not match a co-author mention that is not a trailer", () => {
  assert.deepEqual(hitsIn("Do not paste a Co-authored-by trailer."), []);
});

test("detects a co-author trailer with space or tab before the colon", () => {
  assert.deepEqual(hitsIn("Co-authored-by : Bot bot@example.com"), [
    "Co-authored-by",
  ]);
  assert.deepEqual(hitsIn("Co-authored-by\t: Bot bot@example.com"), [
    "Co-authored-by",
  ]);
  assert.deepEqual(hitsIn("cO-aUtHoReD-bY : Bot bot@example.com"), [
    "Co-authored-by",
  ]);
});

test("a comment-prefixed co-author trailer is rejected", () => {
  assert.deepEqual(
    hitsIn("feat: note\n\n# Co-authored-by: Bot <bot@example.com>\n"),
    ["Co-authored-by"],
  );
});

test("does not match an agents URL used as a longer path prefix", () => {
  assert.deepEqual(hitsIn("https://cursor.com/agentsxxx/nope"), []);
});

test("main exits 1 when the squash body carries a co-author trailer", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  const squash = join(dir, "squash.txt");
  writeFileSync(body, "## Why\nShip the merge rule.\n");
  writeFileSync(commits, "docs(rules): allow squash merge\n");
  writeFileSync(
    squash,
    "Co-authored-by: Cursor Agent <cursoragent@cursor.com>\n",
  );
  const { code, err } = runMain([
    "--body-file",
    body,
    "--commits-file",
    commits,
    "--squash-body-file",
    squash,
  ]);
  assert.equal(code, 1);
  assert.match(err, /squash body contains Co-authored-by/);
});

test("the explicit squash body is empty", () => {
  assert.equal(explicitSquashBody(), "");
  assert.deepEqual(hitsIn(explicitSquashBody()), []);
  const write = process.stdout.write;
  let out = "";
  process.stdout.write = (chunk) => {
    out += chunk;
    return true;
  };
  try {
    assert.equal(main(["--print-squash-body"]), 0);
  } finally {
    process.stdout.write = write;
  }
  assert.equal(out, "");
});

test("main exits 0 when Agents lists a bc- UUID", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(
    body,
    [
      "## Why",
      "Ship the merge rule.",
      "",
      "## Agents",
      "",
      `- \`${REAL_BC_ID}\``,
      "",
      HOST_PR_FOOTER,
      "",
    ].join("\n"),
  );
  writeFileSync(commits, "ci(pr): require bc- agent ids in the body\n");
  assert.equal(main(["--body-file", body, "--commits-file", commits]), 0);
});

test("main exits 1 when the PR body has no Agents heading", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(body, "## Why\nShip the merge rule.\n");
  writeFileSync(commits, `docs: note\n\n${REAL_BC_ID}\n`);
  const { code, err } = runMain([
    "--body-file",
    body,
    "--commits-file",
    commits,
  ]);
  assert.equal(code, 1);
  assert.match(err, /## Agents/);
});

test("main exits 1 when Agents has only the template bc- text", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  const template = readFileSync(
    join(__dirname, "../.github/PULL_REQUEST_TEMPLATE.md"),
    "utf8",
  );
  writeFileSync(body, template);
  writeFileSync(commits, `ci(pr): note\n\n${REAL_BC_ID}\n`);
  const { code, err } = runMain([
    "--body-file",
    body,
    "--commits-file",
    commits,
  ]);
  assert.equal(code, 1);
  assert.match(err, /bc- UUID/);
});

test("main exits 1 when the only bc- UUID sits under Why", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(
    body,
    [
      "## Why",
      `Ship ${REAL_BC_ID}.`,
      "",
      "## Agents",
      "",
      "- `bc-` id for each agent on this PR",
      "",
    ].join("\n"),
  );
  writeFileSync(commits, "ci(pr): require bc- agent ids in the body\n");
  const { code, err } = runMain([
    "--body-file",
    body,
    "--commits-file",
    commits,
  ]);
  assert.equal(code, 1);
  assert.match(err, /bc- UUID/);
});

test("main exits 1 when Agents and the UUID sit in a fenced block", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(
    body,
    [
      "## Why",
      "Ship the merge rule.",
      "",
      "```",
      "## Agents",
      "",
      `- \`${REAL_BC_ID}\``,
      "```",
      "",
    ].join("\n"),
  );
  writeFileSync(commits, "ci(pr): require bc- agent ids in the body\n");
  const { code, err } = runMain([
    "--body-file",
    body,
    "--commits-file",
    commits,
  ]);
  assert.equal(code, 1);
  assert.match(err, /## Agents/);
});

test("main exits 1 when Agents and the UUID sit in an HTML comment", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(
    body,
    [
      "## Why",
      "Ship the merge rule.",
      "",
      "<!--",
      "## Agents",
      "",
      `- \`${REAL_BC_ID}\``,
      "-->",
      "",
    ].join("\n"),
  );
  writeFileSync(commits, "ci(pr): require bc- agent ids in the body\n");
  const { code, err } = runMain([
    "--body-file",
    body,
    "--commits-file",
    commits,
  ]);
  assert.equal(code, 1);
  assert.match(err, /## Agents/);
});

test("main exits 1 when the Agents UUID sits in a fenced block", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(
    body,
    [
      "## Why",
      "Ship the merge rule.",
      "",
      "## Agents",
      "",
      "```",
      `- \`${REAL_BC_ID}\``,
      "```",
      "",
    ].join("\n"),
  );
  writeFileSync(commits, "ci(pr): require bc- agent ids in the body\n");
  const { code, err } = runMain([
    "--body-file",
    body,
    "--commits-file",
    commits,
  ]);
  assert.equal(code, 1);
  assert.match(err, /bc- UUID/);
});

test("a co-author trailer still fails when Agents lists a bc- UUID", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(
    body,
    [
      "## Why",
      "Ship the merge rule.",
      "",
      "Co-authored-by: Bot <bot@example.com>",
      "",
      "## Agents",
      "",
      `- \`${REAL_BC_ID}\``,
      "",
    ].join("\n"),
  );
  writeFileSync(commits, "docs(rules): allow squash merge\n");
  const { code, err } = runMain([
    "--body-file",
    body,
    "--commits-file",
    commits,
  ]);
  assert.equal(code, 1);
  assert.match(err, /PR body contains Co-authored-by/);
});

test("main exits 1 when the only bc- UUID sits in the host footer", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  writeFileSync(
    body,
    [
      "## Why",
      "Ship the merge rule.",
      "",
      "## Agents",
      "",
      "- `bc-` id for each agent on this PR",
      "",
      HOST_PR_FOOTER,
      "",
    ].join("\n"),
  );
  writeFileSync(commits, "ci(pr): require bc- agent ids in the body\n");
  const { code, err } = runMain([
    "--body-file",
    body,
    "--commits-file",
    commits,
  ]);
  assert.equal(code, 1);
  assert.match(err, /bc- UUID/);
});

test("main exits 0 when the squash body is empty", () => {
  const dir = mkdtempSync(join(tmpdir(), "attr-"));
  const body = join(dir, "body.txt");
  const commits = join(dir, "commits.txt");
  const squash = join(dir, "squash.txt");
  writeFileSync(
    body,
    [
      "## Why",
      "Ship the merge rule.",
      "",
      "## Agents",
      "",
      `- \`${REAL_BC_ID}\``,
      "",
    ].join("\n"),
  );
  writeFileSync(commits, "docs(rules): allow squash merge\n");
  writeFileSync(squash, "");
  assert.equal(
    main([
      "--body-file",
      body,
      "--commits-file",
      commits,
      "--squash-body-file",
      squash,
    ]),
    0,
  );
});
