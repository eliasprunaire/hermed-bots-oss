"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { Writable } = require("node:stream");
const { Audit } = require("../../facade/src/audit");
const { main } = require("../../facade/bin/hermes-facade");
const { fromEnv, isLoopbackHost } = require("../../facade/src/config");
const { Idempotency, fingerprint } = require("../../facade/src/idempotency");
const { rpcClass } = require("../../facade/src/policy");
const { RateLimiter } = require("../../facade/src/ratelimit");
const { Store } = require("../../facade/src/store");
const { generatePki, spkiPin } = require("../../facade/src/tls");
const { WebSocketPeer, encodeFrame } = require("../../facade/src/websocket");
const { startStack } = require("../../facade/testkit/stack");
const { EventEmitter } = require("node:events");

const T0 = Date.parse("2026-10-29T12:00:00Z");

function tmp(prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  return dir;
}

test("roles: a normal device cannot administer, nobody reaches shell, config or vault methods", async (t) => {
  const stack = await startStack();
  t.after(() => stack.close());
  const admin = await stack.enroll("admin", "admin device");
  const normal = await stack.enroll("normal", "normal device");

  for (const route of [
    { method: "GET", path: "/facade/devices" },
    { method: "GET", path: "/facade/audit" },
    { method: "POST", path: "/facade/enrollments", body: { role: "admin" } },
    { method: "DELETE", path: `/facade/devices/${admin.device_id}` },
  ]) {
    assert.equal((await stack.call({ ...route, token: normal.token })).status, 403, route.path);
  }
  const list = await stack.call({ path: "/facade/devices", token: admin.token });
  assert.equal(list.status, 200);
  assert.equal(list.json.devices.length, 2);
  assert.ok(!list.body.includes("tokenHash") && !list.body.includes("hbf_"));
  assert.equal((await stack.call({ path: "/facade/audit", token: admin.token })).status, 200);

  const made = await stack.call({ method: "POST", path: "/facade/enrollments", token: admin.token, body: { role: "normal" } });
  assert.equal(made.status, 201);
  assert.match(made.json.code, /^[A-Z0-9]{5}(-[A-Z0-9]{5}){3}$/);
  assert.equal((await stack.call({ method: "POST", path: "/facade/enrollments", token: admin.token, body: { role: "root" } })).status, 400);

  for (const [who, token] of [["admin", admin.token], ["normal", normal.token]]) {
    const socket = await stack.ws({ token });
    for (const method of ["shell.exec", "cli.exec", "config.set", "vault.add", "slash.exec", "session.foreign.import", "unknown.method"]) {
      const reply = await socket.call(method, {});
      assert.equal(reply.error.code, 4003, `${who} ${method}`);
    }
    socket.close();
  }
  assert.equal(stack.hermes.calls["shell.exec"], undefined);
  assert.equal(stack.hermes.calls["config.set"], undefined);

  const adminSocket = await stack.ws({ token: admin.token });
  const normalSocket = await stack.ws({ token: normal.token });
  const del = { session_id: "s1", idempotency_key: "key-delete-01" };
  assert.equal((await normalSocket.call("session.delete", del)).error.code, 4003);
  assert.equal((await adminSocket.call("session.delete", del)).result.status, "ok");
  adminSocket.close();
  normalSocket.close();

  assert.equal((await stack.call({ method: "DELETE", path: "/api/sessions/s1", token: normal.token })).status, 403);
  assert.equal((await stack.call({ method: "POST", path: "/api/sessions/bulk-delete", token: admin.token, body: {} })).status, 403);
  assert.equal((await stack.call({ path: "/api/sessions/..%2f..%2fetc", token: normal.token })).status, 403);
});

test("rate limit: a device is slowed, and repeated failures block the source before it can guess", async (t) => {
  let now = T0;
  const stack = await startStack({ now: () => now, ratePerMinute: 5 });
  t.after(() => stack.close());
  const device = await stack.enroll("normal");
  const statuses = [];
  for (let i = 0; i < 7; i++) statuses.push((await stack.call({ path: "/facade/whoami", token: device.token })).status);
  assert.deepEqual(statuses, [200, 200, 200, 200, 200, 429, 429]);
  const limited = await stack.call({ path: "/facade/whoami", token: device.token });
  assert.ok(Number(limited.headers["retry-after"]) >= 1);
  now += 61_000;
  assert.equal((await stack.call({ path: "/facade/whoami", token: device.token })).status, 200);

  const socket = await stack.ws({ token: device.token });
  const replies = [];
  for (let i = 0; i < 6; i++) replies.push(await socket.call("ping"));
  assert.ok(replies.some((r) => r.error && r.error.code === 4029), "the socket is limited too");
  socket.close();

  now += 61_000;
  for (let i = 0; i < 30; i++) await stack.call({ path: "/facade/whoami", token: "hbf_guess" });
  const blocked = await stack.call({ path: "/facade/whoami", token: device.token });
  assert.equal(blocked.status, 429, "after 30 failures the source is blocked even with a good token");
  now += 61_000;
  assert.equal((await stack.call({ path: "/facade/whoami", token: device.token })).status, 200);
});

