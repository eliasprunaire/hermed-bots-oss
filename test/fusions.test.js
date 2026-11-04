"use strict";

const assert = require("node:assert/strict");
const { mkdtempSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");
const {
  checkMarkdown,
  checkRoot,
  main,
} = require("../scripts/check-fusions.js");

const root = join(__dirname, "..");
const SHA = "e7e1cd23f140143eef6b14f6fdbdca7c9086706b";

function header() {
  return [
    "# Fusions",
    "",
    "| date | PR | sha de squash | vérificateur |",
    "| --- | --- | --- | --- |",
  ].join("\n");
}

test("the live journal is well formed", () => {
  assert.deepEqual(checkRoot(root), []);
  assert.equal(main([]), 0);
});

test("an empty table with the required header exits 0", () => {
  const errors = checkMarkdown(`${header()}\n`, "docs/fusions.md");
  assert.deepEqual(errors, []);
});

test("a complete well-formed row exits 0", () => {
  const text = `${header()}\n| 2026-11-04 | #94 | ${SHA} | app-pilote-verifier[bot] |\n`;
  assert.deepEqual(checkMarkdown(text, "docs/fusions.md"), []);
});

test("a malformed date fails", () => {
  const text = `${header()}\n| 2026-13-40 | #1 | ${SHA} | v |\n`;
  const errors = checkMarkdown(text, "docs/fusions.md");
  assert.ok(errors.some((line) => line.includes("malformed date")));
});

test("a malformed PR fails", () => {
  const text = `${header()}\n| 2026-11-04 | pr-1 | ${SHA} | v |\n`;
  const errors = checkMarkdown(text, "docs/fusions.md");
  assert.ok(errors.some((line) => line.includes("malformed PR")));
});

test("a malformed squash sha fails", () => {
  const text = `${header()}\n| 2026-11-04 | 1 | deadbeef | v |\n`;
  const errors = checkMarkdown(text, "docs/fusions.md");
  assert.ok(errors.some((line) => line.includes("malformed sha de squash")));
});

test("an empty verifier fails", () => {
  const text = `${header()}\n| 2026-11-04 | 1 | ${SHA} |  |\n`;
  const errors = checkMarkdown(text, "docs/fusions.md");
  assert.ok(errors.some((line) => line.includes("empty vérificateur")));
});

test("a row with the wrong number of cells fails", () => {
  const text = `${header()}\n| 2026-11-04 | 1 | ${SHA} |\n`;
  const errors = checkMarkdown(text, "docs/fusions.md");
  assert.ok(errors.some((line) => line.includes("expected 4 cells")));
});

test("a missing header fails", () => {
  const errors = checkMarkdown("# Fusions\n\nrien\n", "docs/fusions.md");
  assert.ok(errors.some((line) => line.includes("missing table header")));
});

test("a missing file fails", () => {
  const dir = mkdtempSync(join(tmpdir(), "fusions-"));
  try {
    const file = join(dir, "missing.md");
    writeFileSync(join(dir, "ok.md"), "x\n");
    const code = main(["--file", file]);
    assert.equal(code, 1);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
