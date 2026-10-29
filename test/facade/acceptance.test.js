"use strict";

// The six acceptance tests of the Hermes facade (PR-1). Each runs the real facade over real TLS
// in front of a stand-in for Hermes that listens on the loopback.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const { checkExposure } = require("../../facade/src/exposure");
const { createFacade } = require("../../facade/src/server");
const { generatePki } = require("../../facade/src/tls");
const { pki, startStack } = require("../../facade/testkit/stack");

const T0 = Date.parse("2026-10-29T12:00:00Z");

function clock(start = T0) {
  const state = { t: start };
  const now = () => state.t;
  now.advance = (ms) => {
    state.t += ms;
  };
  return now;
}

const WRITE = { session_id: "s1", text: "hello" };

function outsideAddress() {
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries || []) {
      if (!entry.internal && entry.family === "IPv4") return entry.address;
    }
  }
  return null;
}

test("1. no access without a valid token", async (t) => {
  const now = clock();
  const stack = await startStack({ now });
  t.after(() => stack.close());
  const paths = ["/api/sessions", "/api/sessions/s1/messages", "/facade/whoami", "/facade/status", "/facade/devices", "/facade/audit", "/anything"];
  const headers = [{}, { authorization: "Bearer " }, { authorization: "Bearer hbf_not-a-real-token" }, { authorization: "Basic dXNlcjpwYXNz" }, { authorization: `Bearer ${stack.hermes.token}` }];
  for (const p of paths) {
    now.advance(61_000);
    for (const h of headers) {
      const res = await stack.call({ path: p, headers: h });
      assert.equal(res.status, 401, `${p} ${JSON.stringify(h)}`);
      assert.deepEqual(res.json, { error: "unauthorized" });
    }
  }
  now.advance(61_000);
  await assert.rejects(stack.ws({ token: null }), (err) => err.status === 401);
  await assert.rejects(stack.ws({ token: "hbf_not-a-real-token" }), (err) => err.status === 401);
  assert.deepEqual(stack.hermes.requests, [], "an unauthenticated call never reaches Hermes");

  const device = await stack.enroll("normal");
  const ok = await stack.call({ path: "/api/sessions", token: device.token });
  assert.equal(ok.status, 200);
  assert.equal(ok.json.total, 1);
  const socket = await stack.ws({ token: device.token });
  const pong = await socket.call("ping");
  assert.deepEqual(pong.result, { pong: true });
  socket.close();
});

test("2. a revoked token is refused at once", async (t) => {
  const stack = await startStack();
  t.after(() => stack.close());
  const admin = await stack.enroll("admin", "admin device");
  const a = await stack.enroll("normal", "device a");
  const b = await stack.enroll("normal", "device b");
  const socketA = await stack.ws({ token: a.token });
  assert.deepEqual((await socketA.call("ping")).result, { pong: true });
  assert.equal((await stack.call({ path: "/facade/whoami", token: a.token })).status, 200);

  const revoked = await stack.call({ method: "DELETE", path: `/facade/devices/${a.device_id}`, token: admin.token });
  assert.equal(revoked.status, 204);

  assert.equal((await stack.call({ path: "/facade/whoami", token: a.token })).status, 401);
  assert.equal((await stack.call({ path: "/api/sessions", token: a.token })).status, 401);
  assert.equal(await socketA.closed(), 1008, "the open socket is cut when the device is revoked");
  await assert.rejects(stack.ws({ token: a.token }), (err) => err.status === 401);
  assert.equal((await stack.call({ path: "/facade/whoami", token: b.token })).status, 200, "other devices are untouched");

  const outside = new (require("../../facade/src/store").Store)({ file: stack.config.stateFile });
  outside.revoke(b.device_id);
  assert.equal((await stack.call({ path: "/facade/whoami", token: b.token })).status, 401, "a revocation made on the host applies on the next call");
});

