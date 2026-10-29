"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createFacade } = require("../src/server");
const { generatePki } = require("../src/tls");
const { connectWs, request } = require("./client");
const { startFakeHermes } = require("./fake-hermes");

let sharedPki = null;

function pki() {
  if (!sharedPki) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "facade-pki-"));
    sharedPki = { ...generatePki({ dir }), dir };
  }
  return sharedPki;
}

// Fake Hermes + facade on the loopback, real TLS, real enrollment calls.
async function startStack({ now, ratePerMinute = 1000, delayMs = 0, checkExposure = false } = {}) {
  const material = pki();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "facade-state-"));
  const hermes = await startFakeHermes({ delayMs });
  const config = {
    stateDir: dir,
    stateFile: path.join(dir, "state.json"),
    auditFile: path.join(dir, "audit.jsonl"),
    listenHost: "127.0.0.1",
    listenPort: 0,
    upstreamHost: "127.0.0.1",
    upstreamPort: hermes.port,
    upstreamToken: hermes.token,
    ratePerMinute,
    checkExposure,
  };
  const facade = createFacade(config, { now, tls: { key: material.serverKey, cert: material.serverCert } });
  const port = await facade.start();
  const trust = { ca: material.caCert, pin: material.pin };

  const call = (options) => request({ port, ...trust, ...options });
  const stack = {
    port,
    hermes,
    facade,
    config,
    trust,
    dir,
    call,
    ws: (options) => connectWs({ port, ...trust, ...options }),
    async enroll(role = "normal", name = "test device") {
      const { code } = facade.store.createEnrollment({ role });
      const res = await call({ method: "POST", path: "/facade/enroll", body: { code, name } });
      if (res.status !== 201) throw new Error(`enroll failed ${res.status}`);
      return res.json;
    },
    async close() {
      await facade.close();
      await hermes.close();
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
  return stack;
}

module.exports = { pki, startStack };
