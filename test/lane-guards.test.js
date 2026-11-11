"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { chmodSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir, userInfo } = require("node:os");
const { join, relative } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const SPIKE = join(ROOT, "docs", "spike");

function scripts(dir = SPIKE) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return scripts(path);
    return /\.(sh|py)$/.test(entry.name) ? [path] : [];
  });
}

const ALL = scripts();
const SHELL = ALL.filter((path) => path.endsWith(".sh"));
const PYTHON = ALL.filter((path) => path.endsWith(".py"));
const name = (path) => relative(ROOT, path);

test("no lane script keeps the empty VM guard or the old skill path (issue #87)", () => {
  assert.ok(ALL.length > 40, `trop peu de scripts trouvés : ${ALL.length}`);
  for (const path of ALL) {
    const text = readFileSync(path, "utf8");
    assert.doesNotMatch(text, /\[ "\$HOME" =\s+\]/, `${name(path)} : garde de VM vide`);
    assert.doesNotMatch(text, /\.cursor\/skills\/verify-hermed-bots/, `${name(path)} : ancien chemin de skill`);
  }
});

// la garde seule, sortie de son script : elle s'ouvre pour le compte de la VM de test et se ferme pour tout autre
test("every VM guard opens for the test VM account and closes for any other account", () => {
  const stub = mkdtempSync(join(tmpdir(), "lane-guard-"));
  try {
    writeFileSync(join(stub, "id"), '#!/bin/sh\necho hvtest\n');
    chmodSync(join(stub, "id"), 0o755);
    const guarded = SHELL.map((path) => [path, readFileSync(path, "utf8").split("\n").find((line) => line.includes("VM hvtest requise"))])
      .filter(([, line]) => line);
    assert.ok(guarded.length >= 15, `trop peu de gardes trouvées : ${guarded.length}`);
    for (const [path, line] of guarded) {
      const env = { ...process.env, HV_XCTESTRUN: "x" };
      const inVM = spawnSync("bash", ["-c", `${line}\necho OPEN`], { env: { ...env, PATH: `${stub}:${process.env.PATH}` }, encoding: "utf8" });
      assert.equal(inVM.stdout.trim(), "OPEN", `${name(path)} : la garde refuse le compte de la VM (${inVM.stderr.trim()})`);
      if (userInfo().username !== "hvtest") {
        const host = spawnSync("bash", ["-c", `${line}\necho OPEN`], { env, encoding: "utf8" });
        assert.equal(host.status, 2, `${name(path)} : la garde laisse passer un autre compte`);
        assert.match(host.stdout, /VM hvtest requise/, `${name(path)} : message de garde absent`);
      }
    }
  } finally {
    rmSync(stub, { recursive: true, force: true });
  }
});

test("hd13 and hd14 run-ui.sh emit HV_TEST_API_KEYS like hd15 before xcodebuild", () => {
  const files = [
    join(SPIKE, "hd13-instruments", "run-ui.sh"),
    join(SPIKE, "hd14-instruments", "run-ui.sh"),
    join(SPIKE, "hd15-instruments", "run-ui.sh"),
  ];
  for (const path of files) {
    const text = readFileSync(path, "utf8");
    const rel = relative(ROOT, path);
    assert.match(
      text,
      /HV_TEST_API_KEYS=\$\(python3 - .*contract\.json"? <<'PYKEYS'/,
      `${rel} : bloc python3/contract.json absent`,
    );
    assert.match(text, /secrets\.token_urlsafe\(32\)/, `${rel} : token_urlsafe(32) absent`);
    assert.match(text, /\["profiles"\]\["served"\]/, `${rel} : profiles.served absent`);
    assert.match(text, /\) \|\| exit 32/, `${rel} : || exit 32 absent`);
    assert.match(
      text,
      /export HV_TEST_API_KEYS TEST_RUNNER_HV_TEST_API_KEYS=\$HV_TEST_API_KEYS/,
      `${rel} : export des deux variables absent`,
    );
    const exported = text.indexOf("export HV_TEST_API_KEYS TEST_RUNNER_HV_TEST_API_KEYS=$HV_TEST_API_KEYS");
    const xcode = text.indexOf("xcodebuild test-without-building");
    assert.ok(exported !== -1 && xcode !== -1 && exported < xcode, `${rel} : export après xcodebuild`);
  }
  const hd13 = readFileSync(join(SPIKE, "hd13-instruments", "run-ui.sh"), "utf8");
  assert.match(
    hd13,
    /python3 - "\$ROOT\/Packages\/HermesAdapter\/Tests\/HermesAdapterTests\/Fixtures\/hermes-current\/contract\.json"/,
    "hd13 : contract.json hors ROOT",
  );
});

test("every skill path follows HV_SKILL_SCRIPTS", () => {
  const assignments = SHELL.flatMap((path) => readFileSync(path, "utf8").split("\n").filter((line) => /^SK=/.test(line)).map((line) => [path, line]));
  assert.ok(assignments.length >= 10, `trop peu de lignes SK= trouvées : ${assignments.length}`);
  for (const [path, line] of assignments) {
    const env = { ...process.env, HV_SKILL_SCRIPTS: "/skill/scripts", ROOT: "/root", REPO: "/repo", HERE: "/here" };
    const run = spawnSync("bash", ["-c", `${line}\nprintf %s "$SK"`], { env, encoding: "utf8" });
    assert.equal(run.stdout, "/skill/scripts", `${name(path)} : SK ignore HV_SKILL_SCRIPTS (${line})`);
  }
  for (const path of [...SHELL, ...PYTHON]) {
    const text = readFileSync(path, "utf8");
    if (/hv-[a-z-]+\.(sh|py)/.test(text) && /local-skills/.test(text)) {
      assert.match(text, /HV_SKILL_SCRIPTS/, `${name(path)} : chemin de skill sans HV_SKILL_SCRIPTS`);
    }
  }
});
