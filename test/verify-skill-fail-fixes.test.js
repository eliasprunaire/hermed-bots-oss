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
const { createHash } = require("node:crypto");
const { crc32, deflateSync } = require("node:zlib");

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

function parseSse(raw) {
  const events = [];
  let id = null;
  for (const line of String(raw).split(/\r?\n/)) {
    if (line.startsWith("id: ")) id = Number(line.slice(4));
    else if (line.startsWith("data: ")) events.push({ id, data: JSON.parse(line.slice(6)) });
  }
  return events;
}

function toolStartedGaps(events) {
  const started = events.filter((ev) => ev.data && ev.data.event === "tool.started");
  const gaps = [];
  for (let i = 1; i < started.length; i++) {
    gaps.push(started[i].data.timestamp - started[i - 1].data.timestamp);
  }
  return { started, gaps };
}

function runStarts(log) {
  return (log || []).filter(
    (row) => row.m === "POST" && typeof row.p === "string" && row.p.endsWith("/v1/runs") && row.s === 202,
  );
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

test("fake Hermes HV_LOOP honors HV_PACE_<ms> between tool.started", async () => {
  const port = await freePort();
  const child = await waitReady(port, { HV_TEST_API_KEY: "pace-loop-key" });
  const auth = { Authorization: "Bearer pace-loop-key" };
  async function loop(input) {
    const started = await request(port, "/p/hv-bot-a/v1/runs", {
      method: "POST",
      headers: auth,
      body: JSON.stringify({ input }),
    });
    assert.equal(started.status, 202, started.raw);
    const runId = started.json && started.json.run_id;
    assert.ok(runId);
    const events = await request(port, `/p/hv-bot-a/v1/runs/${runId}/events`, { headers: auth });
    assert.equal(events.status, 200, events.raw);
    return { runId, parsed: parseSse(events.raw) };
  }
  try {
    const paced = await loop("HV_LOOP HV_PACE_500 go");
    const pacedGaps = toolStartedGaps(paced.parsed);
    assert.equal(pacedGaps.started.length, 3, JSON.stringify(paced.parsed.map((ev) => ev.data.event)));
    assert.ok(pacedGaps.gaps.length >= 1);
    const logPaced = await request(port, "/_hv/log");
    assert.equal(runStarts(logPaced.json).length, 1, JSON.stringify(runStarts(logPaced.json)));

    const replay = await request(port, `/p/hv-bot-a/v1/runs/${paced.runId}/events`, {
      headers: { ...auth, "Last-Event-ID": "0" },
    });
    assert.equal(replay.status, 200, replay.raw);
    const replayed = parseSse(replay.raw);
    assert.equal(replayed[0] && replayed[0].id, 1, JSON.stringify(replayed.map((ev) => ev.id)));
    assert.equal(replayed.filter((ev) => ev.data.event === "tool.started").length, 2);
    assert.equal(replayed.filter((ev) => ev.data.event === "run.completed").length, 1);

    const reset = await request(port, "/_hv/reset", { method: "POST", body: "{}" });
    assert.equal(reset.status, 200, reset.raw);

    const plain = await loop("HV_LOOP go");
    const plainGaps = toolStartedGaps(plain.parsed);
    assert.equal(plainGaps.started.length, 3);
    assert.ok(plainGaps.gaps.length >= 1);
    for (const gap of pacedGaps.gaps) {
      assert.ok(gap >= 0.35, `HV_PACE_500 gap=${gap}`);
    }
    const logPlain = await request(port, "/_hv/log");
    assert.equal(runStarts(logPlain.json).length, 1, JSON.stringify(runStarts(logPlain.json)));
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

function shotdiffIhdrEnv(dir, ae, extra = {}) {
  const bin = join(dir, "bin");
  mkdirSync(bin, { recursive: true });
  writeFileSync(join(bin, "compare"), `#!/bin/sh\nprintf '%s\\n' "${ae}" >&2\nexit 1\n`, { mode: 0o755 });
  writeFileSync(
    join(bin, "identify"),
    [
      "#!/bin/sh",
      "fmt=; file=",
      "while [ $# -gt 0 ]; do",
      '  case "$1" in',
      "    -format) fmt=$2; shift 2 ;;",
      "    *) file=$1; shift ;;",
      "  esac",
      "done",
      'set -- $(od -An -t u1 -j 16 -N 8 "$file")',
      "w=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))",
      "h=$(( $5 * 16777216 + $6 * 65536 + $7 * 256 + $8 ))",
      'case "$fmt" in',
      '  %w) printf "%s\\n" "$w" ;;',
      '  %h) printf "%s\\n" "$h" ;;',
      "  *) printf '%s\\n' $((w * h)) ;;",
      "esac",
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  return { ...process.env, ...extra, PATH: `${bin}:${process.env.PATH || ""}`, LC_ALL: "C" };
}

function pngChunk(tag, data) {
  const payload = Buffer.concat([Buffer.from(tag), data]);
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(payload) >>> 0);
  return Buffer.concat([len, payload, crc]);
}

function encodePng(w, h, bit, colorType, raw, extraChunks = []) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = bit;
  ihdr[9] = colorType;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk("IHDR", ihdr),
    ...extraChunks,
    pngChunk("IDAT", deflateSync(raw)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

function encodePngRgb(w, h, rgb) {
  const stride = w * 3;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[(stride + 1) * y] = 0;
    rgb.copy(raw, (stride + 1) * y + 1, y * stride, (y + 1) * stride);
  }
  return encodePng(w, h, 8, 2, raw);
}

function encodePngRgb16(w, h, rgb) {
  const stride = w * 6;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[(stride + 1) * y] = 0;
    for (let x = 0; x < w; x++) {
      const s = (y * w + x) * 3;
      const d = (stride + 1) * y + 1 + x * 6;
      for (let c = 0; c < 3; c++) {
        const v16 = rgb[s + c] * 257;
        raw[d + c * 2] = v16 >> 8;
        raw[d + c * 2 + 1] = v16 & 255;
      }
    }
  }
  return encodePng(w, h, 16, 2, raw);
}

function encodePngRgba(w, h, rgba) {
  const stride = w * 4;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[(stride + 1) * y] = 0;
    rgba.copy(raw, (stride + 1) * y + 1, y * stride, (y + 1) * stride);
  }
  return encodePng(w, h, 8, 6, raw);
}

function encodePngGrey8(w, h, grey, trnsValue) {
  const stride = w;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[(stride + 1) * y] = 0;
    grey.copy(raw, (stride + 1) * y + 1, y * w, (y + 1) * w);
  }
  const extra = [];
  if (trnsValue !== undefined) {
    const tRNS = Buffer.alloc(2);
    tRNS.writeUInt16BE(trnsValue);
    extra.push(pngChunk("tRNS", tRNS));
  }
  return encodePng(w, h, 8, 0, raw, extra);
}

function encodePngGrey4(w, h, grey8) {
  const stride = Math.ceil(w / 2);
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[(stride + 1) * y] = 0;
    for (let x = 0; x < w; x += 2) {
      const v0 = grey8[y * w + x] >> 4;
      const v1 = x + 1 < w ? grey8[y * w + x + 1] >> 4 : 0;
      raw[(stride + 1) * y + 1 + (x >> 1)] = (v0 << 4) | v1;
    }
  }
  return encodePng(w, h, 4, 0, raw);
}

function rgbCanvas(w, h, color) {
  const buf = Buffer.alloc(w * h * 3);
  for (let i = 0; i < w * h; i++) {
    buf[i * 3] = color[0];
    buf[i * 3 + 1] = color[1];
    buf[i * 3 + 2] = color[2];
  }
  return buf;
}

function blitRgb(buf, w, x0, y0, ww, hh, color) {
  for (let y = y0; y < y0 + hh; y++) {
    for (let x = x0; x < x0 + ww; x++) {
      const o = (y * w + x) * 3;
      buf[o] = color[0];
      buf[o + 1] = color[1];
      buf[o + 2] = color[2];
    }
  }
}

function fillCircleAa(buf, w, h, cx, cy, r, color, bg) {
  const r2 = r * r;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let acc = 0;
      for (let i = 0; i < 4; i++) {
        for (let j = 0; j < 4; j++) {
          const px = x + (i + 0.5) / 4;
          const py = y + (j + 0.5) / 4;
          if ((px - cx) * (px - cx) + (py - cy) * (py - cy) <= r2) acc += 1;
        }
      }
      const t = acc / 16;
      const o = (y * w + x) * 3;
      buf[o] = Math.round(bg[0] * (1 - t) + color[0] * t);
      buf[o + 1] = Math.round(bg[1] * (1 - t) + color[1] * t);
      buf[o + 2] = Math.round(bg[2] * (1 - t) + color[2] * t);
    }
  }
}

