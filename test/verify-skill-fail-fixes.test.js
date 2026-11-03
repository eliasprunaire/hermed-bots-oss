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
const SHOTDIFF = join(ROOT, ".cursor/skills/verify-hermed-bots/scripts/hv-shotdiff.sh");
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

test("hv-shotdiff rejects a large ratio under fr_FR and C locales", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-shot-"));
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap);
  mkdirSync(base);
  // Two very different solid PNGs → ratio well above 0.02.
  const mk = (path, color) => {
    const r = spawnSync(
      "magick",
      ["-size", "40x40", `xc:${color}`, path],
      { encoding: "utf8" },
    );
    assert.equal(r.status, 0, r.stderr);
  };
  mk(join(base, "x.png"), "white");
  mk(join(cap, "x.png"), "black");

  for (const locale of ["C", "fr_FR.UTF-8"]) {
    const run = spawnSync("bash", [SHOTDIFF, cap, base, join(dif, locale), "0.02"], {
      encoding: "utf8",
      env: { ...process.env, LC_ALL: locale, LANG: locale },
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
  // 100x100 white vs white+50x5 black bar → ~2.5 % AE (between 0.02 and 0.03).
  const mkBase = spawnSync(
    "magick",
    ["-size", "100x100", "xc:white", join(base, "x.png")],
    { encoding: "utf8" },
  );
  assert.equal(mkBase.status, 0, mkBase.stderr);
  const mkCap = spawnSync(
    "magick",
    [
      join(base, "x.png"),
      "-fill",
      "black",
      "-draw",
      "rectangle 0,0 49,4",
      join(cap, "x.png"),
    ],
    { encoding: "utf8" },
  );
  assert.equal(mkCap.status, 0, mkCap.stderr);
  const fake = spawnSync("bash", [SHOTDIFF, cap, base, join(dif, "fake"), "0.02"], {
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C" },
  });
  assert.equal(fake.status, 11, `fake tol out=${fake.stdout}`);
  assert.match(fake.stdout, /DIFF/);
  const orb = spawnSync("bash", [SHOTDIFF, cap, base, join(dif, "orb"), "0.03"], {
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C" },
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