test("3. TLS is validated by the pinned anchor", async (t) => {
  const stack = await startStack();
  t.after(() => stack.close());
  const good = await stack.call({ path: "/facade/whoami" });
  assert.equal(good.status, 401, "the handshake succeeds with the pinned anchor");

  const otherDir = fs.mkdtempSync(path.join(os.tmpdir(), "facade-other-pki-"));
  t.after(() => fs.rmSync(otherDir, { recursive: true, force: true }));
  const other = generatePki({ dir: otherDir });
  const wrongPin = await stack.call({ path: "/facade/whoami", pin: other.pin }).then(() => null, (err) => err);
  assert.match(wrongPin.message, /pinned key/);
  const wrongCa = await stack.call({ path: "/facade/whoami", ca: other.caCert }).then(() => null, (err) => err);
  assert.ok(wrongCa, "a certificate chain the client does not anchor is refused");
  const noAnchor = await stack.call({ path: "/facade/whoami", ca: undefined }).then(() => null, (err) => err);
  assert.ok(noAnchor, "the system roots are not a trust anchor for the facade");
  const wrongName = await stack.call({ path: "/facade/whoami", servername: "wrong-name" }).then(() => null, (err) => err);
  assert.ok(wrongName, "a certificate for another name is refused");

  const tls12 = await new Promise((resolve) => {
    const req = require("node:https").request({ host: "127.0.0.1", port: stack.port, ca: stack.trust.ca, servername: "localhost", maxVersion: "TLSv1.2" });
    req.on("error", (err) => resolve(err));
    req.on("response", () => resolve(null));
    req.end();
  });
  assert.ok(tls12, "TLS 1.2 is not offered");
});

test("4. a device never sees Hermes over HTTP", async (t) => {
  const stack = await startStack();
  t.after(() => stack.close());
  const device = await stack.enroll("normal");

  const plain = await new Promise((resolve) => {
    const socket = net.connect(stack.port, "127.0.0.1", () => socket.write("GET /api/sessions HTTP/1.1\r\nhost: x\r\nauthorization: Bearer x\r\n\r\n"));
    const chunks = [];
    socket.on("data", (c) => chunks.push(c));
    socket.on("close", () => resolve(Buffer.concat(chunks).toString("latin1")));
    socket.on("error", () => resolve(Buffer.concat(chunks).toString("latin1")));
    setTimeout(() => socket.destroy(), 1500).unref();
  });
  assert.doesNotMatch(plain, /HTTP\/1/, "the facade answers no plain HTTP");

  const read = await stack.call({ path: "/api/sessions?token=probe&limit=5", token: device.token, headers: { "x-hermes-session-token": "device-supplied", cookie: "a=b" } });
  assert.equal(read.status, 200);
  for (const name of ["set-cookie", "server", "x-hermes-session-token", "www-authenticate", "location"]) {
    assert.equal(read.headers[name], undefined, `${name} does not cross the facade`);
  }
  const seen = stack.hermes.requests.at(-1);
  assert.equal(seen.headers["x-hermes-session-token"], stack.hermes.token, "only the facade credential goes upstream");
  assert.equal(seen.headers.authorization, undefined);
  assert.equal(seen.headers.cookie, undefined);
  assert.equal(seen.url, "/api/sessions?limit=5", "device credentials in the query are dropped");

  const moved = await stack.call({ path: "/api/sessions/moved", token: device.token });
  assert.equal(moved.status, 502, "an upstream redirect is never relayed");
  assert.equal(moved.headers.location, undefined);

  const everything = JSON.stringify([read.body, moved.body]);
  assert.ok(!everything.includes(stack.hermes.token) && !everything.includes(String(stack.hermes.port)), "no internal credential or port in a reply");

  const status = await stack.call({ path: "/facade/status", token: device.token });
  assert.deepEqual(status.json, { hermes_version: "0.22.5", gateway_running: true, active_sessions: 2, overall: "ok" });
  assert.ok(!status.body.includes("home-value") && !status.body.includes("install_id"), "install details stay behind");
  const raw = await stack.call({ path: "/api/status", token: device.token });
  assert.equal(raw.status, 403, "the raw Hermes status route is not served");

  const tls = { key: pki().serverKey, cert: pki().serverCert };
  const foreign = outsideAddress();
  for (const host of ["::", "", "not-a-loopback", ...(foreign ? [foreign] : [])]) {
    assert.throws(() => createFacade({ ...stack.config, upstreamHost: host }, { tls }), /loopback/, `host ${host ? "(an address or name)" : "(empty)"}`);
  }
  assert.throws(() => createFacade({ ...stack.config, upstreamPort: stack.port, listenPort: stack.port }, { tls: { key: pki().serverKey, cert: pki().serverCert } }), /differ/);
});

