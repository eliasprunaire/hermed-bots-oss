"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const http = require("node:http");
const {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const HV_RUN = join(ROOT, ".cursor/skills/verify-hermed-bots/scripts/hv-run.sh");
const HV_REGEN = join(
  ROOT,
  ".cursor/skills/verify-hermed-bots/scripts/hv-regen-baselines.sh",
);
const PIXEL = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64",
);

function freePort() {
  return new Promise((resolve, reject) => {
    const server = http.createServer();
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close((err) => (err ? reject(err) : resolve(port)));
    });
  });
}

function setup(dir) {
  const home = join(dir, "home");
  const work = join(dir, "work");
  const shim = join(dir, "shim");
  const bin = join(dir, "bin");
  const base = join(dir, "base");
  mkdirSync(home);
  mkdirSync(work);
  mkdirSync(shim);
  mkdirSync(bin);
  mkdirSync(base);
  writeFileSync(join(dir, "fake.xctestrun"), "");
  writeFileSync(join(dir, "pixel.png"), PIXEL);
  writeFileSync(join(base, "launch.png"), PIXEL);
  writeFileSync(join(base, "language-fr.png"), PIXEL);
  writeFileSync(
    join(shim, "xcodebuild"),
    '#!/usr/bin/env bash\nprintf "HV-SHOT launch\\nHV-SHOT language-fr\\n"\nexit 0\n',
    { mode: 0o755 },
  );
  writeFileSync(
    join(shim, "xcrun"),
    `#!/usr/bin/env bash
out=
while [ $# -gt 0 ]; do
  [ "$1" = --output-path ] && out=$2
  shift
done
mkdir -p "$out"
i=0
m=
for n in \${SHIM_ATTACH:-}; do
  i=$((i + 1))
  cp "\${HV_STUB_PNG}" "$out/FILE-$i.png"
  m="$m{\\"attachments\\":[{\\"exportedFileName\\":\\"FILE-$i.png\\",\\"suggestedHumanReadableName\\":\\"$\{n}_0_UUID-$i.png\\"}],\\"testIdentifier\\":\\"T/t$i()\\"},"
done
printf '[%s]' "\${m%,}" > "$out/manifest.json"
`,
    { mode: 0o755 },
  );
  chmodSync(join(shim, "xcrun"), 0o755);
  writeFileSync(join(bin, "compare"), "#!/bin/sh\nprintf '0\\n' >&2\nexit 0\n", {
    mode: 0o755,
  });
  writeFileSync(join(bin, "identify"), "#!/bin/sh\nprintf '1\\n'\n", { mode: 0o755 });
}

function spawnUi(dir, extra = {}) {
  const env = {
    ...process.env,
    HOME: join(dir, "home"),
    HV_WORK: join(dir, "work"),
    HV_XCTESTRUN: join(dir, "fake.xctestrun"),
    HV_UNDER_RUNNER: "1",
    HV_BASELINES: join(dir, "base"),
    HV_STUB_PNG: join(dir, "pixel.png"),
    PATH: `${join(dir, "shim")}:${join(dir, "bin")}:${process.env.PATH || ""}`,
    SHIM_ATTACH: "launch language-fr",
    ...extra,
  };
  if (!Object.prototype.hasOwnProperty.call(extra, "HV_RUNNER_DIR")) {
    delete env.HV_RUNNER_DIR;
  }
  if (!Object.prototype.hasOwnProperty.call(extra, "HV_UI_PLAN")) {
    delete env.HV_UI_PLAN;
  }
  if (!Object.prototype.hasOwnProperty.call(extra, "HV_UI_BACKEND")) {
    delete env.HV_UI_BACKEND;
  }
  return spawnSync("bash", [HV_RUN, "ui", "fake"], {
    encoding: "utf8",
    env,
    timeout: 60000,
  });
}

function combined(run) {
  return `${run.stdout || ""}\n${run.stderr || ""}`;
}

test("hv-run ui sans HV_RUNNER_DIR ni HV_UI_PLAN n'exige plus la variable et prend ui-full", async () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-run-ui-default-"));
  try {
    setup(dir);
    const run = spawnUi(dir, { HV_PORT: String(await freePort()) });
    const out = combined(run);
    assert.doesNotMatch(out, /requis/);
    assert.match(out, /UI plan=ui-full/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("hv-run ui respecte une valeur explicite de HV_RUNNER_DIR", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-run-ui-explicit-"));
  try {
    const runner = join(dir, "runner");
    mkdirSync(runner);
    writeFileSync(join(runner, "PAUSE"), "");
    const run = spawnSync("bash", [HV_RUN, "ui", "fake"], {
      encoding: "utf8",
      env: {
        ...process.env,
        HOME: join(dir, "home"),
        HV_WORK: join(dir, "work"),
        HV_RUNNER_DIR: runner,
        HV_UNDER_RUNNER: "1",
      },
      timeout: 10000,
    });
    const out = combined(run);
    assert.equal(run.status, 3, out);
    assert.match(out, /PAUSE présent/);
    assert.ok(out.includes(runner), out);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

function regenEnv(extra = {}) {
  const env = { ...process.env, ...extra };
  if (!Object.prototype.hasOwnProperty.call(extra, "HV_RUNNER_DIR")) {
    delete env.HV_RUNNER_DIR;
  }
  return env;
}

test("hv-regen-baselines sans HV_RUNNER_DIR ni vm.sh s'arrête avec un message", () => {
  const run = spawnSync("bash", [HV_REGEN], {
    encoding: "utf8",
    env: regenEnv(),
    timeout: 10000,
  });
  const out = combined(run);
  assert.equal(run.status, 2, out);
  assert.match(out, /HV_RUNNER_DIR/);
});

test("hv-regen-baselines sans vm.sh s'arrête avec le code 2", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-regen-novm-"));
  try {
    const run = spawnSync("bash", [HV_REGEN], {
      encoding: "utf8",
      env: regenEnv({ HV_RUNNER_DIR: dir }),
      timeout: 10000,
    });
    const out = combined(run);
    assert.equal(run.status, 2, out);
    assert.match(out, /Définir HV_RUNNER_DIR/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("hv-regen-baselines avec un faux vm.sh non exécutable affiche la recette sans l'appeler", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-regen-vm-"));
  try {
    const marker = join(dir, "called");
    const vm = join(dir, "vm.sh");
    writeFileSync(vm, `#!/bin/sh\n: > "${marker}"\nexit 0\n`, {
      mode: 0o644,
    });
    chmodSync(vm, 0o644);
    const run = spawnSync("bash", [HV_REGEN], {
      encoding: "utf8",
      env: regenEnv({ HV_RUNNER_DIR: dir }),
      timeout: 10000,
    });
    const out = combined(run);
    assert.equal(run.status, 0, out);
    assert.match(out, /timeout 3600 zsh/);
    assert.match(out, /vm\.sh ui fake/);
    assert.equal(existsSync(marker), false, out);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