function fillAaBars(buf, w, h, x0, y0, barW, gap, nBars, hh, color, bg) {
  for (let y = 0; y < h; y++) {
    if (y < y0 || y >= y0 + hh) continue;
    for (let x = 0; x < w; x++) {
      let t = 0;
      for (let k = 0; k < nBars; k++) {
        const bx = x0 + k * (barW + gap);
        let acc = 0;
        for (let i = 0; i < 4; i++) {
          const px = x + (i + 0.5) / 4;
          if (px >= bx && px < bx + barW) acc += 1;
        }
        t = Math.max(t, acc / 4);
      }
      if (t === 0) continue;
      const o = (y * w + x) * 3;
      buf[o] = Math.round(bg[0] * (1 - t) + color[0] * t);
      buf[o + 1] = Math.round(bg[1] * (1 - t) + color[1] * t);
      buf[o + 2] = Math.round(bg[2] * (1 - t) + color[2] * t);
    }
  }
}

function blurRgb1(buf, w, h) {
  const out = Buffer.alloc(w * h * 3);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let r = 0;
      let g = 0;
      let b = 0;
      let n = 0;
      for (let dy = -1; dy <= 1; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          const xx = x + dx;
          const yy = y + dy;
          if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
          const o = (yy * w + xx) * 3;
          r += buf[o];
          g += buf[o + 1];
          b += buf[o + 2];
          n += 1;
        }
      }
      const o = (y * w + x) * 3;
      out[o] = Math.round(r / n);
      out[o + 1] = Math.round(g / n);
      out[o + 2] = Math.round(b / n);
    }
  }
  return out;
}