test("enrollment: bad names and bodies are refused and the attempts are limited", async (t) => {
  const stack = await startStack();
  t.after(() => stack.close());
  const { code } = stack.facade.store.createEnrollment({ role: "normal" });
  for (const body of [{ code, name: "" }, { code, name: "x".repeat(65) }, { code, name: "<script>" }, { name: "n" }, { code: 12, name: "n" }]) {
    assert.equal((await stack.call({ method: "POST", path: "/facade/enroll", body })).status, 400, JSON.stringify(body));
  }
  const ok = await stack.call({ method: "POST", path: "/facade/enroll", body: { code: code.toLowerCase().replace(/-/g, " "), name: "Phone d'Elias (1)" } });
  assert.equal(ok.status, 201, "a code typed in lower case with spaces is accepted");
  const big = await stack.call({ method: "POST", path: "/facade/enroll", body: { code, name: "n".repeat(6000) } });
  assert.ok([400, 413].includes(big.status));
  let last = 0;
  for (let i = 0; i < 12; i++) last = (await stack.call({ method: "POST", path: "/facade/enroll", body: { code: "NOPE", name: "n" } })).status;
  assert.equal(last, 429);
});

test("websocket: bad messages get JSON-RPC errors, and the device socket is bounded", async (t) => {
  const stack = await startStack();
  t.after(() => stack.close());
  const device = await stack.enroll("normal");
  const socket = await stack.ws({ token: device.token });
  socket.sendRaw("not json");
  assert.equal((await socket.wait((m) => m.error && m.error.code === -32700)).id, null);
  socket.sendRaw(JSON.stringify([1, 2]));
  assert.equal((await socket.wait((m) => m.error && m.error.code === -32600)).id, null);
  assert.equal((await socket.call("ping", [1])).error.code, 4000);
  socket.sendRaw(JSON.stringify({ jsonrpc: "2.0", id: null, method: "prompt.submit", params: { session_id: "s", text: "t", idempotency_key: "key-00000009" } }));
  const noId = await socket.wait((m) => m.error && m.error.code === 4000 && /id/.test(m.error.message));
  assert.equal(noId.id, null);
  assert.equal(stack.hermes.calls["prompt.submit"], undefined, "a write without an id never leaves the facade");
  socket.close();
});

test("a Hermes that is down gives a 502 on reads and a closed socket, never a hang", async (t) => {
  const stack = await startStack();
  t.after(() => stack.close());
  const device = await stack.enroll("normal");
  await stack.hermes.close();
  const read = await stack.call({ path: "/api/sessions", token: device.token });
  assert.equal(read.status, 502);
  assert.deepEqual(read.json, { error: "upstream_unavailable" });
  const socket = await stack.ws({ token: device.token });
  assert.equal(await socket.closed(), 1012);
  assert.equal((await stack.call({ path: "/facade/status", token: device.token })).status, 502);
  stack.hermes.close = async () => {};
});

