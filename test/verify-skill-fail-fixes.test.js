"use strict";

const assert = require("node:assert/strict");
const { spawn, spawnSync } = require("node:child_process");
const {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const http = require("node:http");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const FAKE = join(ROOT, ".cursor/skills/verify-hermed-bots/scripts/hv-fake-hermes.py");
const VM_UI = join(ROOT, ".cursor/skills/verify-hermed-bots/scripts/hv-vm-ui.py");
const CONTRACT = join(ROOT, ".cursor/skills/verify-hermed-bots/scripts/hv-contract-check.py");
const FIXTURE = join(ROOT, ".cursor/skills/verify-hermed-bots/fixtures/hermes-current/contract.json");
const START = join(ROOT, ".cursor/skills/verify-hermed-bots/orb/hv-start.sh");

function freePort() {
  return new Promise((resolve, reject) => {
    const server = http.createServer();
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close((err) => (err ? reject(err) : resolve(port)));
    });
  });
}

function request(port, path, { method = "GET", headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: "127.0.0.1",
        port,
        path,
        method,
        headers: {
          "Content-Type": "application/json",
          ...(body ? { "Content-Length": Buffer.byteLength(body) } : {}),
          ...headers,
        },
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const raw = Buffer.concat(chunks).toString("utf8");
          let json = null;
          try {
            json = JSON.parse(raw);
          } catch {
            json = null;
          }
          resolve({ status: res.statusCode, raw, json });
        });
      },
    );
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

async function waitReady(port, env) {
  const childEnv = { ...process.env, ...env };
  if (!Object.prototype.hasOwnProperty.call(env, "HV_TEST_API_KEYS")) {
    delete childEnv.HV_TEST_API_KEYS;
  }
  const child = spawn("python3", [FAKE, "--port", String(port)], {
    env: childEnv,
    stdio: ["ignore", "pipe", "pipe"],
  });
  for (let i = 0; i < 50; i++) {
    try {
      const r = await request(port, "/_hv/ready");
      if (r.status === 200) return child;
    } catch {
      await new Promise((ok) => setTimeout(ok, 50));
    }
  }
  child.kill("SIGTERM");
  throw new Error("fake Hermes did not become ready");
}

test("profile health and session messages match HermesAdapter", async () => {
  const port = await freePort();
  const child = await waitReady(port, {});
  try {
    const health = await request(port, "/p/hv-bot-a/health");
    assert.equal(health.status, 200, "GET /p/{profile}/health");
    assert.equal(health.json && health.json.status, "ok");
    assert.ok(health.json && health.json.version);

    const messages = await request(port, "/p/hv-bot-a/api/sessions/s-open/messages");
    assert.equal(messages.status, 200, "GET /p/{profile}/api/sessions/{session}/messages");
    const data = messages.json && messages.json.data;
    assert.ok(Array.isArray(data) && data.length >= 2);
    const roles = data.map((row) => row.role);
    assert.ok(roles.includes("user") && roles.includes("assistant"));
    assert.ok(data.every((row) => typeof row.id === "number" && row.content));
  } finally {
    child.kill("SIGTERM");
  }
});

test("HV_TEST_API_KEYS rejects crossed and missing keys", async () => {
  const port = await freePort();
  const keys = { "hv-bot-a": "key-a-aaaaaaaaaaaaaaaa", "hv-bot-b": "key-b-bbbbbbbbbbbbbbbb" };
  const child = await waitReady(port, { HV_TEST_API_KEYS: JSON.stringify(keys) });
  try {
    const ok = await request(port, "/p/hv-bot-a/health", {
      headers: { Authorization: "Bearer " + keys["hv-bot-a"] },
    });
    assert.equal(ok.status, 200);

    const crossed = await request(port, "/p/hv-bot-a/v1/models", {
      headers: { Authorization: "Bearer " + keys["hv-bot-b"] },
    });
    assert.equal(crossed.status, 401, "crossed key");

    const missing = await request(port, "/p/hv-bot-a/v1/models");
    assert.equal(missing.status, 401, "missing key");

    const healthOpen = await request(port, "/health");
    assert.equal(healthOpen.status, 200, "unscoped /health stays open");
  } finally {
    child.kill("SIGTERM");
  }
});

test("empty profiles list stays empty on /_hv/profile-list", async () => {
  const port = await freePort();
  const child = await waitReady(port, {});
  try {
    const posted = await request(port, "/_hv/config", {
      method: "POST",
      body: JSON.stringify({ profiles: [] }),
    });
    assert.equal(posted.status, 200);

    const listed = await request(port, "/_hv/profile-list");
    assert.equal(listed.status, 200);
    assert.equal(listed.raw.includes("hv-bot-a"), false);
    assert.equal(listed.raw.includes("cyber"), false);

    const hidden = await request(port, "/p/hv-bot-a/v1/models");
    assert.equal(hidden.status, 404);
  } finally {
    child.kill("SIGTERM");
  }
});