function runShotdiff(cap, base, dif, env, tol) {
  const args = [SHOTDIFF, cap, base, dif];
  if (tol !== undefined) args.push(tol);
  return spawnSync("bash", args, { encoding: "utf8", env, timeout: 60000 });
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

test("hv-shotdiff keeps default TOL 0.02 and a local zone rule", () => {
  const src = readFileSync(SHOTDIFF, "utf8");
  assert.match(src, /TOL=\$\{4:-0\.02\}/);
  assert.match(src, /zone=\$zone/);
  assert.match(src, /MIN_ERODED = 80/);
  assert.match(src, /NEIGHBOR_RADIUS = 4/);
  assert.match(src, /NEIGHBOR_DE = 10/);
  const runSrc = readFileSync(HV_RUN, "utf8");
  assert.match(runSrc, /SHOT_TOL=0\.03/);
  assert.match(runSrc, /SHOT_TOL=0\.02/);
  assert.doesNotMatch(runSrc, /hv-shotdiff\.sh".*diffs" 0\.02/);
});

test("hv-shotdiff fails a small frank orange/grey blob under default TOL", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-blob-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const w = 200;
  const h = 200;
  const bg = [240, 240, 240];
  const orange = rgbCanvas(w, h, bg);
  const grey = rgbCanvas(w, h, bg);
  blitRgb(orange, w, 90, 90, 20, 20, [255, 141, 40]);
  blitRgb(grey, w, 90, 90, 20, 20, [121, 121, 121]);
  writeFileSync(join(base, "pill.png"), encodePngRgb(w, h, orange));
  writeFileSync(join(cap, "pill.png"), encodePngRgb(w, h, grey));
  const env = shotdiffIhdrEnv(dir, "400");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 11, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /DIFF pill\.png/);
  assert.match(run.stdout, /ratio=0\.01000/);
  const zone = /zone=(\d+),(\d+),(\d+)x(\d+) px=(\d+) dE=([0-9.]+)/.exec(run.stdout);
  assert.ok(zone, run.stdout);
  assert.equal(Number(zone[1]), 90);
  assert.equal(Number(zone[2]), 90);
  assert.equal(Number(zone[3]), 20);
  assert.equal(Number(zone[4]), 20);
  assert.equal(Number(zone[5]), 400);
  assert.ok(Number(zone[6]) >= 40, zone[6]);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff accepts typical antialiasing under default TOL", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-aa-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const w = 200;
  const h = 200;
  const bg = [240, 240, 240];
  const color = [20, 20, 20];
  const a = rgbCanvas(w, h, bg);
  const b = rgbCanvas(w, h, bg);
  fillCircleAa(a, w, h, 100.0, 100.0, 40.0, color, bg);
  fillCircleAa(b, w, h, 100.4, 100.0, 40.0, color, bg);
  writeFileSync(join(base, "edge.png"), encodePngRgb(w, h, a));
  writeFileSync(join(cap, "edge.png"), encodePngRgb(w, h, b));
  const env = shotdiffIhdrEnv(dir, "298");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 0, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /OK {3}edge\.png/);
  assert.doesNotMatch(run.stdout, /DIFF/);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff accepts a 3 px shifted button under default TOL", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-btn-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const w = 300;
  const h = 80;
  const bg = [240, 240, 240];
  const fg = [20, 20, 20];
  const a = rgbCanvas(w, h, bg);
  const b = rgbCanvas(w, h, bg);
  blitRgb(a, w, 20, 30, 92, 22, fg);
  blitRgb(b, w, 23, 30, 92, 22, fg);
  writeFileSync(join(base, "btn.png"), encodePngRgb(w, h, a));
  writeFileSync(join(cap, "btn.png"), encodePngRgb(w, h, b));
  const env = shotdiffIhdrEnv(dir, "132");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 0, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /OK {3}btn\.png/);
  assert.doesNotMatch(run.stdout, /DIFF/);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff accepts a 4 px vertically shifted pill under default TOL", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-pill4-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const w = 400;
  const h = 200;
  const bg = [240, 240, 240];
  const fg = [20, 20, 20];
  const a = rgbCanvas(w, h, bg);
  const b = rgbCanvas(w, h, bg);
  blitRgb(a, w, 40, 40, 232, 70, fg);
  blitRgb(b, w, 40, 44, 232, 70, fg);
  writeFileSync(join(base, "pill.png"), encodePngRgb(w, h, a));
  writeFileSync(join(cap, "pill.png"), encodePngRgb(w, h, b));
  const env = shotdiffIhdrEnv(dir, "500");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 0, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /OK {3}pill\.png/);
  assert.doesNotMatch(run.stdout, /DIFF/);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff accepts 1 px re-antialiased text under default TOL", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-textaa-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const w = 200;
  const h = 80;
  const bg = [240, 240, 240];
  const fg = [20, 20, 20];
  const a = rgbCanvas(w, h, bg);
  fillAaBars(a, w, h, 20, 20, 3, 4, 12, 21, fg, bg);
  const b = blurRgb1(a, w, h);
  writeFileSync(join(base, "text.png"), encodePngRgb(w, h, a));
  writeFileSync(join(cap, "text.png"), encodePngRgb(w, h, b));
  const env = shotdiffIhdrEnv(dir, "200");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 0, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /OK {3}text\.png/);
  assert.doesNotMatch(run.stdout, /DIFF/);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff fails a pale-blue pill replaced by grey (dE ~20)", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-pale-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const w = 200;
  const h = 200;
  const bg = [240, 240, 240];
  const pale = rgbCanvas(w, h, bg);
  const grey = rgbCanvas(w, h, bg);
  blitRgb(pale, w, 90, 90, 25, 25, [130, 157, 180]);
  blitRgb(grey, w, 90, 90, 25, 25, [121, 121, 121]);
  writeFileSync(join(base, "pill.png"), encodePngRgb(w, h, pale));
  writeFileSync(join(cap, "pill.png"), encodePngRgb(w, h, grey));
  const env = shotdiffIhdrEnv(dir, "625");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 11, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /DIFF pill\.png/);
  const zone = /zone=(\d+),(\d+),(\d+)x(\d+) px=(\d+) dE=([0-9.]+)/.exec(run.stdout);
  assert.ok(zone, run.stdout);
  assert.equal(Number(zone[1]), 90);
  assert.equal(Number(zone[2]), 90);
  assert.equal(Number(zone[3]), 25);
  assert.equal(Number(zone[4]), 25);
  assert.equal(Number(zone[5]), 625);
  const de = Number(zone[6]);
  assert.ok(de >= 15 && de < 40, zone[6]);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff fails a missing 20x15 banner under default TOL", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-banner-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const w = 200;
  const h = 200;
  const bg = [240, 240, 240];
  const a = rgbCanvas(w, h, bg);
  const b = rgbCanvas(w, h, bg);
  blitRgb(a, w, 40, 40, 20, 15, [200, 40, 40]);
  writeFileSync(join(base, "banner.png"), encodePngRgb(w, h, a));
  writeFileSync(join(cap, "banner.png"), encodePngRgb(w, h, b));
  const env = shotdiffIhdrEnv(dir, "300");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 11, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /DIFF banner\.png/);
  const zone = /zone=(\d+),(\d+),(\d+)x(\d+) px=(\d+) dE=([0-9.]+)/.exec(run.stdout);
  assert.ok(zone, run.stdout);
  assert.equal(Number(zone[1]), 40);
  assert.equal(Number(zone[2]), 40);
  assert.equal(Number(zone[3]), 20);
  assert.equal(Number(zone[4]), 15);
  assert.equal(Number(zone[5]), 300);
  assert.ok(Number(zone[6]) >= 40, zone[6]);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff fails a missing 186x68 bubble under default TOL", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-bubble-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const w = 400;
  const h = 200;
  const bg = [240, 240, 240];
  const a = rgbCanvas(w, h, bg);
  const b = rgbCanvas(w, h, bg);
  blitRgb(a, w, 40, 40, 186, 68, [30, 30, 30]);
  writeFileSync(join(base, "bubble.png"), encodePngRgb(w, h, a));
  writeFileSync(join(cap, "bubble.png"), encodePngRgb(w, h, b));
  const env = shotdiffIhdrEnv(dir, "500");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 11, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /DIFF bubble\.png/);
  const zone = /zone=(\d+),(\d+),(\d+)x(\d+) px=(\d+) dE=([0-9.]+)/.exec(run.stdout);
  assert.ok(zone, run.stdout);
  assert.equal(Number(zone[1]), 40);
  assert.equal(Number(zone[2]), 40);
  assert.equal(Number(zone[3]), 186);
  assert.equal(Number(zone[4]), 68);
  assert.equal(Number(zone[5]), 186 * 68);
  assert.ok(Number(zone[6]) >= 40, zone[6]);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff accepts a lossless 16-bit PNG re-encode under default TOL", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-16-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const w = 40;
  const h = 30;
  const rgb = rgbCanvas(w, h, [40, 80, 120]);
  blitRgb(rgb, w, 10, 8, 12, 10, [200, 30, 30]);
  writeFileSync(join(base, "depth.png"), encodePngRgb(w, h, rgb));
  writeFileSync(join(cap, "depth.png"), encodePngRgb16(w, h, rgb));
  const env = shotdiffIhdrEnv(dir, "1");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 0, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /OK {3}depth\.png/);
  assert.doesNotMatch(run.stdout, /DIFF/);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff ignores RGB that is fully transparent under default TOL", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-alpha-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const w = 200;
  const h = 200;
  const baseRgba = Buffer.alloc(w * h * 4);
  const capRgba = Buffer.alloc(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    baseRgba[i * 4] = 240;
    baseRgba[i * 4 + 1] = 240;
    baseRgba[i * 4 + 2] = 240;
    capRgba[i * 4] = 240;
    capRgba[i * 4 + 1] = 240;
    capRgba[i * 4 + 2] = 240;
  }
  for (let y = 90; y < 110; y++) {
    for (let x = 90; x < 110; x++) {
      const o = (y * w + x) * 4;
      capRgba[o] = 255;
      capRgba[o + 1] = 141;
      capRgba[o + 2] = 40;
    }
  }
  writeFileSync(join(base, "ghost.png"), encodePngRgba(w, h, baseRgba));
  writeFileSync(join(cap, "ghost.png"), encodePngRgba(w, h, capRgba));
  const env = shotdiffIhdrEnv(dir, "1");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 0, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /OK {3}ghost\.png/);
  assert.doesNotMatch(run.stdout, /DIFF/);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff flags black pixels that become transparent under default TOL", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-black-a-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const w = 200;
  const h = 200;
  const baseRgba = Buffer.alloc(w * h * 4, 255);
  const capRgba = Buffer.alloc(w * h * 4, 255);
  for (let y = 90; y < 110; y++) {
    for (let x = 90; x < 110; x++) {
      const o = (y * w + x) * 4;
      baseRgba[o] = 0;
      baseRgba[o + 1] = 0;
      baseRgba[o + 2] = 0;
      baseRgba[o + 3] = 255;
      capRgba[o] = 0;
      capRgba[o + 1] = 0;
      capRgba[o + 2] = 0;
      capRgba[o + 3] = 0;
    }
  }
  writeFileSync(join(base, "hole.png"), encodePngRgba(w, h, baseRgba));
  writeFileSync(join(cap, "hole.png"), encodePngRgba(w, h, capRgba));
  const env = shotdiffIhdrEnv(dir, "400");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 11, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /DIFF hole\.png/);
  assert.match(run.stdout, /zone=90,90,20x20/);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff treats 8-bit tRNS as a raw sample under default TOL", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-trns-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const w = 200;
  const h = 200;
  const grey = Buffer.alloc(w * h, 80);
  for (let y = 90; y < 110; y++) {
    for (let x = 90; x < 110; x++) {
      grey[y * w + x] = 121;
    }
  }
  writeFileSync(join(base, "key.png"), encodePngGrey8(w, h, grey, 121));
  writeFileSync(join(cap, "key.png"), encodePngGrey8(w, h, grey));
  const env = shotdiffIhdrEnv(dir, "190");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 11, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /DIFF key\.png/);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff accepts AE=0 for a 4-bit re-encode under default TOL", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-4bit-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const w = 40;
  const h = 30;
  const grey = Buffer.alloc(w * h, 85);
  writeFileSync(join(base, "depth4.png"), encodePngGrey8(w, h, grey));
  writeFileSync(join(cap, "depth4.png"), encodePngGrey4(w, h, grey));
  const env = shotdiffIhdrEnv(dir, "0");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 0, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /OK {3}depth4\.png/);
  assert.doesNotMatch(run.stdout, /DIFF/);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff fails closed when AE is nonzero and the PNG depth is 4-bit", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-4bit-ae-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const w = 40;
  const h = 30;
  const greyA = Buffer.alloc(w * h, 85);
  const greyB = Buffer.alloc(w * h, 170);
  writeFileSync(join(base, "g.png"), encodePngGrey8(w, h, greyA));
  writeFileSync(join(cap, "g.png"), encodePngGrey4(w, h, greyB));
  const env = shotdiffIhdrEnv(dir, "5");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 13, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stderr, /analyse locale impossible pour g\.png/);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff flags hd09-cancelled orange vs grey from #150 against main", () => {
  // Capture historique de #150 (c4138edb), figée hors baselines, indépendante de l'historique git.
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-hd09-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  mkdirSync(dif);
  const historic = readFileSync(join(ROOT, "test/fixtures/shotdiff/hd09-cancelled-c4138edb.png"));
  assert.equal(
    createHash("sha256").update(historic).digest("hex"),
    "0316fdd24dbf71459bd1c75a41cd812729a8e1a45545e4f2bc9d7671668617f1",
  );
  writeFileSync(join(cap, "hd09-cancelled.png"), historic);
  writeFileSync(
    join(base, "hd09-cancelled.png"),
    readFileSync(join(ROOT, ".cursor/skills/verify-hermed-bots/baselines/hd09-cancelled.png")),
  );
  const env = shotdiffIhdrEnv(dir, "428");
  const run = runShotdiff(cap, base, dif, env);
  assert.equal(run.status, 11, `out=${run.stdout} err=${run.stderr}`);
  assert.match(run.stdout, /DIFF hd09-cancelled\.png/);
  const ratio = /ratio=([0-9.]+)/.exec(run.stdout);
  assert.ok(ratio, run.stdout);
  assert.ok(Number(ratio[1]) < 0.02, ratio[1]);
  const zone = /zone=(\d+),(\d+),(\d+)x(\d+) px=(\d+) dE=([0-9.]+)/.exec(run.stdout);
  assert.ok(zone, run.stdout);
  assert.ok(Number(zone[1]) >= 640 && Number(zone[1]) <= 670, zone[1]);
  assert.ok(Number(zone[2]) >= 640 && Number(zone[2]) <= 670, zone[2]);
  assert.ok(Number(zone[3]) >= 20 && Number(zone[3]) <= 30, zone[3]);
  assert.ok(Number(zone[4]) >= 20 && Number(zone[4]) <= 30, zone[4]);
  assert.ok(Number(zone[5]) >= 300, zone[5]);
  assert.ok(Number(zone[6]) >= 40, zone[6]);
  rmSync(dir, { recursive: true, force: true });
});