test("4b. the facade refuses to start when Hermes is reachable beyond the loopback", async (t) => {
  const outside = outsideAddress();
  if (!outside) return t.skip("no non-loopback interface on this machine");
  const open = http.createServer((_req, res) => res.end("x"));
  await new Promise((resolve) => open.listen(0, outside, resolve));
  t.after(() => open.close());
  const port = open.address().port;
  const exposure = await checkExposure({ host: "127.0.0.1", port });
  assert.equal(exposure.ok, false);
  assert.ok(exposure.exposedOn >= 1);
  const stack = await startStack();
  t.after(() => stack.close());
  const refused = createFacade({ ...stack.config, upstreamPort: port, checkExposure: true, stateFile: path.join(stack.dir, "other.json"), auditFile: null, idempotencyFile: null }, { tls: { key: pki().serverKey, cert: pki().serverCert } });
  await assert.rejects(refused.start(), /refusing to start/);
  return undefined;
});

test("4c. the loopback-only check passes for a loopback bind", async (t) => {
  const quiet = http.createServer((_req, res) => res.end("x"));
  await new Promise((resolve) => quiet.listen(0, "127.0.0.1", resolve));
  t.after(() => quiet.close());
  const exposure = await checkExposure({ host: "127.0.0.1", port: quiet.address().port });
  assert.equal(exposure.ok, true);
  assert.equal(exposure.exposedOn, 0);
});

