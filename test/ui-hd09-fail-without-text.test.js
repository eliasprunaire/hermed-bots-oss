"use strict";

const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const http = require("node:http");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const FAKE = join(ROOT, ".cursor/skills/verify-hermed-bots/scripts/hv-fake-hermes.py");
const PARTIAL = "Réponse de t";
const FULL = "Réponse de test";

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

async function waitReady(port) {
  const childEnv = { ...process.env };
  delete childEnv.HV_TEST_API_KEYS;
  delete childEnv.HV_TEST_API_KEY;
  const child = spawn("python3", [FAKE, "--port", String(port)], {
    env: childEnv,
    stdio: ["ignore", "pipe", "pipe"],
  });
  for (let i = 0; i < 50; i += 1) {
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
  for (const line of String(raw).split(/\r?\n/)) {
    if (line.startsWith("data: ")) events.push(JSON.parse(line.slice(6)));
  }
  return events;
}

function assistantDeltas(events) {
  return events
    .filter((ev) => ev && ev.event === "message.delta")
    .map((ev) => ev.delta)
    .filter((delta) => delta);
}

function completedOutputs(events) {
  return events
    .filter((ev) => ev && ev.event === "run.completed")
    .map((ev) => ev.output)
    .filter((output) => output);
}

async function startAndRead(port, input) {
  const started = await request(port, "/p/hv-bot-a/v1/runs", {
    method: "POST",
    body: JSON.stringify({ input, session_id: "s-open" }),
  });
  assert.equal(started.status, 202, started.raw);
  const runId = started.json && started.json.run_id;
  assert.ok(runId);
  const streamed = await request(port, `/p/hv-bot-a/v1/runs/${runId}/events`);
  assert.equal(streamed.status, 200, streamed.raw);
  return parseSse(streamed.raw);
}

test("sans le mode, le faux serveur émet toujours « Réponse de test »", async () => {
  const port = await freePort();
  const child = await waitReady(port);
  try {
    const cfg = await request(port, "/_hv/config");
    assert.equal(cfg.status, 200);
    assert.equal(cfg.json.fail_without_text, false);

    const events = await startAndRead(port, "HV_PACE_1 defaut");
    assert.ok(assistantDeltas(events).includes(FULL), JSON.stringify(assistantDeltas(events)));
    assert.ok(completedOutputs(events).includes(FULL), JSON.stringify(completedOutputs(events)));
  } finally {
    child.kill("SIGTERM");
  }
});

test("échec sans texte : failed et failed-error sans texte assistant ; cancelled et interrupted tronqués", async () => {
  const port = await freePort();
  const child = await waitReady(port);
  const cases = [
    {
      name: "hd09-failed",
      event: { event: "run.completed", status: "failed" },
      expectPartial: false,
      terminal: (events) =>
        events.some((ev) => ev.event === "run.completed" && ev.status === "failed"),
    },
    {
      name: "hd09-failed-error",
      event: { event: "run.failed", error: "HTTP 400: hv fake provider failure" },
      expectPartial: false,
      terminal: (events) =>
        events.some((ev) => ev.event === "run.failed" && ev.error === "HTTP 400: hv fake provider failure"),
    },
    {
      name: "hd09-cancelled",
      event: { event: "run.cancelled", turn_exit_reason: "interrupted_by_user" },
      expectPartial: true,
      terminal: (events) => events.some((ev) => ev.event === "run.cancelled"),
    },
    {
      name: "hd09-interrupted",
      event: { event: "run.interrupted", error: "The gateway restarted before this run settled." },
      expectPartial: true,
      terminal: (events) => events.some((ev) => ev.event === "run.interrupted"),
    },
  ];
  try {
    for (const item of cases) {
      const reset = await request(port, "/_hv/reset", { method: "POST", body: "{}" });
      assert.equal(reset.status, 200, item.name);
      const posted = await request(port, "/_hv/config", {
        method: "POST",
        body: JSON.stringify({ fail_without_text: true }),
      });
      assert.equal(posted.status, 200, item.name);
      const cfg = await request(port, "/_hv/config");
      assert.equal(cfg.json.fail_without_text, true, item.name);

      const injected = await request(port, "/_hv/inject", {
        method: "POST",
        body: JSON.stringify(item.event),
      });
      assert.equal(injected.status, 200, item.name);

      const events = await startAndRead(port, `HV_PACE_1 ${item.name}`);
      const deltas = assistantDeltas(events);
      const outputs = completedOutputs(events);
      assert.equal(deltas.includes(FULL), false, `${item.name} delta complet: ${JSON.stringify(deltas)}`);
      assert.equal(outputs.includes(FULL), false, `${item.name} output complet: ${JSON.stringify(outputs)}`);
      assert.ok(item.terminal(events), `${item.name} terminal absent: ${JSON.stringify(events.map((ev) => ev.event))}`);
      if (item.expectPartial) {
        assert.deepEqual(deltas, [PARTIAL], `${item.name} partiel: ${JSON.stringify(deltas)}`);
      } else {
        assert.deepEqual(deltas, [], `${item.name} deltas: ${JSON.stringify(deltas)}`);
      }

      const messages = await request(port, "/p/hv-bot-a/api/sessions/s-open/messages");
      const recorded = (messages.json && messages.json.data) || [];
      const lastAssistant = [...recorded].reverse().find((row) => row.role === "assistant");
      if (item.expectPartial) {
        assert.equal(lastAssistant && lastAssistant.content, PARTIAL, item.name);
      } else {
        assert.equal(lastAssistant && lastAssistant.content, FULL, `${item.name} seed`);
        const turnUser = recorded.filter((row) => row.role === "user" && row.content === `HV_PACE_1 ${item.name}`);
        assert.equal(turnUser.length, 1, item.name);
        const afterUser = recorded.slice(recorded.findIndex((row) => row.content === `HV_PACE_1 ${item.name}`) + 1);
        assert.equal(
          afterUser.some((row) => row.role === "assistant"),
          false,
          `${item.name} transcript: ${JSON.stringify(afterUser)}`,
        );
      }
    }

    const reset = await request(port, "/_hv/reset", { method: "POST", body: "{}" });
    assert.equal(reset.status, 200);
    const cfg = await request(port, "/_hv/config");
    assert.equal(cfg.json.fail_without_text, false);
    const events = await startAndRead(port, "HV_PACE_1 apres-reset");
    assert.ok(assistantDeltas(events).includes(FULL));
  } finally {
    child.kill("SIGTERM");
  }
});

test("un événement injecté hors mode émet toujours « Réponse de test »", async () => {
  const port = await freePort();
  const child = await waitReady(port);
  try {
    const injected = await request(port, "/_hv/inject", {
      method: "POST",
      body: JSON.stringify({ event: "hv.unknown_future_event", payload: { x: 2 } }),
    });
    assert.equal(injected.status, 200);
    const events = await startAndRead(port, "HV_PACE_1 inconnu");
    assert.ok(assistantDeltas(events).includes(FULL));
    assert.ok(events.some((ev) => ev.event === "hv.unknown_future_event"));
  } finally {
    child.kill("SIGTERM");
  }
});
