"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdtempSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const script = join(__dirname, "..", "docs", "spike", "hd07-instruments", "perf-summary.py");

// une ligne de perf.txt : `<côté> <numéro> rc=<code de xcodebuild> HV-PERF07 mode=<mode> ms=<durée>`
function row(side, index, ms, rc = 0) {
  const value = ms === null ? "ÉCHEC" : String(ms);
  return `${side} ${index} rc=${rc} HV-PERF07 mode=${side === "trunk" ? "direct" : "tunnel"} ms=${value}`;
}

function summarize(lines, count = 5) {
  const dir = mkdtempSync(join(tmpdir(), "perf-summary-"));
  const file = join(dir, "perf.txt");
  writeFileSync(file, lines.join("\n") + "\n");
  try {
    return spawnSync("python3", ["-I", script, file, String(count)], { encoding: "utf8" });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function series(side, values, rcs = []) {
  return values.map((ms, i) => row(side, i + 1, ms, rcs[i] ?? 0));
}

test("five valid measures per side within the budget give OK", () => {
  const result = summarize([
    ...series("trunk", [567, 525, 695, 616, 543]),
    ...series("head", [898, 841, 773, 641, 766]),
  ]);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /médiane 567 ms/);
  assert.match(result.stdout, /médiane 773 ms/);
  assert.match(result.stdout, /RESULT OK/);
});

test("one valid measure and four failures per side give FAIL", () => {
  const result = summarize([
    ...series("trunk", [567, null, null, null, null], [0, 65, 65, 65, 65]),
    ...series("head", [773, null, null, null, null], [0, 65, 65, 65, 65]),
  ]);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /RESULT FAIL/);
  assert.match(result.stdout, /trunk : 1 mesure valide sur 5/);
});

test("a measure printed by a run whose xcodebuild failed is not counted", () => {
  const result = summarize([
    ...series("trunk", [567, 525, 695, 616, 543]),
    ...series("head", [898, 841, 773, 641, 766], [0, 0, 65, 0, 0]),
  ]);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /RESULT FAIL/);
  assert.match(result.stdout, /head : 4 mesures valides sur 5/);
});

test("more measures than asked give FAIL", () => {
  const result = summarize([
    ...series("trunk", [567, 525, 695, 616, 543, 500]),
    ...series("head", [898, 841, 773, 641, 766]),
  ]);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /trunk : 6 mesures valides sur 5/);
});

test("a head median more than 2000 ms above the trunk median gives FAIL", () => {
  const result = summarize([
    ...series("trunk", [500, 500, 500, 500, 500]),
    ...series("head", [2600, 2600, 2600, 2600, 2600]),
  ]);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /écart de médianes head - trunk : \+2100 ms/);
  assert.match(result.stdout, /RESULT FAIL/);
});

test("an empty file gives FAIL without a traceback", () => {
  const result = summarize([]);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.doesNotMatch(result.stderr, /Traceback/);
});