test("5. an expired or reused enrollment code is refused", async (t) => {
  const now = clock();
  const stack = await startStack({ now });
  t.after(() => stack.close());
  const enroll = (code, name = "phone") => stack.call({ method: "POST", path: "/facade/enroll", body: { code, name } });

  const first = stack.facade.store.createEnrollment({ role: "normal" });
  assert.equal(first.expiresAt - T0, 5 * 60 * 1000, "a code lives five minutes");
  now.advance(5 * 60 * 1000 - 1);
  const used = await enroll(first.code);
  assert.equal(used.status, 201, "valid until the last millisecond");
  assert.match(used.json.token, /^hbf_/);

  const reuse = await enroll(first.code);
  assert.equal(reuse.status, 401);
  assert.deepEqual(reuse.json, { error: "enrollment_invalid" });

  const second = stack.facade.store.createEnrollment({ role: "normal" });
  now.advance(5 * 60 * 1000);
  const late = await enroll(second.code);
  assert.equal(late.status, 401);
  assert.deepEqual(late.json, { error: "enrollment_invalid" });

  const unknown = await enroll("AAAAA-AAAAA-AAAAA-AAAAA");
  assert.deepEqual(unknown.json, { error: "enrollment_invalid" });

  const reasons = stack.facade.audit.recent().filter((e) => e.event === "enroll_denied").map((e) => e.reason);
  assert.deepEqual(reasons, ["reused", "expired", "unknown"]);

  const auditText = fs.readFileSync(stack.config.auditFile, "utf8");
  assert.ok(!auditText.includes(first.code) && !auditText.includes(used.json.token), "neither a code nor a token reaches the audit file");
  for (const line of auditText.trim().split("\n")) assert.match(JSON.parse(line).ts, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
});

test("6. writes are idempotent", async (t) => {
  const stack = await startStack({ delayMs: 120 });
  t.after(() => stack.close());
  const device = await stack.enroll("normal");
  const other = await stack.enroll("normal", "other device");
  const socket = await stack.ws({ token: device.token });
  const submit = (key, extra = {}, id) => socket.call("prompt.submit", { ...WRITE, idempotency_key: key, ...extra }, id);

  const first = await submit("key-00000001");
  assert.equal(first.result.status, "streaming");
  assert.equal(first.idempotent_replay, undefined);
  const again = await submit("key-00000001");
  assert.deepEqual(again.result, first.result, "same key, same answer");
  assert.equal(again.idempotent_replay, true);
  assert.equal(stack.hermes.calls["prompt.submit"], 1, "Hermes ran the write once");

  const fresh = await submit("key-00000002");
  assert.notDeepEqual(fresh.result, first.result);
  assert.equal(stack.hermes.calls["prompt.submit"], 2);

  const clash = await submit("key-00000001", { text: "something else" });
  assert.equal(clash.error.code, 4009);
  assert.equal(stack.hermes.calls["prompt.submit"], 2);

  const [x, y] = await Promise.all([submit("key-00000003", {}, "x"), submit("key-00000003", {}, "y")]);
  assert.deepEqual(x.result, y.result, "two parallel copies share one execution");
  assert.equal(stack.hermes.calls["prompt.submit"], 3);

  const missing = await socket.call("prompt.submit", WRITE);
  assert.equal(missing.error.code, 4004);
  const badKey = await socket.call("prompt.submit", { ...WRITE, idempotency_key: "short" });
  assert.equal(badKey.error.code, 4004);
  assert.equal(stack.hermes.calls["prompt.submit"], 3, "a write without a key never leaves the facade");

  const approve = await socket.call("approval.respond", { session_id: "s1", choice: "deny", idempotency_key: "key-approve-1" });
  const approveAgain = await socket.call("approval.respond", { session_id: "s1", choice: "deny", idempotency_key: "key-approve-1" });
  const cancel = await socket.call("session.interrupt", { session_id: "s1", idempotency_key: "key-cancel-01" });
  const cancelAgain = await socket.call("session.interrupt", { session_id: "s1", idempotency_key: "key-cancel-01" });
  assert.equal(approve.result.status, "resolved");
  assert.equal(approveAgain.idempotent_replay, true);
  assert.equal(cancel.result.status, "interrupted");
  assert.equal(cancelAgain.idempotent_replay, true);
  assert.equal(stack.hermes.calls["approval.respond"], 1);
  assert.equal(stack.hermes.calls["session.interrupt"], 1);

  socket.close();
  const reconnected = await stack.ws({ token: device.token });
  const afterReconnect = await reconnected.call("prompt.submit", { ...WRITE, idempotency_key: "key-00000001" });
  assert.equal(afterReconnect.idempotent_replay, true, "a retry on a new connection is replayed");
  assert.equal(stack.hermes.calls["prompt.submit"], 3);

  const otherSocket = await stack.ws({ token: other.token });
  const scoped = await otherSocket.call("prompt.submit", { ...WRITE, idempotency_key: "key-00000001" });
  assert.equal(scoped.idempotent_replay, undefined, "a key belongs to one device");
  assert.equal(stack.hermes.calls["prompt.submit"], 4);
  reconnected.close();
  otherSocket.close();
});

test("6b. a lost outcome is never run again", async (t) => {
  const stack = await startStack({ delayMs: 400 });
  t.after(() => stack.close());
  const device = await stack.enroll("normal");
  const socket = await stack.ws({ token: device.token });
  const pending = socket.call("prompt.submit", { ...WRITE, idempotency_key: "key-lost-0001" }, "p1").catch(() => null);
  await new Promise((resolve) => setTimeout(resolve, 60));
  stack.hermes.dropSockets();
  await pending;
  await socket.closed();
  const retry = await stack.ws({ token: device.token });
  const answer = await retry.call("prompt.submit", { ...WRITE, idempotency_key: "key-lost-0001" });
  assert.equal(answer.error.code, 4010);
  assert.equal(stack.hermes.calls["prompt.submit"], 1);
  retry.close();
});