test("websocket codec: fragmented, large, ping and protocol errors", () => {
  function pair(options = {}) {
    const socket = new EventEmitter();
    const written = [];
    socket.write = (b) => written.push(Buffer.from(b));
    socket.end = () => {};
    socket.destroy = () => {};
    const peer = new WebSocketPeer(socket, options);
    const messages = [];
    const closes = [];
    peer.on("message", (m) => messages.push(m));
    peer.on("close", (c) => closes.push(c));
    return { socket, peer, written, messages, closes };
  }
  const raw = (opcode, payload, { fin = true } = {}) => {
    const f = encodeFrame(opcode, payload, { mask: true });
    if (!fin) f[0] &= 0x7f;
    return f;
  };

  let p = pair();
  p.socket.emit("data", raw(1, "hel", { fin: false }));
  assert.deepEqual(p.messages, []);
  p.socket.emit("data", raw(0, "lo"));
  assert.deepEqual(p.messages, ["hello"]);

  const big = "x".repeat(70_000);
  p = pair();
  const bigFrame = raw(1, big);
  p.socket.emit("data", bigFrame.subarray(0, 5));
  p.socket.emit("data", bigFrame.subarray(5));
  assert.equal(p.messages[0].length, 70_000);

  p = pair();
  p.socket.emit("data", raw(9, "pp"));
  assert.equal(p.written[0][0], 0x8a, "a ping is answered with a pong");

  p = pair();
  p.socket.emit("data", encodeFrame(1, "unmasked", { mask: false }));
  assert.deepEqual(p.closes, [1002], "a client frame must be masked");

  p = pair({ maxMessageBytes: 10 });
  p.socket.emit("data", raw(1, "x".repeat(11)));
  assert.deepEqual(p.closes, [1009]);

  p = pair();
  p.socket.emit("data", raw(2, Buffer.from([1, 2])));
  assert.deepEqual(p.closes, [1003], "binary is refused");

  p = pair();
  p.socket.emit("data", raw(1, Buffer.from([0xff, 0xfe])));
  assert.deepEqual(p.closes, [1007], "invalid UTF-8 is refused");

  p = pair();
  p.socket.emit("data", raw(8, Buffer.from([0x03, 0xe8])));
  assert.deepEqual(p.closes, [1000]);
});

