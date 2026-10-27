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

const SPIKE = join(__dirname, "..", "docs", "spike", "hd07-instruments");
const HD08 = join(__dirname, "..", "docs", "spike", "hd08-instruments");

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

// exit codes come from the environment: GUARD_SNAPSHOT, GUARD_REFUSED (name ending in .invalid), GUARD_ALLOWED
const GUARD_STUB = `#!/usr/bin/env bash
case "$1" in
  snapshot) exit "\${GUARD_SNAPSHOT:-0}" ;;
  target) case "$2" in *.invalid) exit "\${GUARD_REFUSED:-22}" ;; *) exit "\${GUARD_ALLOWED:-0}" ;; esac ;;
  *) exit 0 ;;
esac
`;

function runPass(codes, extraEnv = {}) {
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
      copyFileSync(join(SPIKE, file), join(here, file));
    }
    for (const lane of new Set(LANES)) {
      writeFileSync(join(here, lane), LANE_STUB, { mode: 0o755 });
    }
    writeFileSync(join(skills, "hv-guard.sh"), GUARD_STUB);
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
  const run = runPass(
    { snapshot: 0, refused: 0, allowed: 0 },
    { HV_FORBIDDEN_HOST: "operator-host.invalid" },
  );
  assert.notEqual(run.status, 0, run.output);
  assert.deepEqual(run.started, []);
  assert.match(run.output, /HV_FORBIDDEN_HOST code 0, 22 attendu/);
  assert.doesNotMatch(run.output, /RESULT OK/);
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
  assert.match(run.output, /HV_FORBIDDEN_HOST : code 22/);
  assert.match(run.output, /RESULT OK/);
});

test("without HV_FORBIDDEN_HOST a guard that accepts every target stops the pass", () => {
  const run = runPass({ snapshot: 0, refused: 0, allowed: 0 });
  assert.notEqual(run.status, 0, run.output);
  assert.deepEqual(run.started, []);
  assert.match(run.output, /HV_FORBIDDEN_HOST code 0, 22 attendu/);
  assert.doesNotMatch(run.output, /RESULT OK/);
  assert.doesNotMatch(run.output, /HV_FORBIDDEN_HOST unset/);
});

test("HV_FORBIDDEN_HOST from the operator is probed and must exit 22", () => {
  const run = runPass(
    { snapshot: 0, refused: 22, allowed: 0 },
    { HV_FORBIDDEN_HOST: "operator-host.invalid" },
  );
  assert.equal(run.status, 0, run.output);
  assert.deepEqual(run.started, LANES);
  assert.match(run.output, /HV_FORBIDDEN_HOST : code 22/);
  assert.doesNotMatch(run.output, /example-host/);
});

function runHd08Probe(codes, extraEnv = {}) {
  const dir = mkdtempSync(join(tmpdir(), "hd08-lib-"));
  try {
    const here = join(dir, "repo", "docs", "spike", "hd08-instruments");
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
    copyFileSync(join(HD08, "lib.sh"), join(here, "lib.sh"));
    writeFileSync(join(skills, "hv-guard.sh"), GUARD_STUB);
    chmodSync(join(skills, "hv-guard.sh"), 0o755);
    const result = spawnSync(
      "bash",
      [
        "-c",
        'set -u; . "$LIB"; echo "SSH_HOST=$SSH_HOST"; require_forbidden_target; echo PROBE_OK',
      ],
      {
        encoding: "utf8",
        env: {
          PATH: process.env.PATH,
          HOME: dir,
          HV_WORK: join(dir, "work"),
          LIB: join(here, "lib.sh"),
          GUARD_SNAPSHOT: String(codes.snapshot),
          GUARD_REFUSED: String(codes.refused),
          GUARD_ALLOWED: String(codes.allowed),
          ...extraEnv,
        },
      },
    );
    return { status: result.status, output: result.stdout + result.stderr };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("hd08 lib.sh sources under set -u and the correct guard accepts the default probe", () => {
  const run = runHd08Probe({ snapshot: 0, refused: 22, allowed: 0 });
  assert.equal(run.status, 0, run.output);
  assert.match(run.output, /SSH_HOST=host\.example/);
  assert.match(run.output, /HV_FORBIDDEN_HOST : code 22/);
  assert.match(run.output, /PROBE_OK/);
});

test("hd08 without HV_FORBIDDEN_HOST a guard that accepts every target fails", () => {
  const run = runHd08Probe({ snapshot: 0, refused: 0, allowed: 0 });
  assert.notEqual(run.status, 0, run.output);
  assert.match(run.output, /SSH_HOST=host\.example/);
  assert.match(run.output, /HV_FORBIDDEN_HOST code 0, 22 attendu/);
  assert.doesNotMatch(run.output, /PROBE_OK/);
  assert.doesNotMatch(run.output, /RESULT OK/);
});
