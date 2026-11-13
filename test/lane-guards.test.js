"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
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

test("hd11, hd13 and hd14 run-ui.sh emit HV_TEST_API_KEYS like hd15 before xcodebuild", () => {
  const files = [
    join(SPIKE, "hd11-instruments", "run-ui.sh"),
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
    assert.doesNotMatch(text, /HV_TEST_API_KEYS=["']/, `${rel} : clé en dur`);
  }
  for (const lane of ["hd11", "hd13"]) {
    const text = readFileSync(join(SPIKE, `${lane}-instruments`, "run-ui.sh"), "utf8");
    assert.match(
      text,
      /python3 - "\$ROOT\/Packages\/HermesAdapter\/Tests\/HermesAdapterTests\/Fixtures\/hermes-current\/contract\.json"/,
      `${lane} : contract.json hors ROOT`,
    );
  }
});

test("hd13 run-ui.sh copies fake-requests.json in the EXIT trap before down fake", () => {
  const text = readFileSync(join(SPIKE, "hd13-instruments", "run-ui.sh"), "utf8");
  const match = text.match(/^trap '([^']*)' EXIT$/m);
  assert.ok(match, "hd13 : trap EXIT introuvable");
  const trap = match[1];
  const curlAt = trap.indexOf("curl ");
  const downAt = trap.indexOf("down fake");
  assert.ok(curlAt !== -1, "hd13 : curl absent du trap");
  assert.ok(downAt !== -1, "hd13 : down fake absent du trap");
  assert.ok(curlAt < downAt, "hd13 : curl après down fake");
  assert.match(trap, /curl -s -m 5 http:\/\/127\.0\.0\.1:18643\/_hv\/log > "\$HV_EVIDENCE\/fake-requests\.json"/);
  assert.doesNotMatch(trap, /Authorization/i);
  assert.match(trap, /\|\| true/);

  const payload = '[{"m":"POST","p":"/p/hv-bot-a/v1/runs","s":401,"body":""}]';
  const dirs = [];
  function runTrap(curlRc, exitCode) {
    const dir = mkdtempSync(join(tmpdir(), "hd13-fake-log-"));
    dirs.push(dir);
    const evidence = join(dir, "evidence");
    mkdirSync(evidence);
    const bin = join(dir, "bin");
    mkdirSync(bin);
    const skill = join(dir, "scripts");
    mkdirSync(skill);
    const order = join(dir, "order");
    const curlArgs = join(dir, "curl.args");
    const envArgs = join(dir, "env.args");
    writeFileSync(join(bin, "curl"), `#!/bin/sh
printf '%s\\n' "$@" > ${JSON.stringify(curlArgs)}
echo curl >> ${JSON.stringify(order)}
[ ${curlRc} -eq 0 ] || exit ${curlRc}
printf '%s' ${JSON.stringify(payload)}
`);
    chmodSync(join(bin, "curl"), 0o755);
    writeFileSync(join(skill, "hv-hermes-env.sh"), `#!/bin/sh
if [ -f "$HV_EVIDENCE/fake-requests.json" ]; then
  echo down-after-copy >> ${JSON.stringify(order)}
else
  echo down-before-copy >> ${JSON.stringify(order)}
fi
printf '%s\\n' "$*" > ${JSON.stringify(envArgs)}
`);
    chmodSync(join(skill, "hv-hermes-env.sh"), 0o755);
    const run = spawnSync("bash", ["-c", `set -uo pipefail\ntrap '${trap}' EXIT\nexit ${exitCode}`], {
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        HV_EVIDENCE: evidence,
        SK: skill,
        PROXY: "1999999999",
        STOP: join(dir, "stop"),
        SAMPLER: "1999999998",
        WATCHER: "1999999997",
      },
      encoding: "utf8",
    });
    return { evidence, order, curlArgs, envArgs, run };
  }

  try {
    const ok = runTrap(0, 42);
    assert.equal(ok.run.status, 42, `hd13 : le trap change le code de sortie (${ok.run.stderr})`);
    assert.equal(readFileSync(join(ok.evidence, "fake-requests.json"), "utf8"), payload);
    assert.deepEqual(readFileSync(ok.order, "utf8").trim().split("\n"), ["curl", "down-after-copy"]);
    assert.equal(readFileSync(ok.envArgs, "utf8").trim(), "down fake");
    const args = readFileSync(ok.curlArgs, "utf8").trim().split("\n");
    assert.deepEqual(args, ["-s", "-m", "5", "http://127.0.0.1:18643/_hv/log"]);
    assert.doesNotMatch(args.join(" "), /Authorization/i);

    const fail = runTrap(22, 7);
    assert.equal(fail.run.status, 7, `hd13 : curl en échec fait échouer la lane (${fail.run.stderr})`);
    assert.deepEqual(readFileSync(fail.order, "utf8").trim().split("\n"), ["curl", "down-after-copy"]);
    assert.equal(readFileSync(fail.envArgs, "utf8").trim(), "down fake");
  } finally {
    for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
  }
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