test("acceptance records tool.started and once/deny on PRD profiles", async () => {
  const port = await freePort();
  const child = await waitReady(port, { HV_TEST_API_KEY: "selftest-acceptance-key" });
  const out = join(mkdtempSync(join(tmpdir(), "hv-acc-")), "r.json");
  try {
    const run = spawnSync(
      "python3",
      [CONTRACT, "--url", `http://127.0.0.1:${port}`, "--fixture", FIXTURE, "--out", out, "--acceptance", "--timeout", "8"],
      {
        encoding: "utf8",
        timeout: 120000,
        env: { ...process.env, HV_TEST_API_KEY: "selftest-acceptance-key" },
      },
    );
    assert.equal(run.status, 0, run.stderr || run.stdout);
    const rows = JSON.parse(readFileSync(out, "utf8"));
    const acceptance = rows.filter((r) => String(r.contract).startsWith("acceptance:"));
    assert.equal(acceptance.length, 54);
    assert.ok(acceptance.every((r) => r.result === "PASS"));
    const prd = JSON.parse(readFileSync(FIXTURE, "utf8")).profiles.served.filter((p) => !String(p).startsWith("hv-"));
    for (const profile of prd) {
      const tool = acceptance.find((r) => r.contract === `acceptance:${profile}:tool`);
      assert.ok(tool, profile + " tool probe");
      assert.match(String(tool.detail), /tool\.started/);
      const approve = acceptance.find((r) => r.contract === `acceptance:${profile}:approve`);
      assert.ok(approve, profile + " approve probe");
      assert.match(String(approve.detail), /once/);
      assert.match(String(approve.detail), /deny/);
    }
  } finally {
    child.kill("SIGTERM");
  }
});

test("hv-vm-ui opens the reverse tunnel through vm.sh exec", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-vm-"));
  const log = join(dir, "argv.log");
  writeFileSync(
    join(dir, "vm.sh"),
    `#!/bin/sh
echo "$@" >> "${log}"
if [ "$1" = ssh ]; then
  echo "no ssh subcommand" >&2
  exit 2
fi
if [ "$1" = exec ]; then
  shift
  if [ "$1" = -N ]; then
    sleep 30
    exit 0
  fi
  exit 0
fi
echo usage >&2
exit 2
`,
    { mode: 0o755 },
  );
  const mod = join(dir, "mod");
  mkdirSync(mod);
  writeFileSync(join(mod, "hv_vm_ui.py"), readFileSync(VM_UI));
  chmodSync(join(mod, "hv_vm_ui.py"), 0o755);
  const run = spawnSync(
    "python3",
    [
      "-c",
      "import time, hv_vm_ui; p = hv_vm_ui.start_reverse_tunnel('18642'); time.sleep(0.4); alive = p is not None and p.poll() is None\n" +
        "print('alive' if alive else (p.poll() if p else 'none'));\n" +
        "(p.terminate() if p else None); raise SystemExit(0 if alive else 1)",
    ],
    { encoding: "utf8", cwd: mod, env: { ...process.env, HV_RUNNER_DIR: dir }, timeout: 10000 },
  );
  const argv = readFileSync(log, "utf8");
  assert.equal(/(^|\n)ssh( |$)/.test(argv), false, argv);
  assert.match(argv, /^exec /m);
  assert.match(argv, /-N/);
  assert.match(argv, /-R/);
  assert.equal(run.status, 0, run.stdout + run.stderr + argv);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-start.sh keeps an existing API_SERVER_KEY", () => {
  const src = readFileSync(START, "utf8");
  const match = src.match(/python - <<'PY'\n([\s\S]*?)\nPY/);
  assert.ok(match, "embedded python");
  const dir = mkdtempSync(join(tmpdir(), "hv-start-"));
  mkdirSync(join(dir, "profiles", "hv-bot-a"), { recursive: true });
  writeFileSync(join(dir, "config.yaml"), "model: x\n");
  writeFileSync(join(dir, "profiles", "hv-bot-a", "config.yaml"), "model: x\n");
  writeFileSync(join(dir, ".env"), "API_SERVER_KEY=keep-original\n");
  writeFileSync(join(dir, "profiles", "hv-bot-a", ".env"), "API_SERVER_KEY=keep-profile\n");
  const body = match[1].replace(/import hermes_yaml\n/, "");
  const stub = `import pathlib, os, sys
class hermes_yaml:
    @staticmethod
    def safe_load(text):
        return {}
    @staticmethod
    def safe_dump(obj):
        return "model: stub\\n"
${body}
`;
  const py = join(dir, "run.py");
  writeFileSync(py, stub);
  const run = spawnSync("python3", [py], {
    encoding: "utf8",
    env: { ...process.env, HERMES_HOME: dir, HV_TEST_API_KEY: "replacement-key-should-not-win" },
  });
  assert.equal(run.status, 0, run.stderr);
  assert.match(readFileSync(join(dir, ".env"), "utf8"), /^API_SERVER_KEY=keep-original$/m);
  assert.match(readFileSync(join(dir, "profiles", "hv-bot-a", ".env"), "utf8"), /^API_SERVER_KEY=keep-profile$/m);
  rmSync(dir, { recursive: true, force: true });
});