test("hv-shotdiff accepts every baseline compared to itself", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-self-"));
  const dif = join(dir, "dif");
  mkdirSync(dif);
  const baselines = join(ROOT, ".cursor/skills/verify-hermed-bots/baselines");
  const pngs = readdirSync(baselines).filter((name) => name.endsWith(".png"));
  assert.ok(pngs.length > 0, "aucune référence PNG");
  const env = shotdiffIhdrEnv(dir, "0");
  const run = runShotdiff(baselines, baselines, dif, env);
  assert.equal(run.status, 0, `out=${run.stdout} err=${run.stderr}`);
  const oks = run.stdout.split("\n").filter((line) => /^OK\s/.test(line));
  const diffs = run.stdout.split("\n").filter((line) => /^DIFF /.test(line));
  assert.equal(diffs.length, 0, diffs.join("\n"));
  assert.equal(oks.length, pngs.length, `ok=${oks.length} png=${pngs.length}`);
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
  assert.equal(listed.length, 16, String(listed.length));
  assert.match(
    lacunes,
    /Les 26 PNG déjà versionnés dans `UIReferences\/` \(hors `issue58-version-missing-key\.png`/,
  );
  assert.match(lacunes, /Les noms ci-dessous n'ont toujours pas de binaire/);
  const settingsDark = [
    "piste1-connection-large-dark.png",
    "piste1-connection-standard-dark.png",
    "piste1-about-connecting-large-dark.png",
    "piste1-about-connecting-standard-dark.png",
    "piste1-about-failed-large-dark.png",
    "piste1-about-failed-standard-dark.png",
    "piste1-about-ready-large-dark.png",
    "piste1-about-ready-standard-dark.png",
    "piste1-about-untested-large-dark.png",
    "piste1-about-untested-standard-dark.png",
    "unreachable.png",
  ];
  for (const name of settingsDark) {
    assert.equal(existsSync(join(baselines, name)), true, name);
    assert.equal(listed.includes(name), false, name);
  }
  const promoted = [
    "design-compact-conversation.png",
    "design-compact-home.png",
    "design-dark-conversation.png",
    "design-dark-home.png",
    "hd13-local-state.png",
    "hd13-loop-guard.png",
    "hd13-ten-min-banner.png",
    "hd14-approval.png",
    "hd14-drop.png",
    "hd14-held.png",
    "hd14-no-write.png",
    "hd14-other.png",
    "hd14-release.png",
    "hd14-taken.png",
    "hd15-approval.png",
    "hd15-double.png",
    "hd15-drop.png",
    "hd15-idle.png",
    "hd15-kept.png",
    "hd15-no-tunnel.png",
  ];
  for (const name of promoted) {
    assert.equal(existsSync(join(baselines, name)), true, name);
    assert.equal(listed.includes(name), false, name);
  }
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

