"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const root = join(__dirname, "..");
const script = join(root, "scripts/check-toolchain-min.mjs");

function run(cwd, extraEnv = {}) {
  return spawnSync(process.execPath, [script, cwd], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, ...extraEnv },
  });
}

function tree(files) {
  const dir = mkdtempSync(join(tmpdir(), "toolchain-min-"));
  mkdirSync(join(dir, ".github", "workflows"), { recursive: true });
  for (const [rel, body] of Object.entries(files)) {
    const full = join(dir, rel);
    mkdirSync(join(full, ".."), { recursive: true });
    writeFileSync(full, body);
  }
  return dir;
}

const MIN = "swift=6.4\nxcode=27.1\n";

test("an older Swift image fails and names the file, found version, and minimum", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": "container: swift:6.3\n",
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\.github\/workflows\/ci\.yml/);
    assert.match(result.stderr, /6\.3/);
    assert.match(result.stderr, /6\.4/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an equal Swift image passes", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": "container: swift:6.4\n",
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 0, result.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a newer Swift image passes", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": "container: swift:6.4.2\n",
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 0, result.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an older Xcode pin fails and names the file, found version, and minimum", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/release.yml": [
      "xcode-version: '16.4'\n",
      "DEVELOPER_DIR: /Applications/Xcode_27.0.app/Contents/Developer\n",
      "select Xcode_26.1.app\n",
    ].join(""),
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\.github\/workflows\/release\.yml/);
    assert.match(result.stderr, /16\.4|27\.0|26\.1/);
    assert.match(result.stderr, /27\.1/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a missing minima file fails", () => {
  const dir = tree({
    ".github/workflows/ci.yml": "container: swift:6.4\n",
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /toolchain-min\.txt/);
    assert.match(result.stderr, /absent/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a malformed minima file fails", () => {
  const dir = tree({
    ".github/toolchain-min.txt": "swift=6.4\n",
    ".github/workflows/ci.yml": "container: swift:6.4\n",
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /mal formé/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an older Swift image in a .yaml workflow fails", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yaml": "container: swift:6.3\n",
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\.github\/workflows\/ci\.yaml/);
    assert.match(result.stderr, /6\.3/);
    assert.match(result.stderr, /6\.4/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a quoted xcode-version key below the minimum fails", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/macos.yml": '"xcode-version": "27.0"\n',
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\.github\/workflows\/macos\.yml/);
    assert.match(result.stderr, /27\.0/);
    assert.match(result.stderr, /27\.1/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a hash inside an unquoted value still fails an older Swift image", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml":
      "run: echo build#1; docker run --rm swift:6.3 swift --version\n",
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /6\.3/);
    assert.match(result.stderr, /6\.4/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an apostrophe in an unquoted name does not keep a Swift comment", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "name: Swift's CI\n",
      "container: swift:6.4.2\n",
      "# leftover image swift:6.3\n",
    ].join(""),
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 0, result.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a Swift comment below the minimum is ignored when the image meets it", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "container: swift:6.4.2\n",
      "# leftover image swift:6.3\n",
    ].join(""),
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 0, result.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a tree with no Xcode pin reports that none is set", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": "container: swift:6.4.2\n",
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /aucune version Xcode fixée/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the live tree meets the recorded minima", () => {
  const result = spawnSync(process.execPath, [script], {
    cwd: root,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
});

test("ci.yml runs the checker on ubuntu-latest", () => {
  const ci = readFileSync(join(root, ".github/workflows/ci.yml"), "utf8");
  const job = ci.slice(ci.indexOf("  toolchain-min:"));
  assert.match(job, /runs-on: ubuntu-latest\n/);
  assert.match(job, /node scripts\/check-toolchain-min\.mjs/);
});
