#!/usr/bin/env node
"use strict";

// Time added by the facade on one read: 300 sequential GET /api/sessions on a kept-alive
// connection, direct to the stand-in for Hermes and through the facade (pinned TLS, device
// token). Prints medians and p95 in milliseconds, and the added median.

const http = require("node:http");
const https = require("node:https");
const { pinnedClientOptions } = require("../src/tls");
const { startStack } = require("./stack");

const RUNS = 300;

function timeEach(agent, mod, options) {
  const out = [];
  const once = () =>
    new Promise((resolve, reject) => {
      const started = process.hrtime.bigint();
      const req = mod.request({ ...options, agent }, (res) => {
        res.resume();
        res.on("end", () => {
          out.push(Number(process.hrtime.bigint() - started) / 1e6);
          resolve();
        });
      });
      req.on("error", reject);
      req.end();
    });
  return (async () => {
    for (let i = 0; i < 20; i++) await once();
    out.length = 0;
    for (let i = 0; i < RUNS; i++) await once();
    return out.sort((a, b) => a - b);
  })();
}

const pick = (sorted, q) => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * q))];

async function main() {
  const stack = await startStack();
  try {
    const device = await stack.enroll("normal");
    const direct = await timeEach(new http.Agent({ keepAlive: true }), http, {
      host: "127.0.0.1",
      port: stack.hermes.port,
      path: "/api/sessions",
      headers: { "x-hermes-session-token": stack.hermes.token },
    });
    const pinned = pinnedClientOptions({ caPem: stack.trust.ca, pin: stack.trust.pin });
    const through = await timeEach(new https.Agent({ keepAlive: true, ...pinned }), https, {
      host: "127.0.0.1",
      port: stack.port,
      servername: "localhost",
      path: "/api/sessions",
      ...pinned,
      headers: { authorization: `Bearer ${device.token}` },
    });
    const fmt = (n) => n.toFixed(2);
    process.stdout.write(`direct   median ${fmt(pick(direct, 0.5))} ms  p95 ${fmt(pick(direct, 0.95))} ms\n`);
    process.stdout.write(`facade   median ${fmt(pick(through, 0.5))} ms  p95 ${fmt(pick(through, 0.95))} ms\n`);
    process.stdout.write(`added    median ${fmt(pick(through, 0.5) - pick(direct, 0.5))} ms\n`);
  } finally {
    await stack.close();
  }
}

main().catch((err) => {
  process.stderr.write(`${err.stack || err.message}\n`);
  process.exit(1);
});
