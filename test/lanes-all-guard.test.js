"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const SPIKE07 = join(__dirname, "..", "docs", "spike", "hd07-instruments");
const SPIKE08 = join(__dirname, "..", "docs", "spike", "hd08-instruments");

// lane scripts in the order lanes-all.sh calls them (nine calls)
const LANES = [
  "lane-regression.sh",
  "run-ui.sh",
  "lane-reopen.sh",
  "lane-processes.sh",
  "lane-wrongkey.sh",
  "lane-netwatch.sh",
  "lane-secret.sh",
  "lane-processes.sh",
  "lane-reopen.sh",
];

const LANE_STUB = `#!/usr/bin/env bash
echo "$(basename "$0")" >> "$MARKER"
exit 0
`;

// snapshot / allowed come from the environment. The refusal arm is a glob
// the extractor can read (`*fixture-forbidden*)` then 22), plus `*.invalid`
// for an operator override. An accept-all stub has no such glob.
const GUARD_STUB = `#!/usr/bin/env bash
case "$1" in
  snapshot) exit "\${GUARD_SNAPSHOT:-0}" ;;
  target)
    case "$2" in
      *fixture-forbidden*) exit "\${GUARD_REFUSED:-22}" ;;
      *.invalid) exit "\${GUARD_REFUSED:-22}" ;;
      *) exit "\${GUARD_ALLOWED:-0}" ;;
    esac
    ;;
  *) exit 0 ;;
esac
`;

const ACCEPT_ALL_GUARD = `#!/usr/bin/env bash
case "$1" in
  snapshot) exit "\${GUARD_SNAPSHOT:-0}" ;;
  target) exit "\${GUARD_ALLOWED:-0}" ;;
  *) exit 0 ;;
esac
`;

const EXAMPLE_ONLY_GUARD = `#!/usr/bin/env bash
case "$1" in
  snapshot) exit 0 ;;
  target)
    case "$2" in
      *example-host*) exit 22 ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
`;

