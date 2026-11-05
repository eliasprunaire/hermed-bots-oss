"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdirSync, mkdtempSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const {
  DEFAULT_SCHEMA,
  SKILL_ROOT,
  validateAgainstSchema,
} = require("../scripts/hv-classify.js");

const CLI = join(SKILL_ROOT, "scripts", "hv-classify.js");
const SCHEMA = require(DEFAULT_SCHEMA);
const FIXTURES = join(SKILL_ROOT, "test", "fixtures");

function run(args, env = {}) {
  return spawnSync(process.execPath, [CLI, ...args], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
}

function parseOut(res) {
  return JSON.parse(res.stdout.trim());
}

function assertSchema(payload) {
  const errors = validateAgainstSchema(payload, SCHEMA);
  assert.deepEqual(errors, [], errors.join("; "));
}

test("fixture fast: hors UI, path=fast", () => {
  const res = run(["--dry-run", "--files-from", join(FIXTURES, "fast", "files.txt")]);
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.path, "fast");
  assert.equal(json.needs_ui, false);
  assert.equal(json.ok, true);
  assert.deepEqual(json.errors, []);
  assert.ok(json.features.includes("hermes-adapter"));
  assert.ok(json.features.includes("sparkle-update"));
  assert.equal(json.mode, "full");
});

test("fixture ui: fichiers UI, path=ui", () => {
  const res = run(["--dry-run", "--files-from", join(FIXTURES, "ui", "files.txt")]);
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.path, "ui");
  assert.equal(json.needs_ui, true);
  assert.equal(json.ok, true);
  assert.ok(json.features.includes("bot-list"));
  assert.ok(json.features.includes("conversation"));
});

test("fixture fast_suspended: UI requise, VM indisponible", () => {
  const res = run([
    "--dry-run",
    "--files-from",
    join(FIXTURES, "fast_suspended", "files.txt"),
    "--ui-unavailable",
  ]);
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.path, "fast_suspended");
  assert.equal(json.needs_ui, true);
  assert.equal(json.ok, true);
  assert.ok(json.features.includes("connection"));
  assert.ok(json.features.includes("app-shell"));
});

test("HV_UI_UNAVAILABLE=1 classe aussi en fast_suspended", () => {
  const res = run(
    ["--dry-run", "--files", "HermedBots/Bots/BotListView.swift"],
    { HV_UI_UNAVAILABLE: "1" },
  );
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.path, "fast_suspended");
});

test("feature map absente: exit ≠ 0, ok=false, erreur explicite", () => {
  const res = run([
    "--dry-run",
    "--files",
    "Packages/HermesAdapter/Sources/HermesAdapter/Contract.swift",
    "--feature-map",
    join(FIXTURES, "missing", "map.v1.json"),
  ]);
  assert.notEqual(res.status, 0);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.ok, false);
  assert.equal(json.path, "fast");
  assert.match(json.errors.join("\n"), /feature map absente/);
});

test("la sortie dry-run valide le schéma v1", () => {
  const res = run(["--dry-run", "--files", "README.md"]);
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.deepEqual(Object.keys(json).sort(), ["errors", "features", "mode", "needs_ui", "ok", "path"]);
});

test("mode light si même patch-id et PR déjà PASS", () => {
  const res = run([
    "--dry-run",
    "--files",
    "Packages/HermesAdapter/Sources/HermesAdapter/Contract.swift",
    "--same-patch-id",
    "--pr-pass",
  ]);
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.mode, "light");
});

test("label needs-full-verify force full", () => {
  const res = run([
    "--dry-run",
    "--files",
    "Packages/HermesAdapter/Sources/HermesAdapter/Contract.swift",
    "--same-patch-id",
    "--pr-pass",
    "--label",
    "needs-full-verify",
  ]);
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.mode, "full");
});

test("doctor détecte un fichier de skill manquant", () => {
  const root = mkdtempSync(join(tmpdir(), "hv-classify-doctor-"));
  try {
    mkdirSync(join(root, "features"), { recursive: true });
    mkdirSync(join(root, "schema"), { recursive: true });
    mkdirSync(join(root, "scripts"), { recursive: true });
    writeFileSync(join(root, "features", "README.md"), "x\n");
    writeFileSync(join(root, "features", "map.v1.json"), "{\"version\":1,\"features\":[]}\n");
    writeFileSync(join(root, "schema", "dry-run.v1.json"), "{}\n");
    writeFileSync(join(root, "scripts", "hv-classify.js"), "x\n");
    const res = run(["doctor", "--skill-root", root]);
    assert.notEqual(res.status, 0);
    const json = JSON.parse(res.stdout.trim());
    assert.equal(json.ok, false);
    assert.deepEqual(json.missing, ["SKILL.md"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("doctor du skill réel est ok", () => {
  const res = run(["doctor"]);
  assert.equal(res.status, 0, res.stderr);
  const json = JSON.parse(res.stdout.trim());
  assert.equal(json.ok, true);
  assert.deepEqual(json.missing, []);
});
