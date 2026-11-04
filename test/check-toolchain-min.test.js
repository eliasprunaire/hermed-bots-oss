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
      "run: xcode-select --switch /Applications/Xcode_26.1.app/Contents/Developer\n",
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

test("a Swift image in a literal block scalar still fails when too old", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "run: |\n",
      '  echo build" #1"; docker run --rm swift:6.3 swift --version\n',
    ].join(""),
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

test("an Xcode pin in a folded block scalar still fails when too old", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "run: >-\n",
      '  echo build" #1"; export DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer\n',
    ].join(""),
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /27\.0/);
    assert.match(result.stderr, /27\.1/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a French leftover Swift comment does not fail a current image", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "container: swift:6.4.2\n",
      "# Ancienne image : swift:6.3\n",
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

test("a list item block scalar run still fails an older Swift image", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "jobs:\n",
      "  build:\n",
      "    steps:\n",
      "      - run: |\n",
      "          docker run --rm swift:6.3 swift --version\n",
    ].join(""),
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

test("an older container image mapping fails", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "jobs:\n",
      "  build:\n",
      "    container:\n",
      "      image: swift:6.3\n",
    ].join(""),
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

test("an older service image fails", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "jobs:\n",
      "  build:\n",
      "    services:\n",
      "      compiler:\n",
      "        image: swift:6.3\n",
    ].join(""),
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

test("an older docker:// action image fails", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "jobs:\n",
      "  build:\n",
      "    steps:\n",
      "      - uses: docker://swift:6.3\n",
    ].join(""),
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

test("an older xcode-select pin in run fails", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml":
      "run: sudo xcode-select --switch /Applications/Xcode_26.1.app/Contents/Developer\n",
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /26\.1/);
    assert.match(result.stderr, /27\.1/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("invalid YAML fails with a French message and the file name", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": "jobs:\n  build: [\n",
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\.github\/workflows\/ci\.yml/);
    assert.match(result.stderr, /YAML invalide/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an older Swift image in strategy.matrix fails", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "strategy:\n",
      "  matrix:\n",
      "    image: ['swift:6.3']\n",
      "container: ${{ matrix.image }}\n",
    ].join(""),
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

test("an older Swift image in a matrix include entry fails", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "strategy:\n",
      "  matrix:\n",
      "    include:\n",
      "      - image: swift:6.3\n",
      "container: ${{ matrix.image }}\n",
    ].join(""),
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

test("an up to date Swift image in strategy.matrix passes", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "strategy:\n",
      "  matrix:\n",
      "    image: ['swift:6.4']\n",
      "container: ${{ matrix.image }}\n",
    ].join(""),
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 0, result.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an older Swift image reached through a YAML alias fails", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "SWIFT_IMAGE: &swift_image swift:6.3\n",
      "container: *swift_image\n",
    ].join(""),
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

test("an older Xcode path reached through a YAML alias fails", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "XCODE: &xcode_dir /Applications/Xcode_27.0.app/Contents/Developer\n",
      "DEVELOPER_DIR: *xcode_dir\n",
    ].join(""),
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\.github\/workflows\/ci\.yml/);
    assert.match(result.stderr, /27\.0/);
    assert.match(result.stderr, /27\.1/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an unquoted float xcode-version below the minimum fails and counts as a pin", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": "xcode-version: 16.0\n",
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\.github\/workflows\/ci\.yml/);
    assert.match(result.stderr, /version xcode 16\.0 /);
    assert.match(result.stderr, /27\.1/);
    assert.doesNotMatch(result.stdout, /aucune version Xcode fixée/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an integer xcode-version is compared with the minimum", () => {
  const cases = [
    { body: "xcode-version: 16\n", status: 1 },
    { body: "xcode-version: '16'\n", status: 1 },
    { body: "xcode-version: 27\n", status: 1 },
    { body: "xcode-version: 28\n", status: 0 },
  ];
  for (const { body, status } of cases) {
    const dir = tree({
      ".github/toolchain-min.txt": MIN,
      ".github/workflows/ci.yml": body,
    });
    try {
      const result = run(dir);
      assert.equal(result.status, status, `${body} stderr=${result.stderr}`);
      if (status === 1) {
        assert.match(result.stderr, /\.github\/workflows\/ci\.yml/);
        assert.match(result.stderr, /27\.1/);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

test("more aliases than the library limit fail as invalid YAML", () => {
  const aliases = Array.from({ length: 101 }, () => "*a").join(", ");
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": `x: &a foo\nseq: [${aliases}]\n`,
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\.github\/workflows\/ci\.yml/);
    assert.match(result.stderr, /YAML invalide/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an alias without an anchor fails as invalid YAML", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": "container: *missing\n",
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\.github\/workflows\/ci\.yml/);
    assert.match(result.stderr, /YAML invalide/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a self-referencing alias ends without looping", { timeout: 5000 }, () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": ["a: &a\n", "  b: *a\n", "container: swift:6.4\n"].join(""),
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 0, result.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an older xcode-version matrix shared by alias fails when first reached under another key", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "strategy:\n",
      "  matrix:\n",
      '    version: &versions ["27.0"]\n',
      "    xcode-version: *versions\n",
    ].join(""),
  });
  try {
    const result = run(dir);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\.github\/workflows\/ci\.yml/);
    assert.match(result.stderr, /27\.0/);
    assert.match(result.stderr, /27\.1/);
    assert.doesNotMatch(result.stdout, /aucune version Xcode fixée/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an older Swift image in a matrix version column fails", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "strategy: { matrix: { version: ['swift:6.3'] } }\n",
      "container: ${{ matrix.version }}\n",
    ].join(""),
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

test("an older Swift image matrix shared by alias fails when first reached under another key", () => {
  const dir = tree({
    ".github/toolchain-min.txt": MIN,
    ".github/workflows/ci.yml": [
      "strategy:\n",
      "  matrix:\n",
      '    version: &images ["swift:6.3"]\n',
      "    image: *images\n",
    ].join(""),
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

test("ci.yml runs the checker on ubuntu-latest", () => {
  const ci = readFileSync(join(root, ".github/workflows/ci.yml"), "utf8");
  const job = ci.slice(ci.indexOf("  toolchain-min:"));
  assert.match(job, /runs-on: ubuntu-latest\n/);
  assert.match(job, /npm ci/);
  assert.match(job, /node scripts\/check-toolchain-min\.mjs/);
});
