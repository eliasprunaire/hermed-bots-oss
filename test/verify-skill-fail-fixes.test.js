"use strict";

const assert = require("node:assert/strict");
const { spawn, spawnSync } = require("node:child_process");
const {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
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
const SHOTDIFF = join(ROOT, ".cursor/skills/verify-hermed-bots/scripts/hv-shotdiff.sh");
const DAILY_LANES = join(ROOT, ".cursor/skills/verify-hermed-bots/scripts/hv-daily-lanes.py");
const HV_RUN = join(ROOT, ".cursor/skills/verify-hermed-bots/scripts/hv-run.sh");

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

test("SSE log records message.delta text at emit time", async () => {
  const port = await freePort();
  const child = await waitReady(port, { HV_TEST_API_KEY: "probe-delta-key" });
  try {
    const injected = await request(port, "/_hv/inject", {
      method: "POST",
      body: JSON.stringify({ event: "message.delta", delta: " d00" }),
    });
    assert.equal(injected.status, 200);
    const started = await request(port, "/p/hv-bot-a/v1/runs", {
      method: "POST",
      headers: { Authorization: "Bearer probe-delta-key" },
      body: JSON.stringify({ input: "HV_PACE_100 delta" }),
    });
    assert.equal(started.status, 202, started.raw);
    const runId = started.json && started.json.run_id;
    assert.ok(runId);
    const events = await request(port, `/p/hv-bot-a/v1/runs/${runId}/events`, {
      headers: { Authorization: "Bearer probe-delta-key" },
    });
    assert.equal(events.status, 200);
    assert.match(events.raw, / d00/);
    const log = await request(port, "/_hv/log");
    assert.equal(log.status, 200);
    const deltas = (log.json || []).filter((row) => row.p === "/_hv/sse/message.delta");
    assert.ok(deltas.length >= 1, JSON.stringify(log.json));
    assert.ok(
      deltas.some((row) => row.body === " d00" && typeof row.t === "number"),
      JSON.stringify(deltas),
    );
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
  # -N as guest argv is the old bug (dispatch 127). Refuse it.
  if [ "$1" = -N ]; then
    echo "guest argv must not carry -N" >&2
    exit 127
  fi
  if [ "$1" = sleep ]; then
    sleep "$2"
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
      "import os, time, hv_vm_ui\n" +
        "p = hv_vm_ui.start_reverse_tunnel('18642'); time.sleep(0.4)\n" +
        "alive = p is not None and p.poll() is None\n" +
        "shim = None\n" +
        "if p is not None:\n" +
        "  # PATH du holder porte le shim ssh qui injecte -R sur le transport\n" +
        "  import pathlib\n" +
        "  # relire via /proc indisponible : inspecter le wrapper créé à côté\n" +
        "  pass\n" +
        "shim_dir = hv_vm_ui.install_ssh_reverse_wrapper('18642')\n" +
        "wrapper = shim_dir / 'ssh'\n" +
        "body = wrapper.read_text(encoding='utf-8')\n" +
        "zshenv = (shim_dir / 'zdot' / '.zshenv').read_text(encoding='utf-8')\n" +
        "print('alive' if alive else (p.poll() if p else 'none'))\n" +
        "print('WRAPPER', body.replace('\\n', '|'))\n" +
        "print('ZSHENV', 'timeout()' in zshenv, str(wrapper) in zshenv)\n" +
        "(p.terminate() if p else None)\n" +
        "ok = alive and '-R' in body and 'ExitOnForwardFailure' in body and '-N' not in body.split()\n" +
        "ok = ok and 'timeout()' in zshenv and str(wrapper) in zshenv and 'ssh()' not in zshenv\n" +
        "raise SystemExit(0 if ok else 1)",
    ],
    { encoding: "utf8", cwd: mod, env: { ...process.env, HV_RUNNER_DIR: dir }, timeout: 10000 },
  );
  const argv = readFileSync(log, "utf8");
  assert.equal(/(^|\n)ssh( |$)/.test(argv), false, argv);
  assert.match(argv, /^exec /m);
  assert.equal(/\n?-N\b/.test(argv) || /(^| )-N( |$)/.test(argv), false, "guest argv must not carry -N: " + argv);
  assert.match(argv, /sleep/);
  assert.equal(run.status, 0, run.stdout + run.stderr + argv);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-vm-ui default profile table matches ProfileTable.parse layout", () => {
  const src = readFileSync(VM_UI, "utf8");
  assert.match(src, /Profile\s+Model\s+Gateway/);
  assert.match(src, /hv-bot-a\s+hv-fake-1\s+running/);
  assert.match(src, /hv-bot-b\s+hv-fake-1\s+running/);
  // Un en-tête à espaces simples (« Profile Model Gateway ») est rejeté par ProfileTable.parse.
  assert.doesNotMatch(src, /"Profile Model Gateway\\nhv-bot-a hv-fake-1 running/);
});

test("hv-vm-ui host consumes guest xctestrun in one vm.sh exec", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-vm-host-"));
  const log = join(dir, "argv.log");
  writeFileSync(
    join(dir, "vm.sh"),
    `#!/bin/sh
echo "$@" >> "${log}"
if [ "$1" = exec ]; then
  exit 0
fi
echo usage >&2
exit 2
`,
    { mode: 0o755 },
  );
  const work = join(dir, "work");
  mkdirSync(join(work, "secrets"), { recursive: true });
  writeFileSync(
    join(work, "secrets", "hv-ui-keys.json"),
    JSON.stringify({ "hv-bot-a": "a".repeat(20), "hv-bot-b": "b".repeat(20) }),
  );
  const mod = join(dir, "mod");
  mkdirSync(mod);
  writeFileSync(join(mod, "hv_vm_ui.py"), readFileSync(VM_UI));
  const run = spawnSync(
    "python3",
    ["-c", "import hv_vm_ui; raise SystemExit(hv_vm_ui.host())"],
    {
      encoding: "utf8",
      cwd: mod,
      env: {
        ...process.env,
        HV_RUNNER_DIR: dir,
        HV_WORK: work,
        HV_TARGET_HOST: "hv-hermes-test",
        // garde : pas de build hôte ni glob .xctestrun
      },
      timeout: 10000,
    },
  );
  const argv = readFileSync(log, "utf8");
  assert.match(argv, /^exec /m);
  assert.equal(argv.includes("build-for-testing"), false, argv);
  assert.equal(argv.includes(".xctestrun"), false, argv);
  assert.match(argv, /hv-run\.sh/);
  assert.match(argv, /HV_RUNNER_DIR=/);
  assert.match(argv, /HV_UNDER_RUNNER=1/);
  // Le script invité lit un fichier 0600 ; le nom de variable peut apparaître, pas les valeurs.
  assert.equal(argv.includes("aaaaaaaaaaaaaaaaaaaa"), false, "key material in argv: " + argv);
  assert.equal(argv.includes("bbbbbbbbbbbbbbbbbbbb"), false, "key material in argv: " + argv);
  assert.match(argv, /hv-ui-keys-private\.json/);
  assert.equal(run.stdout.includes("aaaaaaaaaaaaaaaaaaaa"), false, run.stdout);
  assert.equal(run.status, 0, run.stdout + run.stderr + argv);
  rmSync(dir, { recursive: true, force: true });
});

