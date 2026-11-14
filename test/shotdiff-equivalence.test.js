"use strict";

const assert = require("node:assert/strict");
const { readFileSync, rmSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const { tmpdir } = require("node:os");
const { mkdtempSync } = require("node:fs");
const {
  SHOTDIFF,
  captureCase,
  equivalenceCases,
  parseZone,
} = require("./shotdiff-harness.js");

const GOLDEN = join(__dirname, "fixtures/shotdiff/equivalence.json");

test("hv-shotdiff verdicts match the freeze from origin/main", () => {
  const frozen = JSON.parse(readFileSync(GOLDEN, "utf8"));
  assert.equal(frozen.frozenFrom, "origin/main");
  const specs = equivalenceCases();
  assert.equal(specs.length, frozen.cases.length);
  const parent = mkdtempSync(join(tmpdir(), "hv-eq-head-"));
  try {
    for (let i = 0; i < specs.length; i++) {
      const spec = specs[i];
      const expected = frozen.cases[i];
      assert.equal(spec.id, expected.id, `ordre figé cassé à ${i}`);
      const got = captureCase(SHOTDIFF, spec, parent);
      assert.equal(got.status, expected.status, `${spec.id} status`);
      assert.equal(got.stdout, expected.stdout, `${spec.id} stdout`);
      assert.equal(got.stderr, expected.stderr, `${spec.id} stderr`);
      assert.equal(got.zone, expected.zone, `${spec.id} zone`);
      assert.equal(parseZone(got.stdout), expected.zone, `${spec.id} zone stdout`);
    }
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
});
