"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const {
  DEFAULT_SCHEMA,
  SKILL_ROOT,
  UI_CORE_ONLY_TESTING,
  onlyTestingArgs,
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
  assert.equal(json.ui_plan, "none");
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
  assert.ok(json.features.includes("app-shell"));
  assert.equal(json.ui_plan, "ui-full");
});

test("Resources/Localizable.xcstrings classe en ui", () => {
  const res = run(["--dry-run", "--files", "HermedBots/Resources/Localizable.xcstrings"]);
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.path, "ui");
  assert.equal(json.needs_ui, true);
  assert.equal(json.ok, true);
  assert.ok(json.features.includes("app-shell"));
  assert.equal(json.ui_plan, "ui-full");
});

test("Resources/Localizable.xcstrings en fast_suspended si UI indisponible", () => {
  const res = run([
    "--dry-run",
    "--files",
    "HermedBots/Resources/Localizable.xcstrings",
    "--ui-unavailable",
  ]);
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.path, "fast_suspended");
  assert.equal(json.needs_ui, true);
  assert.equal(json.ok, true);
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

function writeTempMap(payload) {
  const dir = mkdtempSync(join(tmpdir(), "hv-classify-map-"));
  const file = join(dir, "map.v1.json");
  writeFileSync(file, `${JSON.stringify(payload)}\n`);
  return { dir, file };
}

test("carte paths:[{}] : ok=false, erreur explicite, pas de classement fast", () => {
  const tmp = writeTempMap({
    version: 1,
    features: [{ id: "ui", paths: [{}] }],
  });
  try {
    const res = run([
      "--dry-run",
      "--files",
      "HermedBots/Bots/BotListView.swift",
      "--feature-map",
      tmp.file,
    ]);
    assert.notEqual(res.status, 0);
    const json = parseOut(res);
    assertSchema(json);
    assert.equal(json.ok, false);
    assert.equal(json.path, "fast");
    assert.equal(json.needs_ui, false);
    assert.match(json.errors.join("\n"), /glob manquant/);
  } finally {
    rmSync(tmp.dir, { recursive: true, force: true });
  }
});

test("fonctionnalité nulle : JSON ok=false, pas d'exception", () => {
  const tmp = writeTempMap({
    version: 1,
    features: [null],
  });
  try {
    const res = run([
      "--dry-run",
      "--files",
      "HermedBots/Bots/BotListView.swift",
      "--feature-map",
      tmp.file,
    ]);
    assert.equal(res.error, undefined);
    assert.notEqual(res.status, 0);
    const json = parseOut(res);
    assertSchema(json);
    assert.equal(json.ok, false);
    assert.match(json.errors.join("\n"), /fonctionnalité nulle/);
  } finally {
    rmSync(tmp.dir, { recursive: true, force: true });
  }
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
  assert.deepEqual(Object.keys(json).sort(), ["errors", "features", "mode", "needs_ui", "ok", "path", "ui_plan"]);
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

test("Feature Map : SixActions seul choisit ui-core", () => {
  const res = run(["--dry-run", "--files", "HermedBotsUITests/SixActions.swift"]);
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.path, "ui");
  assert.equal(json.ui_plan, "ui-core");
  assert.deepEqual(onlyTestingArgs(json.ui_plan), UI_CORE_ONLY_TESTING.map((id) => `-only-testing:${id}`));
});

test("Feature Map : LaunchTests et Errors (HD12Video) restent ui-core", () => {
  const res = run([
    "--dry-run",
    "--files",
    "HermedBotsUITests/LaunchTests.swift,HermedBotsUITests/Errors.swift",
  ]);
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.ui_plan, "ui-core");
});

test("Feature Map : Swift d'interface force ui-full", () => {
  const res = run(["--dry-run", "--files", "HermedBots/Bots/BotList.swift"]);
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.ui_plan, "ui-full");
  assert.deepEqual(onlyTestingArgs(json.ui_plan), []);
});

test("Feature Map : captures et profils forcent ui-full", () => {
  for (const file of [
    "HermedBotsUITests/Piste1Shots.swift",
    "HermedBotsUITests/ProfileKeys.swift",
    "HermedBotsUITests/Compat.swift",
    "HermedBotsUITests/VersionProfiles.swift",
    "HermedBotsUITests/DesignShots.swift",
    "baselines/hd08-bots.png",
  ]) {
    const res = run(["--dry-run", "--files", file]);
    assert.equal(res.status, 0, res.stderr);
    const json = parseOut(res);
    assertSchema(json);
    assert.equal(json.path, "ui", file);
    assert.equal(json.ui_plan, "ui-full", file);
  }
});

test("Feature Map : Swift d'interface + tests core = ui-full", () => {
  const res = run([
    "--dry-run",
    "--files",
    "HermedBotsUITests/SixActions.swift,HermedBots/Conversation/Conversation.swift",
  ]);
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.ui_plan, "ui-full");
});

test("Feature Map : Swift d'interface hors carte force ui-full", () => {
  const res = run(["--dry-run", "--files", "HermedBots/Unmapped/NewScreen.swift"]);
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.path, "ui");
  assert.equal(json.needs_ui, true);
  assert.equal(json.ui_plan, "ui-full");
});

test("Feature Map : Secrets.swift n'ouvre pas de passe UI", () => {
  const res = run(["--dry-run", "--files", "HermedBots/Secrets/SecretStore.swift"]);
  assert.equal(res.status, 0, res.stderr);
  const json = parseOut(res);
  assertSchema(json);
  assert.equal(json.path, "fast");
  assert.equal(json.ui_plan, "none");
});

test("Feature Map : doute (autre test UI) choisit ui-full si ui_plan full, sinon ui-core", () => {
  const tunnel = run(["--dry-run", "--files", "HermedBotsUITests/TunnelTests.swift"]);
  assert.equal(tunnel.status, 0, tunnel.stderr);
  assert.equal(parseOut(tunnel).ui_plan, "ui-core");
});

test("hv-run et hv-vm-ui filtrent ui-core par -only-testing", () => {
  const runSh = readFileSync(join(SKILL_ROOT, "scripts", "hv-run.sh"), "utf8");
  const vmUi = readFileSync(join(SKILL_ROOT, "scripts", "hv-vm-ui.py"), "utf8");
  for (const src of [runSh, vmUi]) {
    assert.match(src, /HV_UI_PLAN/);
    assert.match(src, /-only-testing:HermedBotsUITests\/SixActions/);
    assert.match(src, /-only-testing:HermedBotsUITests\/LaunchTests/);
    assert.match(src, /-only-testing:HermedBotsUITests\/HD12Video/);
  }
});

test("plans XCTest : ui-core sélectionne SixActions LaunchTests HD12Video", () => {
  const core = JSON.parse(readFileSync(join(SKILL_ROOT, "..", "..", "..", "TestPlans", "UICore.xctestplan"), "utf8"));
  const full = JSON.parse(readFileSync(join(SKILL_ROOT, "..", "..", "..", "TestPlans", "UIFull.xctestplan"), "utf8"));
  const selected = core.testTargets[0].selectedTests;
  assert.deepEqual([...selected].sort(), ["HD12Video", "LaunchTests", "SixActions"]);
  assert.equal(core.testTargets[0].parallelizable, false);
  assert.equal(full.testTargets[0].parallelizable, false);
  assert.equal(full.testTargets[0].selectedTests, undefined);
  for (const id of ["Piste1Shots", "ProfileKeys", "Compat", "VersionProfiles"]) {
    assert.ok(!selected.includes(id), id);
  }
});