test("fake Hermes lists configured profiles including new names", async () => {
  const port = await freePort();
  const child = await waitReady(port, {});
  try {
    const posted = await request(port, "/_hv/config", {
      method: "POST",
      body: JSON.stringify({ profiles: ["default", "hv-bot-a", "hv-new"] }),
    });
    assert.equal(posted.status, 200);
    const listed = await request(port, "/_hv/profile-list");
    assert.equal(listed.status, 200);
    assert.match(listed.raw, /\bhv-new\b/);
    assert.match(listed.raw, /\bhv-bot-a\b/);
  } finally {
    child.kill("SIGTERM");
  }
});

test("new session starts with an empty messages list", async () => {
  const port = await freePort();
  const child = await waitReady(port, {});
  try {
    const created = await request(port, "/p/hv-bot-a/api/sessions", {
      method: "POST",
      body: "{}",
    });
    assert.equal(created.status, 201);
    const sid = created.json && created.json.session && created.json.session.id;
    assert.ok(sid, "new session id");
    const messages = await request(port, `/p/hv-bot-a/api/sessions/${sid}/messages`);
    assert.equal(messages.status, 200);
    const data = messages.json && messages.json.data;
    assert.ok(Array.isArray(data));
    assert.equal(data.length, 0, "new session must not reuse seed fixtures");
  } finally {
    child.kill("SIGTERM");
  }
});