test("store: tokens and codes are kept as hashes, state survives a restart", () => {
  const dir = tmp("facade-store-");
  const file = path.join(dir, "state.json");
  let now = T0;
  const store = new Store({ file, now: () => now });
  const { code } = store.createEnrollment({ role: "admin" });
  const redeemed = store.redeemEnrollment(code, "laptop");
  assert.equal(redeemed.ok, true);
  const text = fs.readFileSync(file, "utf8");
  assert.ok(!text.includes(redeemed.token) && !text.includes(code.replace(/-/g, "")), "only hashes on disk");
  assert.equal((fs.statSync(file).mode & 0o777), 0o600);
  const again = new Store({ file, now: () => now });
  assert.equal(again.authenticate(redeemed.token).role, "admin");
  assert.equal(again.authenticate(`${redeemed.token}x`), null);
  assert.equal(again.authenticate(null), null);
  again.revoke(redeemed.device.id);
  assert.equal(store.authenticate(redeemed.token), null, "a second handle on the file sees the revocation");
  assert.equal(store.revoke("dev_0000000000000000"), null);
  assert.throws(() => store.createEnrollment({ role: "root" }), /role/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("audit: UTC timestamps, secrets masked", () => {
  const dir = tmp("facade-audit-");
  const audit = new Audit({ file: path.join(dir, "a.jsonl"), now: () => T0 });
  const entry = audit.record("probe", { token: "hbf_secret", code: "AAAAA", Authorization: "Bearer x", device: "dev_1" });
  assert.equal(entry.ts, "2026-10-29T12:00:00.000Z");
  assert.equal(entry.token, "[redacted]");
  assert.equal(entry.code, "[redacted]");
  assert.equal(entry.Authorization, "[redacted]");
  assert.equal(entry.device, "dev_1");
  assert.ok(!fs.readFileSync(path.join(dir, "a.jsonl"), "utf8").includes("hbf_secret"));
  fs.rmSync(dir, { recursive: true, force: true });
});

test("rate limiter, idempotency and policy units", async () => {
  let now = 0;
  const limiter = new RateLimiter({ limit: 2, windowMs: 1000, now: () => now });
  assert.equal(limiter.take("k").ok, true);
  assert.equal(limiter.take("k").ok, true);
  assert.deepEqual(limiter.take("k"), { ok: false, retryAfterMs: 1000 });
  assert.equal(limiter.peek("k").ok, false);
  now = 1000;
  assert.equal(limiter.take("k").ok, true);

  const idem = new Idempotency({ now: () => now, ttlMs: 1000 });
  const print = fingerprint("m", { b: 1, a: [1, 2] });
  assert.equal(print, fingerprint("m", { a: [1, 2], b: 1 }), "key order does not matter");
  assert.notEqual(print, fingerprint("m", { a: [1, 2], b: 2 }));
  assert.equal(idem.begin("d", "key-00000001", print).state, "new");
  const waiting = idem.begin("d", "key-00000001", print);
  assert.equal(waiting.state, "pending");
  idem.complete("d", "key-00000001", { ok: 1 });
  assert.deepEqual(await waiting.wait, { state: "replay", result: { ok: 1 } });
  assert.equal(idem.begin("d", "key-00000001", "other").state, "conflict");
  now += 1000;
  assert.equal(idem.begin("d", "key-00000001", print).state, "new", "a finished key expires");
  idem.release("d", "key-00000001");
  assert.equal(idem.begin("d", "key-00000001", print).state, "new");
  assert.equal(Idempotency.validKey("short"), false);
  assert.equal(Idempotency.validKey("a".repeat(129)), false);
  assert.equal(Idempotency.validKey("ok-key_1.2:3"), true);

  assert.equal(rpcClass("normal", "prompt.submit"), "write");
  assert.equal(rpcClass("normal", "session.list"), "read");
  assert.equal(rpcClass("normal", "session.delete"), null);
  assert.equal(rpcClass("admin", "session.delete"), "write");
  assert.equal(rpcClass("admin", "shell.exec"), null);
});

test("config: Hermes must be local, secrets come from the environment", () => {
  assert.equal(isLoopbackHost("127.0.0.1"), true);
  assert.equal(isLoopbackHost("127.9.9.9"), true);
  assert.equal(isLoopbackHost("::1"), true);
  assert.equal(isLoopbackHost("localhost"), true);
  assert.equal(isLoopbackHost("0.0.0.0"), false);
  assert.equal(isLoopbackHost("192.0.2.1"), false);
  assert.equal(isLoopbackHost("hermes.example.org"), false);
  const env = { HERMES_FACADE_STATE_DIR: "state", HERMES_FACADE_UPSTREAM_TOKEN: "t" };
  const config = fromEnv(env);
  assert.equal(config.listenHost, "127.0.0.1", "the facade listens on the loopback unless told otherwise");
  assert.equal(config.listenPort, 8443);
  assert.equal(config.checkExposure, true);
  assert.throws(() => fromEnv({ ...env, HERMES_FACADE_UPSTREAM_HOST: "0.0.0.0" }), /loopback/);
  assert.throws(() => fromEnv({ HERMES_FACADE_STATE_DIR: "state" }), /credential/);
  assert.throws(() => fromEnv({ ...env, HERMES_FACADE_LISTEN_PORT: "99999" }), /LISTEN_PORT/);
  assert.throws(() => fromEnv({ ...env, HERMES_FACADE_LISTEN_PORT: "9119" }), /differ/);
});

test("tls: the pin is stable across a renewal that keeps the key, and changes with a new key", () => {
  const dir = tmp("facade-pki-");
  const first = generatePki({ dir, hosts: ["localhost", "127.0.0.1"] });
  const renewed = generatePki({ dir, hosts: ["localhost", "127.0.0.1"] });
  assert.equal(renewed.pin, first.pin);
  assert.notEqual(renewed.serverCert, first.serverCert);
  const rekeyed = generatePki({ dir, hosts: ["localhost"], reuseKey: false });
  assert.notEqual(rekeyed.pin, first.pin);
  assert.equal(spkiPin(rekeyed.serverCert), rekeyed.pin);
  assert.equal(fs.statSync(path.join(dir, "ca.key")).mode & 0o777, 0o600);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("cli: enroll, list, revoke and exposure check", async () => {
  const dir = tmp("facade-cli-");
  const env = { HERMES_FACADE_STATE_DIR: dir };
  const run = async (...args) => {
    let out = "";
    const stream = new Writable({ write(chunk, _enc, cb) { out += chunk; cb(); } });
    const code = await main(args, env, stream);
    return { code, out };
  };
  const enrolled = await run("enroll", "--role", "admin");
  assert.equal(enrolled.code, 0);
  assert.match(enrolled.out, /^code [A-Z0-9-]{23}\nrole admin\nexpires 2\d{3}-\d\d-\d\dT[\d:.]+Z\n$/);
  const store = new Store({ file: path.join(dir, "state.json") });
  const code = /code (\S+)/.exec(enrolled.out)[1];
  const device = store.redeemEnrollment(code, "box").device;
  assert.match((await run("devices")).out, new RegExp(`${device.id}\\tadmin\\tactive\\tbox`));
  assert.equal((await run("revoke", device.id)).code, 0);
  assert.match((await run("devices")).out, /revoked/);
  assert.equal((await run("revoke", "dev_0000000000000000")).code, 1);
  assert.equal((await run("bogus")).code, 2);
  const init = await run("init-tls");
  assert.match(init.out, /^pin [A-Za-z0-9+/]{43}=/);
  fs.rmSync(dir, { recursive: true, force: true });
});
