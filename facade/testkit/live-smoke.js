#!/usr/bin/env node
"use strict";

// Live check of the facade in front of a Hermes TEST instance (never a production one).
// HERMES_TEST_PORT and HERMES_TEST_TOKEN name a `hermes serve` that runs on the loopback with a
// throwaway data directory, and HERMES_TEST_HOME names that directory. The script writes
// nothing until `assertDisposable` proves that the directory carries the disposable marker and
// that the running instance reports the same directory. Nothing here prints a credential.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createFacade } = require("../src/server");
const { generatePki } = require("../src/tls");
const { connectWs, request } = require("./client");
const { assertDisposable } = require("./disposable");

const port = Number(process.env.HERMES_TEST_PORT);
const token = process.env.HERMES_TEST_TOKEN;
if (!port || !token) {
  process.stderr.write("HERMES_TEST_PORT and HERMES_TEST_TOKEN are required\n");
  process.exit(2);
}

let failed = 0;
function check(name, ok, detail = "") {
  if (!ok) failed += 1;
  process.stdout.write(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` (${detail})` : ""}\n`);
}

async function main() {
  await assertDisposable({ port, token, home: process.env.HERMES_TEST_HOME });
  check("the instance is marked disposable and reports the marked data directory", true);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "facade-live-"));
  const material = generatePki({ dir: path.join(dir, "tls") });
  const config = {
    stateDir: dir,
    stateFile: path.join(dir, "state.json"),
    auditFile: path.join(dir, "audit.jsonl"),
    idempotencyFile: path.join(dir, "idempotency.jsonl"),
    listenHost: "127.0.0.1",
    listenPort: 0,
    upstreamHost: "127.0.0.1",
    upstreamPort: port,
    upstreamToken: token,
    ratePerMinute: 1000,
    checkExposure: true,
  };
  const facade = createFacade(config, { tls: { key: material.serverKey, cert: material.serverCert } });
  const facadePort = await facade.start();
  check("start: the Hermes port is loopback-only and the facade serves TLS", true);
  const trust = { ca: material.caCert, pin: material.pin };
  const call = (options) => request({ port: facadePort, ...trust, ...options });

  try {
    check("no token, no access", (await call({ path: "/api/sessions" })).status === 401);
    const code = facade.store.createEnrollment({ role: "normal" }).code;
    const enrolled = await call({ method: "POST", path: "/facade/enroll", body: { code, name: "live smoke" } });
    check("enrollment code gives a device token", enrolled.status === 201);
    const reused = await call({ method: "POST", path: "/facade/enroll", body: { code, name: "again" } });
    check("the same code twice is refused", reused.status === 401);

    const bearer = enrolled.json.token;
    const status = await call({ path: "/facade/status", token: bearer });
    check("facade status is projected from Hermes", status.status === 200 && /^\d+\.\d+\.\d+/.test(status.json.hermes_version), `version ${status.json && status.json.hermes_version}`);
    check("the projection carries no install detail", !/hermes_home|config_path|env_path|install_id/.test(status.body));
    const raw = await call({ path: "/api/status", token: bearer });
    check("the raw Hermes status route is closed", raw.status === 403);
    const sessions = await call({ path: "/api/sessions", token: bearer });
    check("a read reaches Hermes through the facade", [200, 503].includes(sessions.status), `status ${sessions.status}`);
    check("no Hermes credential header comes back", !sessions.headers["set-cookie"] && !sessions.headers["x-hermes-session-token"]);

    const ws = await connectWs({ port: facadePort, token: bearer, ...trust });
    const ping = await ws.call("ping");
    check("ping through the bridge", ping.result && ping.result.pong === true);
    const denied = await ws.call("shell.exec", { command: "id" });
    check("shell.exec never leaves the facade", denied.error && denied.error.code === 4003);
    const noKey = await ws.call("session.create", {});
    check("a write without an idempotency key is refused", noKey.error && noKey.error.code === 4004);

    const created = await ws.call("session.create", { idempotency_key: "live-create-0001" });
    check("session.create reaches Hermes", created.result && typeof created.result.session_id === "string");
    const createdAgain = await ws.call("session.create", { idempotency_key: "live-create-0001" });
    check("session.create replayed, not run twice", createdAgain.idempotent_replay === true && createdAgain.result.session_id === created.result.session_id);

    const sid = created.result.session_id;
    const submit = await ws.call("prompt.submit", { session_id: sid, text: "ping", idempotency_key: "live-prompt-0001" });
    check("prompt.submit reaches Hermes", submit.result && submit.result.status === "streaming", `row ${submit.result && submit.result.user_row_id}`);
    const submitAgain = await ws.call("prompt.submit", { session_id: sid, text: "ping", idempotency_key: "live-prompt-0001" });
    check("prompt.submit replayed with the same row", submitAgain.idempotent_replay === true && submitAgain.result.user_row_id === submit.result.user_row_id);
    await new Promise((resolve) => setTimeout(resolve, 1500));
    const interrupt = await ws.call("session.interrupt", { session_id: sid, idempotency_key: "live-cancel-0001" });
    check("session.interrupt reaches Hermes", interrupt.result && interrupt.result.status === "interrupted");
    const approval = await ws.call("approval.respond", { session_id: sid, choice: "deny", idempotency_key: "live-approve-0001" });
    check("approval.respond reaches Hermes", Boolean(approval.result || approval.error), approval.error ? `hermes answered ${approval.error.code}` : "resolved");
    const list = await ws.call("session.list", {});
    const rows = (list.result && list.result.sessions) || [];
    const mine = rows.filter((s) => s.id === created.result.stored_session_id);
    check("one prompt row after two identical submissions", mine.length === 1 && mine[0].message_count === 1, `${rows.length} session(s) listed`);
    ws.close();

    const admin = facade.store.createEnrollment({ role: "admin" }).code;
    const adminDevice = (await call({ method: "POST", path: "/facade/enroll", body: { code: admin, name: "live admin" } })).json;
    const revoked = await call({ method: "DELETE", path: `/facade/devices/${enrolled.json.device_id}`, token: adminDevice.token });
    check("an admin revokes a device", revoked.status === 204);
    check("the revoked token is refused at once", (await call({ path: "/api/sessions", token: bearer })).status === 401);
    check("another device keeps working", (await call({ path: "/facade/whoami", token: adminDevice.token })).status === 200);

    const audit = fs.readFileSync(config.auditFile, "utf8");
    check("the audit file holds no token and no code", !audit.includes(bearer) && !audit.includes(code) && !audit.includes(token));
    check("audit timestamps are UTC", audit.trim().split("\n").every((line) => /Z"/.test(line) && /^\{"ts":"\d{4}-\d\d-\d\dT[\d:.]+Z"/.test(line)));
  } finally {
    await facade.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
  process.stdout.write(failed ? `${failed} check(s) failed\n` : "all checks passed\n");
  process.exit(failed ? 1 : 0);
}

main().catch((err) => {
  process.stderr.write(`${err.stack || err.message}\n`);
  process.exit(1);
});
