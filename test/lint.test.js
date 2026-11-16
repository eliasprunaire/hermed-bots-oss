"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdtempSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const root = join(__dirname, "..");

function runLint(args) {
  const npmArgs = ["run", "lint"];
  if (args.length > 0) {
    npmArgs.push("--", ...args);
  }
  return spawnSync("npm", npmArgs, {
    cwd: root,
    encoding: "utf8",
  });
}

// npm 12+ répète les arguments du script dans stdout/stderr
function pointFinalDiagnostics(result) {
  return `${result.stdout || ""}\n${result.stderr || ""}`
    .split(/\r?\n/)
    .filter((line) => /:\d+: POINT_FINAL/.test(line))
    .join("\n");
}

test("npm run lint exits 0", () => {
  const result = runLint([]);
  assert.equal(result.status, 0, result.stderr);
});

test("lint exits non-zero when a path has a syntax error", () => {
  const dir = mkdtempSync(join(tmpdir(), "lint-bad-"));
  const file = join(dir, "bad.js");
  writeFileSync(file, "function (\n");
  try {
    const result = runLint([file]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /SyntaxError/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("lint exits non-zero when a comment ends with a period", () => {
  const dir = mkdtempSync(join(tmpdir(), "lint-period-bad-"));
  const file = join(dir, "bad.js");
  writeFileSync(file, "// commentaire fautif.\n");
  try {
    const result = runLint([file]);
    assert.notEqual(result.status, 0, result.stderr);
    assert.match(result.stderr, /POINT_FINAL/);
    assert.doesNotMatch(result.stderr, /SyntaxError/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("lint exits 0 when a comment has no final period", () => {
  const dir = mkdtempSync(join(tmpdir(), "lint-period-ok-"));
  const file = join(dir, "ok.js");
  writeFileSync(file, "// commentaire conforme\n");
  try {
    const result = runLint([file]);
    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(result.stderr, /POINT_FINAL/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("lint exits 0 when a comment ends with an ellipsis", () => {
  const dir = mkdtempSync(join(tmpdir(), "lint-period-ellipsis-"));
  const file = join(dir, "ok.js");
  writeFileSync(file, "// suite...\n");
  try {
    const result = runLint([file]);
    assert.equal(result.status, 0, result.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("lint exits non-zero on a shell comment with a final period", () => {
  const dir = mkdtempSync(join(tmpdir(), "lint-period-sh-"));
  const file = join(dir, "bad.sh");
  writeFileSync(file, "#!/bin/sh\n# commentaire fautif.\n");
  try {
    const result = runLint([file]);
    assert.notEqual(result.status, 0, result.stderr);
    assert.match(result.stderr, /POINT_FINAL/);
    assert.doesNotMatch(result.stderr, /SyntaxError/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("lint exits 0 when a JS template line looks like a comment with a period", () => {
  const dir = mkdtempSync(join(tmpdir(), "lint-period-js-template-"));
  const file = join(dir, "ok.js");
  writeFileSync(
    file,
    ["const text = `", "// Ceci est une donnée.", "`;", ""].join("\n"),
  );
  try {
    const result = runLint([file]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(pointFinalDiagnostics(result), "");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("lint exits 0 when a Python triple-quoted line looks like a comment with a period", () => {
  const dir = mkdtempSync(join(tmpdir(), "lint-period-py-triple-"));
  const file = join(dir, "ok.py");
  writeFileSync(
    file,
    ["text = \"\"\"", "# Ceci est une donnée.", "\"\"\"", ""].join("\n"),
  );
  try {
    const result = runLint([file]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(pointFinalDiagnostics(result), "");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("lint exits 0 when a shell here-doc line looks like a comment with a period", () => {
  const dir = mkdtempSync(join(tmpdir(), "lint-period-sh-heredoc-"));
  const file = join(dir, "ok.sh");
  writeFileSync(
    file,
    ["cat <<EOF", "# Ceci est une donnée.", "EOF", ""].join("\n"),
  );
  try {
    const result = runLint([file]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(pointFinalDiagnostics(result), "");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("POINT_FINAL diagnostics ignore npm announcements that echo reserved paths", () => {
  const diagnostics = pointFinalDiagnostics({
    stdout: "> lint\n> node scripts/lint.js scripts/dev-lead-runner/lint-period-probe.sh\n",
    stderr: [
      "npm warn Unknown cli config",
      "tmp/bad.js:1: POINT_FINAL",
      "npm notice new major version of npm available",
    ].join("\n"),
  });
  assert.match(diagnostics, /bad\.js:1: POINT_FINAL/);
  assert.doesNotMatch(diagnostics, /dev-lead-runner/);
});

test("lint skips a period comment in reserved paths and still flags it elsewhere", () => {
  const probe = join(root, "scripts", "dev-lead-runner", "lint-period-probe.sh");
  const dir = mkdtempSync(join(tmpdir(), "lint-period-reserved-"));
  const other = join(dir, "bad.js");
  writeFileSync(probe, "# commentaire fautif.\n");
  writeFileSync(other, "// commentaire fautif.\n");
  try {
    const result = runLint([
      probe,
      join(root, "scripts", "infra-guard-ci.js"),
      other,
    ]);
    const diagnostics = pointFinalDiagnostics(result);
    assert.notEqual(result.status, 0, result.stderr);
    assert.match(diagnostics, /bad\.js:\d+: POINT_FINAL/);
    assert.doesNotMatch(diagnostics, /dev-lead-runner/);
    assert.doesNotMatch(diagnostics, /infra-guard-ci/);
    assert.doesNotMatch(result.stderr, /SyntaxError/);
  } finally {
    rmSync(probe, { force: true });
    rmSync(dir, { recursive: true, force: true });
  }
});