function runPass(codes, extraEnv = {}, options = {}) {
  const dir = mkdtempSync(join(tmpdir(), "lanes-all-guard-"));
  try {
    const here = join(dir, "repo", "docs", "spike", "hd07-instruments");
    const skills = join(
      dir,
      "repo",
      ".cursor",
      "skills",
      "verify-hermed-bots",
      "scripts",
    );
    mkdirSync(here, { recursive: true });
    mkdirSync(skills, { recursive: true });
    for (const file of ["lib.sh", "lanes-all.sh"]) {
      copyFileSync(join(SPIKE07, file), join(here, file));
    }
    for (const lane of new Set(LANES)) {
      writeFileSync(join(here, lane), LANE_STUB, { mode: 0o755 });
    }
    writeFileSync(join(skills, "hv-guard.sh"), options.guard || GUARD_STUB);
    chmodSync(join(skills, "hv-guard.sh"), 0o755);

    const marker = join(dir, "marker.txt");
    const result = spawnSync(
      "bash",
      [join(here, "lanes-all.sh"), join(dir, "evidence")],
      {
        encoding: "utf8",
        env: {
          PATH: process.env.PATH,
          HOME: dir,
          HV_WORK: join(dir, "work"),
          MARKER: marker,
          GUARD_SNAPSHOT: String(codes.snapshot),
          GUARD_REFUSED: String(codes.refused),
          GUARD_ALLOWED: String(codes.allowed),
          ...extraEnv,
        },
      },
    );
    const started = existsSync(marker)
      ? readFileSync(marker, "utf8").split("\n").filter(Boolean)
      : [];
    return { status: result.status, output: result.stdout + result.stderr, started };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function runLibRequire(spike, extraEnv = {}, options = {}) {
  const dir = mkdtempSync(join(tmpdir(), "lib-forbidden-"));
  try {
    const here = join(dir, "repo", "docs", "spike", "hd-lib");
    const skills = join(
      dir,
      "repo",
      ".cursor",
      "skills",
      "verify-hermed-bots",
      "scripts",
    );
    mkdirSync(here, { recursive: true });
    mkdirSync(skills, { recursive: true });
    copyFileSync(join(spike, "lib.sh"), join(here, "lib.sh"));
    writeFileSync(join(skills, "hv-guard.sh"), options.guard || GUARD_STUB);
    chmodSync(join(skills, "hv-guard.sh"), 0o755);
    const harness = join(here, "harness.sh");
    writeFileSync(
      harness,
      `#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"
echo "SSH_HOST=$SSH_HOST"
require_forbidden_target
echo REQUIRE_OK
`,
      { mode: 0o755 },
    );
    const result = spawnSync("bash", [harness], {
      encoding: "utf8",
      env: {
        PATH: process.env.PATH,
        HOME: dir,
        HV_WORK: join(dir, "work"),
        GUARD_SNAPSHOT: "0",
        GUARD_REFUSED: "22",
        GUARD_ALLOWED: "0",
        ...extraEnv,
      },
    });
    return { status: result.status, output: result.stdout + result.stderr };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

for (const code of [20, 21]) {
  test(`snapshot code ${code} stops the pass with that code before any lane`, () => {
    const run = runPass({ snapshot: code, refused: 22, allowed: 0 });
    assert.equal(run.status, code, run.output);
    assert.deepEqual(run.started, []);
    assert.match(run.output, /RESULT FAIL/);
    assert.doesNotMatch(run.output, /RESULT OK/);
  });
}

test("refused target returning 0 instead of 22 stops the pass before any lane", () => {
  const run = runPass({ snapshot: 0, refused: 0, allowed: 0 });
  assert.notEqual(run.status, 0, run.output);
  assert.deepEqual(run.started, []);
  assert.match(run.output, /forbidden-probe code 0, 22 attendu/);
  assert.doesNotMatch(run.output, /RESULT OK/);
  assert.doesNotMatch(run.output, /fixture-forbidden/);
});

test("allowed target returning 22 instead of 0 stops the pass before any lane", () => {
  const run = runPass({ snapshot: 0, refused: 22, allowed: 22 });
  assert.notEqual(run.status, 0, run.output);
  assert.deepEqual(run.started, []);
  assert.match(run.output, /host\.example code 22, 0 attendu/);
  assert.doesNotMatch(run.output, /RESULT OK/);
});

test("witness: expected guard codes run the nine lane stubs in script order", () => {
  const run = runPass({ snapshot: 0, refused: 22, allowed: 0 });
  assert.equal(run.status, 0, run.output);
  assert.deepEqual(run.started, LANES);
  assert.match(run.output, /forbidden-probe : code 22/);
  assert.match(run.output, /RESULT OK/);
});

test("without HV_FORBIDDEN_HOST the pass probes the glob derived from hv-guard.sh", () => {
  const run = runPass({ snapshot: 0, refused: 22, allowed: 0 });
  assert.equal(run.status, 0, run.output);
  assert.deepEqual(run.started, LANES);
  assert.match(run.output, /forbidden-probe : code 22/);
  assert.doesNotMatch(run.output, /example-host/);
  assert.doesNotMatch(run.output, /fixture-forbidden/);
  assert.match(run.output, /RESULT OK/);
});

test("HV_FORBIDDEN_HOST from the operator is probed and must exit 22", () => {
  const run = runPass(
    { snapshot: 0, refused: 22, allowed: 0 },
    { HV_FORBIDDEN_HOST: "operator-host.invalid" },
  );
  assert.equal(run.status, 0, run.output);
  assert.deepEqual(run.started, LANES);
  assert.match(run.output, /forbidden-probe : code 22/);
  assert.doesNotMatch(run.output, /example-host/);
});

test("without HV_FORBIDDEN_HOST an accept-all guard stops before any lane", () => {
  const run = runPass(
    { snapshot: 0, refused: 22, allowed: 0 },
    {},
    { guard: ACCEPT_ALL_GUARD },
  );
  assert.notEqual(run.status, 0, run.output);
  assert.deepEqual(run.started, []);
  assert.match(run.output, /no forbidden probe from hv-guard\.sh/);
  assert.doesNotMatch(run.output, /RESULT OK/);
});

test("a guard that only refuses example-host is skipped and the pass stops", () => {
  const run = runPass(
    { snapshot: 0, refused: 22, allowed: 0 },
    {},
    { guard: EXAMPLE_ONLY_GUARD },
  );
  assert.notEqual(run.status, 0, run.output);
  assert.deepEqual(run.started, []);
  assert.match(run.output, /no forbidden probe from hv-guard\.sh/);
  assert.doesNotMatch(run.output, /RESULT OK/);
});

test("hd07 lib.sh derives a forbidden probe from the guard stub", () => {
  const run = runLibRequire(SPIKE07);
  assert.equal(run.status, 0, run.output);
  assert.match(run.output, /SSH_HOST=host\.example/);
  assert.match(run.output, /forbidden-probe : code 22/);
  assert.match(run.output, /REQUIRE_OK/);
  assert.doesNotMatch(run.output, /fixture-forbidden/);
});

test("hd08 lib.sh derives a forbidden probe from the guard stub", () => {
  const run = runLibRequire(SPIKE08);
  assert.equal(run.status, 0, run.output);
  assert.match(run.output, /SSH_HOST=host\.example/);
  assert.match(run.output, /forbidden-probe : code 22/);
  assert.match(run.output, /REQUIRE_OK/);
  assert.doesNotMatch(run.output, /fixture-forbidden/);
});

test("hd07 lib.sh stops when the guard has no exit-22 glob", () => {
  const run = runLibRequire(SPIKE07, {}, { guard: ACCEPT_ALL_GUARD });
  assert.notEqual(run.status, 0, run.output);
  assert.match(run.output, /no forbidden probe from hv-guard\.sh/);
  assert.doesNotMatch(run.output, /REQUIRE_OK/);
});

test("hd08 lib.sh stops when the guard has no exit-22 glob", () => {
  const run = runLibRequire(SPIKE08, {}, { guard: ACCEPT_ALL_GUARD });
  assert.notEqual(run.status, 0, run.output);
  assert.match(run.output, /SSH_HOST=host\.example/);
  assert.match(run.output, /no forbidden probe from hv-guard\.sh/);
  assert.doesNotMatch(run.output, /REQUIRE_OK/);
});

test("hd07 lib.sh uses HV_FORBIDDEN_HOST when the operator sets it", () => {
  const run = runLibRequire(SPIKE07, { HV_FORBIDDEN_HOST: "operator-host.invalid" });
  assert.equal(run.status, 0, run.output);
  assert.match(run.output, /forbidden-probe : code 22/);
});
