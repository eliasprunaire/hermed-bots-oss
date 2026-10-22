const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdirSync, mkdtempSync, readFileSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");
const { hitsIn } = require("../scripts/check-pr-attribution.js");
const {
  main,
  materializeTrustedHelpers,
  mergeArgv,
} = require("../scripts/squash-merge.js");

test("mergeArgv always passes an explicit body file", () => {
  const gh = mergeArgv("27", "/tmp/body.txt", "gh");
  const origin = mergeArgv("27", "/tmp/body.txt", "origin");
  assert.deepEqual(gh, [
    "gh",
    "pr",
    "merge",
    "27",
    "--squash",
    "--body-file",
    "/tmp/body.txt",
  ]);
  assert.equal(origin[0], "origin");
  assert.equal(origin[5], "--body-file");
  assert.equal(origin[6], "/tmp/body.txt");
});

test("refuses to merge when the squash body has a co-author trailer", () => {
  const error = console.error;
  const chunks = [];
  console.error = (...args) => {
    chunks.push(args.map(String).join(" "));
  };
  let spawned = false;
  try {
    const code = main(["27"], {
      squashBody: () =>
        "Co-authored-by: Cursor Agent <cursoragent@cursor.com>\n",
      resolveForge: () => "gh",
      spawn: () => {
        spawned = true;
        return 0;
      },
    });
    assert.equal(code, 1);
    assert.equal(spawned, false);
    assert.match(chunks.join("\n"), /squash body contains Co-authored-by/);
  } finally {
    console.error = error;
  }
});

test("forwards --auto and still passes an explicit empty body", () => {
  let command;
  const code = main(["--auto", "27"], {
    resolveForge: () => "gh",
    spawn: (cmd) => {
      command = cmd;
      return 0;
    },
  });
  assert.equal(code, 0);
  assert.equal(command.includes("--auto"), true);
  assert.equal(command.includes("--body-file"), true);
  assert.equal(readFileSync(command[command.indexOf("--body-file") + 1], "utf8"), "");
});

test("asks the forge to squash with an explicit empty body", () => {
  let command;
  const code = main(["27"], {
    resolveForge: () => "gh",
    spawn: (cmd) => {
      command = cmd;
      return 0;
    },
  });
  assert.equal(code, 0);
  assert.equal(command[0], "gh");
  assert.deepEqual(command.slice(1, 5), ["pr", "merge", "27", "--squash"]);
  assert.equal(command[5], "--body-file");
  const text = readFileSync(command[6], "utf8");
  assert.equal(text, "");
  assert.deepEqual(hitsIn(text), []);
});

test("uses origin when that forge is selected", () => {
  let command;
  const code = main(["14"], {
    resolveForge: () => "origin",
    spawn: (cmd) => {
      command = cmd;
      return 0;
    },
  });
  assert.equal(code, 0);
  assert.equal(command[0], "origin");
  assert.equal(command[3], "14");
  assert.equal(readFileSync(command[6], "utf8"), "");
});

function git(cwd, args) {
  const result = spawnSync("git", ["-c", "core.hooksPath=/dev/null", ...args], {
    cwd,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}

test("a modified worktree helper is not the process that runs", () => {
  const repo = mkdtempSync(join(tmpdir(), "trusted-merge-"));
  git(repo, ["init", "-b", "main"]);
  git(repo, ["config", "user.email", "test@example.com"]);
  git(repo, ["config", "user.name", "Test"]);
  mkdirSync(join(repo, "scripts"));
  writeFileSync(
    join(repo, "scripts/check-pr-attribution.js"),
    "process.stdout.write('attr-base\\n');\n",
  );
  writeFileSync(
    join(repo, "scripts/squash-merge.js"),
    "require('./check-pr-attribution.js');\nprocess.stdout.write('merge-base\\n');\n",
  );
  git(repo, ["add", "."]);
  git(repo, ["commit", "-m", "base helpers"]);
  git(repo, ["checkout", "-b", "feature"]);
  writeFileSync(
    join(repo, "scripts/check-pr-attribution.js"),
    "process.stdout.write('evil-attr\\n');\n",
  );
  writeFileSync(
    join(repo, "scripts/squash-merge.js"),
    "process.stdout.write('evil-merge\\n');\n",
  );
  git(repo, ["add", "."]);
  git(repo, ["commit", "-m", "evil helpers"]);
  const rev = git(repo, ["merge-base", "HEAD", "main"]).trim();
  const dest = mkdtempSync(join(tmpdir(), "trusted-out-"));
  const entry = materializeTrustedHelpers(rev, dest, { cwd: repo });
  const run = spawnSync(process.execPath, [entry], { encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr);
  assert.equal(run.stdout, "attr-base\nmerge-base\n");
  assert.equal(run.stdout.includes("evil"), false);
});

test("main errors when the pull request number is missing", () => {
  const error = console.error;
  const chunks = [];
  console.error = (...args) => {
    chunks.push(args.map(String).join(" "));
  };
  try {
    const code = main([]);
    assert.equal(code, 1);
    assert.match(chunks.join("\n"), /usage: squash-merge.js/);
  } finally {
    console.error = error;
  }
});