test("POST /_hv/profile-models configures models and reset clears them", async () => {
  const port = await freePort();
  const child = await waitReady(port, {});
  try {
    const posted = await request(port, "/_hv/profile-models", {
      method: "POST",
      body: JSON.stringify({ "hv-bot-b": "model-y" }),
    });
    assert.equal(posted.status, 200, posted.raw);
    const listed = await request(port, "/_hv/profile-list");
    assert.equal(listed.status, 200);
    assert.match(listed.raw, /model-y/);
    const reset = await request(port, "/_hv/reset", { method: "POST", body: "{}" });
    assert.equal(reset.status, 200);
    const listed2 = await request(port, "/_hv/profile-list");
    assert.equal(listed2.raw.includes("model-y"), false);
  } finally {
    child.kill("SIGTERM");
  }
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

test("fake Hermes dedupes transcript by run id, not assistant text", async () => {
  const port = await freePort();
  const keys = { "hv-bot-a": "key-a-aaaaaaaaaaaaaaaa", "hv-bot-b": "key-b-bbbbbbbbbbbbbbbb" };
  const child = await waitReady(port, { HV_TEST_API_KEYS: JSON.stringify(keys) });
  try {
    const auth = { Authorization: "Bearer " + keys["hv-bot-a"] };
    const sid = "s-open";
    for (const input of ["first turn", "second turn"]) {
      const started = await request(port, "/p/hv-bot-a/v1/runs", {
        method: "POST",
        headers: auth,
        body: JSON.stringify({ input, session_id: sid }),
      });
      assert.ok([200, 202].includes(started.status), started.raw);
      const runId = started.json && (started.json.id || started.json.run_id);
      assert.ok(runId, started.raw);
      // Drain SSE to completion so record_run_transcript runs.
      await new Promise((resolve, reject) => {
        const req = http.request(
          {
            host: "127.0.0.1",
            port,
            path: `/p/hv-bot-a/v1/runs/${runId}/events`,
            method: "GET",
            headers: auth,
          },
          (res) => {
            res.on("data", () => {});
            res.on("end", resolve);
          },
        );
        req.on("error", reject);
        req.end();
      });
    }
    const messages = await request(port, `/p/hv-bot-a/api/sessions/${sid}/messages`, { headers: auth });
    assert.equal(messages.status, 200, messages.raw);
    const data = messages.json && messages.json.data;
    assert.ok(Array.isArray(data));
    const added = data.filter((m) => m.id >= 1000);
    assert.equal(added.length, 4, JSON.stringify(added));
    assert.equal(added.filter((m) => m.role === "assistant").length, 2);
  } finally {
    child.kill("SIGTERM");
  }
});

test("fake Hermes partitions transcripts by profile", async () => {
  const port = await freePort();
  const keys = { "hv-bot-a": "key-a-aaaaaaaaaaaaaaaa", "hv-bot-b": "key-b-bbbbbbbbbbbbbbbb" };
  const child = await waitReady(port, { HV_TEST_API_KEYS: JSON.stringify(keys) });
  try {
    const authA = { Authorization: "Bearer " + keys["hv-bot-a"] };
    const authB = { Authorization: "Bearer " + keys["hv-bot-b"] };
    const created = await request(port, "/p/hv-bot-a/api/sessions", {
      method: "POST",
      headers: authA,
      body: JSON.stringify({ title: "private-a" }),
    });
    assert.ok([200, 201].includes(created.status), created.raw);
    const sid =
      (created.json && created.json.session && created.json.session.id) ||
      (created.json && (created.json.id || created.json.session_id));
    assert.ok(sid, created.raw);

    const started = await request(port, "/p/hv-bot-a/v1/runs", {
      method: "POST",
      headers: authA,
      body: JSON.stringify({ input: "secret-for-a", session_id: sid }),
    });
    assert.ok([200, 202].includes(started.status), started.raw);
    const runId = started.json && (started.json.id || started.json.run_id);
    await new Promise((resolve, reject) => {
      const req = http.request(
        {
          host: "127.0.0.1",
          port,
          path: `/p/hv-bot-a/v1/runs/${runId}/events`,
          method: "GET",
          headers: authA,
        },
        (res) => {
          res.on("data", () => {});
          res.on("end", resolve);
        },
      );
      req.on("error", reject);
      req.end();
    });

    const own = await request(port, `/p/hv-bot-a/api/sessions/${sid}/messages`, { headers: authA });
    assert.equal(own.status, 200);
    assert.ok((own.json.data || []).some((m) => String(m.content).includes("secret-for-a")));

    // Même session id côté B : 404 (pas dans SESSIONS[B]) — pas de fuite du transcript A.
    const crossed = await request(port, `/p/hv-bot-b/api/sessions/${sid}/messages`, { headers: authB });
    assert.equal(crossed.status, 404, crossed.raw);
  } finally {
    child.kill("SIGTERM");
  }
});

test("fake Hermes keeps approval decision across Last-Event-ID resume", async () => {
  const port = await freePort();
  const keys = { "hv-bot-a": "key-a-aaaaaaaaaaaaaaaa", "hv-bot-b": "key-b-bbbbbbbbbbbbbbbb" };
  const child = await waitReady(port, { HV_TEST_API_KEYS: JSON.stringify(keys) });
  try {
    const auth = { Authorization: "Bearer " + keys["hv-bot-a"] };
    const started = await request(port, "/p/hv-bot-a/v1/runs", {
      method: "POST",
      headers: auth,
      body: JSON.stringify({ input: "HV_APPROVAL please", session_id: "s-open" }),
    });
    assert.ok([200, 202].includes(started.status), started.raw);
    const runId = started.json && (started.json.id || started.json.run_id);
    assert.ok(runId, started.raw);

    // Open stream briefly to create PENDING / RUN_SSE, then decide.
    const first = await new Promise((resolve, reject) => {
      const events = [];
      const req = http.request(
        {
          host: "127.0.0.1",
          port,
          path: `/p/hv-bot-a/v1/runs/${runId}/events`,
          method: "GET",
          headers: auth,
        },
        (res) => {
          let buf = "";
          res.on("data", (c) => {
            buf += c.toString("utf8");
            if (buf.includes("approval.request") && events.length === 0) {
              events.push("seen");
              const m = buf.match(/"request_id":\s*"([^"]+)"/);
              const requestId = m ? m[1] : "apr_" + runId;
              // Decide once the request is visible.
              request(port, `/p/hv-bot-a/v1/runs/${runId}/approval`, {
                method: "POST",
                headers: auth,
                body: JSON.stringify({ choice: "once", request_id: requestId }),
              }).catch(reject);
            }
          });
          res.on("end", () => resolve(buf));
        },
      );
      req.on("error", reject);
      req.end();
    });
    assert.match(first, /approval\.responded/);
    assert.match(first, /"choice": "once"/);

    // Resume after the last event id (5 = last of head(2)+tail(4) zero-based → use 5).
    const resumed = await new Promise((resolve, reject) => {
      const req = http.request(
        {
          host: "127.0.0.1",
          port,
          path: `/p/hv-bot-a/v1/runs/${runId}/events`,
          method: "GET",
          headers: { ...auth, "Last-Event-ID": "5" },
        },
        (res) => {
          let buf = "";
          res.on("data", (c) => {
            buf += c.toString("utf8");
          });
          res.on("end", () => resolve(buf));
        },
      );
      req.on("error", reject);
      req.setTimeout(3000, () => {
        req.destroy(new Error("resume hung waiting for a new decision"));
      });
      req.end();
    });
    assert.equal(resumed.includes("tool.started"), false, resumed);
    assert.equal(resumed.includes("approval.request"), false, resumed);
  } finally {
    child.kill("SIGTERM");
  }
});

const PNG1 = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64",
);

function shotdiffEnv(dir, ae, pixels, extra = {}) {
  const bin = join(dir, "bin");
  mkdirSync(bin);
  writeFileSync(join(bin, "compare"), `#!/bin/sh\nprintf '%s\\n' "${ae}" >&2\nexit 1\n`, { mode: 0o755 });
  writeFileSync(join(bin, "identify"), `#!/bin/sh\nprintf '%s\\n' "${pixels}"\n`, { mode: 0o755 });
  return { ...process.env, ...extra, PATH: `${bin}:${process.env.PATH || ""}` };
}

test("hv-shotdiff rejects a large ratio under fr_FR and C locales", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  writeFileSync(join(base, "x.png"), PNG1);
  writeFileSync(join(cap, "x.png"), PNG1);
  const env = shotdiffEnv(dir, "1000", "100");

  for (const locale of ["C", "fr_FR.UTF-8"]) {
    const run = spawnSync("bash", [SHOTDIFF, cap, base, join(dif, locale), "0.02"], {
      encoding: "utf8",
      env: { ...env, LC_ALL: locale, LANG: locale },
    });
    assert.equal(run.status, 11, `locale=${locale} out=${run.stdout} err=${run.stderr}`);
    assert.match(run.stdout, /DIFF/);
  }
  rmSync(dir, { recursive: true, force: true });
});


test("hv-run shotdiff tolerance is 0.03 for orb and 0.02 otherwise", () => {
  const src = readFileSync(HV_RUN, "utf8");
  assert.match(src, /SHOT_TOL=0\.03/);
  assert.match(src, /SHOT_TOL=0\.02/);
  assert.match(src, /"\$SHOT_TOL"/);
  assert.doesNotMatch(src, /hv-shotdiff\.sh".*diffs" 0\.02/);
  for (const [backend, expected] of [
    ["orb", "0.03"],
    ["fake", "0.02"],
    ["", "0.02"],
  ]) {
    const run = spawnSync(
      "bash",
      [
        "-c",
        `HV_UI_BACKEND=${backend}; ENVMODE=fake; case "\${HV_UI_BACKEND:-\$ENVMODE}" in orb) SHOT_TOL=0.03 ;; *) SHOT_TOL=0.02 ;; esac; printf '%s' "$SHOT_TOL"`,
      ],
      { encoding: "utf8" },
    );
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.stdout, expected, `backend=${backend || "(empty)"}`);
  }
});

test("hv-shotdiff mid-ratio fails at 0.02 (fake) and passes at 0.03 (orb)", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-tol-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  writeFileSync(join(base, "x.png"), PNG1);
  writeFileSync(join(cap, "x.png"), PNG1);
  const env = shotdiffEnv(dir, "250", "10000", { LC_ALL: "C" });
  const fake = spawnSync("bash", [SHOTDIFF, cap, base, join(dif, "fake"), "0.02"], {
    encoding: "utf8",
    env,
  });
  assert.equal(fake.status, 11, `fake tol out=${fake.stdout}`);
  assert.match(fake.stdout, /DIFF/);
  const orb = spawnSync("bash", [SHOTDIFF, cap, base, join(dif, "orb"), "0.03"], {
    encoding: "utf8",
    env,
  });
  assert.equal(orb.status, 0, `orb tol out=${orb.stdout}`);
  assert.match(orb.stdout, /OK/);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-vm-ui host guest argv never carries HV_TEST_API_KEYS", () => {
  const src = readFileSync(VM_UI, "utf8");
  assert.match(src, /install_transport_shim/);
  assert.match(src, /hv-ui-keys-private\.json/);
  // guest_env list must not append the packed keys.
  assert.doesNotMatch(src, /guest_env\.append\(\s*"HV_TEST_API_KEYS=/);
});


test("hv-vm-ui private key copy reuses transport -i and trust options", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-keys-opts-"));
  const idFile = join(dir, "id_hv");
  const known = join(dir, "known_hosts");
  writeFileSync(idFile, "synthetic-identity\n");
  writeFileSync(known, "hv-ui-vm ssh-ed25519 AAAA\n");
  const log = join(dir, "bin.log");
  writeFileSync(log, "");
  const bin = join(dir, "bin");
  mkdirSync(bin);
  writeFileSync(
    join(bin, "ssh"),
    [
      "#!/bin/sh",
      `printf 'SSH' >> "${log}"`,
      `for a in "$@" ; do printf ' %s' "$a" >> "${log}" ; done`,
      `printf '\\n' >> "${log}"`,
      "exit 0",
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  writeFileSync(
    join(bin, "scp"),
    [
      "#!/bin/sh",
      `printf 'SCP' >> "${log}"`,
      `for a in "$@" ; do printf ' %s' "$a" >> "${log}" ; done`,
      `printf '\\n' >> "${log}"`,
      "exit 0",
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  const mod = join(dir, "mod");
  mkdirSync(mod);
  writeFileSync(join(mod, "hv_vm_ui.py"), readFileSync(VM_UI));
  const run = spawnSync(
    "python3",
    [
      "-c",
      "import hv_vm_ui\n" +
        "d = hv_vm_ui.install_transport_shim(None, '{\\\"hv-bot-a\\\":\\\"key-aaaaaaaaaaaaaaaa\\\"}')\n" +
        "print(d)",
    ],
    { encoding: "utf8", cwd: mod, timeout: 10000 },
  );
  assert.equal(run.status, 0, run.stdout + run.stderr);
  const shimDir = run.stdout.trim();
  const guestHome = join(dir, "guest-home");
  mkdirSync(guestHome);
  const env = {
    ...process.env,
    HV_SSH_BIN: join(bin, "ssh"),
    HV_SCP_BIN: join(bin, "scp"),
    HOME: guestHome,
  };
  const invoked = spawnSync(
    join(shimDir, "ssh"),
    [
      "-o",
      "StrictHostKeyChecking=yes",
      "-o",
      `UserKnownHostsFile=${known}`,
      "-o",
      "HostKeyAlias=hv-ui-vm",
      "-o",
      "IdentitiesOnly=yes",
      "-i",
      idFile,
      "hvtest@127.0.0.1",
      "bash ~/vmui-run.sh",
    ],
    { encoding: "utf8", env, timeout: 10000 },
  );
  assert.equal(invoked.status, 0, invoked.stdout + invoked.stderr);
  const logged = readFileSync(log, "utf8");
  assert.match(logged, /SCP.*-i\s+\S*id_hv/);
  assert.match(logged, /SCP.*StrictHostKeyChecking=yes/);
  assert.match(logged, /SCP.*UserKnownHostsFile=/);
  assert.match(logged, /SCP.*HostKeyAlias=hv-ui-vm/);
  assert.match(logged, /SCP.*IdentitiesOnly=yes/);
  assert.match(logged, /SCP.*hv-ui-keys-private\.json/);
  assert.match(logged, /SSH.*-i\s+\S*id_hv/);
  assert.match(logged, /SSH.*StrictHostKeyChecking=yes/);
  assert.match(logged, /SSH.*chmod 600/);
  rmSync(dir, { recursive: true, force: true });
});

test("fake Hermes rejects cross-profile run approve and events", async () => {
  const port = await freePort();
  const keys = { "hv-bot-a": "key-a-aaaaaaaaaaaaaaaa", "hv-bot-b": "key-b-bbbbbbbbbbbbbbbb" };
  const child = await waitReady(port, { HV_TEST_API_KEYS: JSON.stringify(keys) });
  try {
    const authA = { Authorization: "Bearer " + keys["hv-bot-a"] };
    const authB = { Authorization: "Bearer " + keys["hv-bot-b"] };
    const started = await request(port, "/p/hv-bot-a/v1/runs", {
      method: "POST",
      headers: authA,
      body: JSON.stringify({ input: "HV_APPROVAL cross-owner" }),
    });
    assert.ok([200, 202].includes(started.status), started.raw);
    const runId = started.json && (started.json.id || started.json.run_id);
    assert.ok(runId, started.raw);

    const crossApprove = await request(port, `/p/hv-bot-b/v1/runs/${runId}/approval`, {
      method: "POST",
      headers: authB,
      body: JSON.stringify({ request_id: "apr_x", choice: "deny" }),
    });
    assert.ok([403, 404].includes(crossApprove.status), crossApprove.raw);

    const crossEvents = await request(port, `/p/hv-bot-b/v1/runs/${runId}/events`, {
      headers: authB,
    });
    assert.ok([403, 404].includes(crossEvents.status), crossEvents.raw);

    const crossCancel = await request(port, `/p/hv-bot-b/v1/runs/${runId}/stop`, {
      method: "POST",
      headers: authB,
      body: "{}",
    });
    assert.ok([403, 404].includes(crossCancel.status), crossCancel.raw);
  } finally {
    child.kill("SIGTERM");
  }
});

test("hv-shotdiff fails when image dimensions differ", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-dim-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  // Same 1x1 PNG fixture as other shotdiff tests — dimensions come from the identify stub
  // (CI has no ImageMagick magick; cdf9e332 pattern).
  writeFileSync(join(base, "x.png"), PNG1);
  writeFileSync(join(cap, "x.png"), PNG1);
  const bin = join(dir, "bin");
  mkdirSync(bin);
  writeFileSync(
    join(bin, "identify"),
    [
      "#!/bin/sh",
      "fmt=; file=",
      "while [ $# -gt 0 ]; do",
      '  case "$1" in',
      '    -format) fmt=$2; shift 2 ;;',
      '    *) file=$1; shift ;;',
      "  esac",
      "done",
      'case "$fmt" in',
      "  %w)",
      '    case "$file" in',
      '      */base/*) printf "100\\n" ;;',
      '      *) printf "101\\n" ;;',
      "    esac",
      "    ;;",
      '  %h) printf "100\\n" ;;',
      '  *) printf "10000\\n" ;;',
      "esac",
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  writeFileSync(
    join(bin, "compare"),
    "#!/bin/sh\nprintf '0\\n' >&2\nexit 0\n",
    { mode: 0o755 },
  );
  const run = spawnSync("bash", [SHOTDIFF, cap, base, dif, "0.02"], {
    encoding: "utf8",
    env: { ...process.env, PATH: `${bin}:${process.env.PATH || ""}`, LC_ALL: "C" },
  });
  assert.equal(run.status, 11, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /DIFF/);
  assert.match(run.stdout, /size/);
  rmSync(dir, { recursive: true, force: true });
});

test("skill baselines copy UIReferences PNGs and LACUNES names stay missing", () => {
  const refs = join(ROOT, "UIReferences");
  const baselines = join(ROOT, ".cursor/skills/verify-hermed-bots/baselines");
  const stale = "issue58-version-missing-key.png";
  const pngs = readdirSync(refs).filter((name) => name.endsWith(".png"));
  assert.equal(pngs.length, 27);
  for (const name of pngs) {
    assert.equal(existsSync(join(baselines, name)), name !== stale, name);
  }
  const lacunes = readFileSync(join(baselines, "LACUNES-PNG.md"), "utf8");
  const listed = [...lacunes.matchAll(/- LACUNE binaire : `([^`]+)`/g)].map((m) => m[1]);
  assert.ok(listed.includes(stale));
  assert.ok(listed.length > 40, String(listed.length));
  for (const name of listed) {
    assert.equal(existsSync(join(baselines, name)), false, name);
  }
});

test("hv-daily-lanes isolates HOME per lane", () => {
  const src = readFileSync(DAILY_LANES, "utf8");
  assert.match(src, /def lane_ctx\(/);
  assert.match(src, /home-\{tag\}/);
  const dir = mkdtempSync(join(tmpdir(), "hv-daily-home-"));
  const script =
    "import importlib.util\n" +
    "from pathlib import Path\n" +
    "spec = importlib.util.spec_from_file_location('dl', " + JSON.stringify(DAILY_LANES) + ")\n" +
    "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n" +
    "root = Path(" + JSON.stringify(dir) + ")\n" +
    "def ctx(tag):\n" +
    "  home = root / f'home-{tag}'; runner = root / f'runner-{tag}'; work = root / f'work-{tag}'\n" +
    "  home.mkdir(); runner.mkdir(); work.mkdir()\n" +
    "  return home, m.base_env(home, runner, work, 'k'*20)\n" +
    "h4, e4 = ctx('4')\n" +
    "hermes = h4 / '.local' / 'bin'; hermes.mkdir(parents=True)\n" +
    "(hermes / 'hermes').write_text('mutated\\n')\n" +
    "h6, e6 = ctx('6')\n" +
    "assert e4['HOME'] != e6['HOME']\n" +
    "assert not (Path(e6['HOME']) / '.local' / 'bin' / 'hermes').exists()\n" +
    "assert (Path(e4['HOME']) / '.local' / 'bin' / 'hermes').read_text() == 'mutated\\n'\n" +
    "print('ok')\n";
  const run = spawnSync("python3", ["-c", script], { encoding: "utf8", timeout: 10000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /ok/);
  rmSync(dir, { recursive: true, force: true });
});

