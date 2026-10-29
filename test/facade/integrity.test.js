"use strict";

// Fixes for the second independent review of PR-1: upstream ids made by the facade, an
// exposure check that covers every non-loopback address, masking of any configured secret,
// audit of host commands, revocation seen before each relayed event, and a smoke test that
// writes only to a disposable instance.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const { EventEmitter } = require("node:events");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { execFile } = require("node:child_process");
const { Writable } = require("node:stream");
const { main } = require("../../facade/bin/hermes-facade");
const { Audit } = require("../../facade/src/audit");
const { MIN_SECRET_LENGTH } = require("../../facade/src/config");
const { checkExposure, probe, targets } = require("../../facade/src/exposure");
const { outsideAddress, scopedAddress, wildcardAddress } = require("../../facade/testkit/addresses");
const { MARKER_NAME, MARKER_TEXT, assertDisposable } = require("../../facade/testkit/disposable");
const { startFakeHermes } = require("../../facade/testkit/fake-hermes");
const { createFacade } = require("../../facade/src/server");
const { startStack } = require("../../facade/testkit/stack");

const T0 = Date.parse("2026-10-29T12:00:00Z");
const KEY = "collision-key-0001";
const WRITE = { session_id: "s1", text: "hello", idempotency_key: KEY };

function tmp(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

function frame(id, method, params) {
  return JSON.stringify({ jsonrpc: "2.0", ...(id === undefined ? {} : { id }), method, params });
}

async function run(env, ...args) {
  let out = "";
  const stream = new Writable({ write(chunk, _enc, cb) { out += chunk; cb(); } });
  const code = await main(args, env, stream);
  return { code, out };
}

test("ids: a read that reuses the id of a running write cannot complete that write", async (t) => {
  const stack = await startStack({ delayMs: 300 });
  t.after(() => stack.close());
  const device = await stack.enroll("normal");
  const socket = await stack.ws({ token: device.token });

  socket.sendRaw(frame("x1", "prompt.submit", WRITE));
  socket.sendRaw(frame("x1", "ping", {}));
  const pong = await socket.wait((m) => m.id === "x1" && m.result && m.result.pong === true);
  assert.ok(pong, "the read gets its own answer under its own id");
  const submitted = await socket.wait((m) => m.id === "x1" && m.result && m.result.status === "streaming");
  assert.ok(submitted, "the write gets its own answer under its own id");

  const again = await socket.call("prompt.submit", WRITE);
  assert.equal(again.idempotent_replay, true);
  assert.equal(again.result.status, "streaming", "the kept result is the write's, not the read's");
  assert.equal(stack.hermes.calls["prompt.submit"], 1);

  const ids = stack.hermes.seen.map((s) => s.id);
  assert.ok(ids.every((id) => typeof id === "string" && id.startsWith("fb-")), "Hermes only sees ids the facade made");
  assert.ok(!ids.includes("x1"), "no device id reaches Hermes");
  assert.equal(new Set(ids).size, ids.length, "upstream ids are unique");
});

test("ids: a failing read that reuses the id of a running write does not free its key", async (t) => {
  const stack = await startStack({ delayMs: 300 });
  t.after(() => stack.close());
  const device = await stack.enroll("normal");
  const socket = await stack.ws({ token: device.token });

  socket.sendRaw(frame("x1", "prompt.submit", WRITE));
  socket.sendRaw(frame("x1", "session.list", { bogus: true }));
  const failed = await socket.wait((m) => m.id === "x1" && m.error);
  assert.equal(failed.error.code, 4000, "the read fails on its own");

  const retry = await socket.call("prompt.submit", WRITE, "x2");
  assert.equal(retry.idempotent_replay, true, "the retry waits for the first call and replays it");
  assert.equal(retry.result.status, "streaming");
  assert.equal(stack.hermes.calls["prompt.submit"], 1, "Hermes ran the write once");
});

test("ids: notifications, null ids and odd ids", async (t) => {
  const stack = await startStack();
  t.after(() => stack.close());
  const device = await stack.enroll("normal");
  const socket = await stack.ws({ token: device.token });

  socket.sendRaw(frame(undefined, "ping", {}));
  socket.sendRaw(frame(null, "ping", {}));
  const nulled = await socket.wait((m) => m.id === null && m.result && m.result.pong === true);
  assert.ok(nulled, "a null id comes back as null");
  assert.equal(stack.hermes.seen.filter((s) => s.method === "ping" && s.id === undefined).length, 1, "a notification stays a notification");

  socket.sendRaw(JSON.stringify({ jsonrpc: "2.0", id: { nested: 1 }, method: "ping" }));
  const odd = await socket.wait((m) => m.error && m.error.code === -32600);
  assert.ok(odd, "an object id is refused");
  assert.equal(stack.hermes.calls.ping, 2);
});

test("ids: a response nobody asked for is dropped", async (t) => {
  const stack = await startStack();
  t.after(() => stack.close());
  const device = await stack.enroll("normal");
  const socket = await stack.ws({ token: device.token });
  await socket.call("ping");

  stack.hermes.emitRaw(JSON.stringify({ jsonrpc: "2.0", id: "x1", result: { orphan: true } }));
  stack.hermes.emitRaw(JSON.stringify({ jsonrpc: "2.0", id: "fb-guess-1", result: { orphan: true } }));
  const next = await socket.call("ping", {}, "x1");
  assert.equal(next.result.pong, true);
  await assert.rejects(socket.wait((m) => m.result && m.result.orphan, 300), /timeout/);
});

test("exposure: every non-loopback address is probed, a scoped one with its zone", () => {
  const found = targets({
    lo: [
      { address: "loopback-v4", family: "IPv4", internal: true },
      { address: "loopback-v6", family: "IPv6", internal: true, scopeid: 0 },
    ],
    eth0: [
      { address: "routable-v4", family: "IPv4", internal: false },
      { address: "scoped-v6", family: "IPv6", internal: false, scopeid: 2 },
      { address: "global-v6", family: "IPv6", internal: false, scopeid: 0 },
    ],
    tun0: [{ address: "other-v4", family: "IPv4", internal: false }],
  });
  assert.deepEqual(found, ["routable-v4", "scoped-v6%eth0", "global-v6", "other-v4"]);
});

test("exposure: a listener reachable on a scoped address alone fails the check", async () => {
  const interfaces = {
    lo: [{ address: "loopback-v4", family: "IPv4", internal: true }],
    eth0: [
      { address: "routable-v4", family: "IPv4", internal: false },
      { address: "scoped-v6", family: "IPv6", internal: false, scopeid: 2 },
    ],
  };
  const seen = [];
  const only = (open) => async (target) => {
    seen.push(target);
    return target === open ? "open" : "closed";
  };
  const exposed = await checkExposure({ host: "localhost", port: 1, interfaces, connect: only("scoped-v6%eth0") });
  assert.equal(exposed.ok, false);
  assert.equal(exposed.exposedOn, 1);
  assert.equal(exposed.interfacesChecked, 2, "the scoped address is counted, not skipped");
  assert.deepEqual(seen.sort(), ["routable-v4", "scoped-v6%eth0"]);

  const quiet = await checkExposure({ host: "localhost", port: 1, interfaces, connect: only("nothing") });
  assert.deepEqual({ ok: quiet.ok, exposedOn: quiet.exposedOn, unverified: quiet.unverified }, { ok: true, exposedOn: 0, unverified: 0 });

  const unsure = await checkExposure({ host: "localhost", port: 1, interfaces, connect: async (target) => (target === "routable-v4" ? "unknown" : "closed") });
  assert.equal(unsure.ok, false, "a probe that proves nothing fails closed");
  assert.equal(unsure.unverified, 1);
});

// A socket that does what the test says: stay silent, fail with a code, or connect.
function scripted(behaviour) {
  return () => {
    const socket = new EventEmitter();
    let timer = null;
    socket.destroyed = false;
    socket.destroy = () => {
      socket.destroyed = true;
      clearTimeout(timer);
    };
    socket.setTimeout = (ms, onTimeout) => {
      if (behaviour === "silent") timer = setTimeout(onTimeout, ms);
    };
    setImmediate(() => {
      if (behaviour === "connect") socket.emit("connect");
      else if (behaviour !== "silent") socket.emit("error", Object.assign(new Error("probe"), { code: behaviour }));
    });
    return socket;
  };
}

test("exposure: the real probe keeps only a refusal as proof of closure", async () => {
  const outcome = (behaviour) => probe("probe-target", 1, 30, scripted(behaviour));
  assert.equal(await outcome("connect"), "open");
  assert.equal(await outcome("ECONNREFUSED"), "closed");
  assert.equal(await outcome("silent"), "unknown", "a timeout proves nothing");
  for (const code of ["ETIMEDOUT", "ECONNRESET", "EHOSTUNREACH", "ENETUNREACH", "EADDRNOTAVAIL", "ENETDOWN", "EACCES", "EINVAL", "EPERM", "ENOTFOUND", undefined]) {
    assert.equal(await outcome(code), "unknown", `error ${code} is ambiguous`);
  }
  const dial = () => {
    throw new Error("dial failed");
  };
  assert.equal(await probe("probe-target", 1, 30, dial), "unknown");
});

test("exposure: a probe that times out fails the check, through the real probe", async () => {
  const interfaces = { eth0: [{ address: "routable-v4", family: "IPv4", internal: false }] };
  const silent = await checkExposure({ host: "localhost", port: 1, interfaces, timeoutMs: 30, dial: scripted("silent") });
  assert.deepEqual({ ok: silent.ok, interfacesChecked: silent.interfacesChecked, exposedOn: silent.exposedOn, unverified: silent.unverified }, { ok: false, interfacesChecked: 1, exposedOn: 0, unverified: 1 });

  const refused = await checkExposure({ host: "localhost", port: 1, interfaces, timeoutMs: 30, dial: scripted("ECONNREFUSED") });
  assert.equal(refused.ok, true, "a refusal is a proof of closure");
  const reset = await checkExposure({ host: "localhost", port: 1, interfaces, timeoutMs: 30, dial: scripted("ECONNRESET") });
  assert.equal(reset.ok, false);
});

test("exposure: real sockets, open and refused are proven, an unresolvable target is not", async () => {
  const server = net.createServer((socket) => socket.end());
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  assert.equal(await probe("127.0.0.1", port, 1000), "open");
  await new Promise((resolve) => server.close(resolve));
  assert.equal(await probe("127.0.0.1", port, 1000), "closed", "nothing listens any more");
  assert.equal(await probe("unresolvable-name", port, 1000), "unknown", "a name that does not resolve proves nothing");
});

test("exposure: a wildcard or non-loopback Hermes host fails whatever the interfaces say", async () => {
  const closed = async () => "closed";
  for (const host of [await wildcardAddress(), "", "not-a-loopback", outsideAddress(), scopedAddress()].filter((h) => h !== null)) {
    const result = await checkExposure({ host, port: 1, interfaces: {}, connect: closed });
    assert.equal(result.ok, false, `host ${host === "" ? "(empty)" : "(a non-loopback value)"}`);
    assert.equal(result.loopbackHost, false);
  }
  const local = await checkExposure({ host: "127.0.0.1", port: 1, interfaces: {}, connect: closed });
  assert.equal(local.ok, true);

  const env = { HERMES_FACADE_UPSTREAM_PORT: "1", HERMES_FACADE_UPSTREAM_HOST: await wildcardAddress() };
  assert.equal((await run(env, "check-exposure")).code, 1, "the host command refuses a wildcard host");
});

test("exposure: a real listener on a scoped address is found", async (t) => {
  const scoped = scopedAddress();
  if (!scoped) return t.skip("no scoped address");
  const server = http.createServer((_req, res) => res.end("x"));
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen({ port: 0, host: scoped }, resolve);
  });
  t.after(() => server.close());
  const result = await checkExposure({ host: "localhost", port: server.address().port });
  assert.equal(result.ok, false);
  assert.ok(result.exposedOn >= 1);
  return undefined;
});

test("exposure: a real wildcard listener is found, a loopback one is not", async (t) => {
  const wild = http.createServer((_req, res) => res.end("x"));
  await new Promise((resolve) => wild.listen(0, resolve));
  t.after(() => wild.close());
  const quiet = http.createServer((_req, res) => res.end("x"));
  await new Promise((resolve) => quiet.listen(0, "127.0.0.1", resolve));
  t.after(() => quiet.close());

  const checked = await checkExposure({ host: "localhost", port: quiet.address().port });
  assert.equal(checked.ok, true, "a loopback listener is not exposed");
  if (!outsideAddress() && !scopedAddress()) return;
  const result = await checkExposure({ host: "localhost", port: wild.address().port });
  assert.equal(result.ok, false);
  assert.ok(result.exposedOn >= 1);
});

test("audit: any configured secret is masked, whatever its length, through the real audit route", async (t) => {
  const token = "k".repeat(MIN_SECRET_LENGTH - 6) + "-1234-";
  assert.equal(token.length, MIN_SECRET_LENGTH);
  const stack = await startStack({ upstreamToken: token });
  t.after(() => stack.close());
  const admin = await stack.enroll("admin", "admin device");

  const read = await stack.call({ path: `/api/sessions/${token}/messages`, token: admin.token });
  assert.equal(read.status, 200, "an allowed read route carries the value in its path");
  const socket = await stack.ws({ token: admin.token });
  await socket.call(token, {});
  socket.close();
  await stack.call({ path: "/facade/whoami", token: admin.token, headers: { "x-probe": token } });

  const viaApi = (await stack.call({ path: "/facade/audit?limit=500", token: admin.token })).body;
  const file = fs.readFileSync(stack.config.auditFile, "utf8");
  assert.ok(!viaApi.includes(token), "the audit route never returns the configured secret");
  assert.ok(!file.includes(token), "the audit file never holds the configured secret");
  assert.match(viaApi, /\/api\/sessions\/\[redacted\]\/messages/);
});

test("audit: secrets of any length are masked, with their encoded form", () => {
  const audit = new Audit({ now: () => T0, secrets: ["Q", "pw/with space", ""] });
  const entry = audit.record("probe", { one: "xQy", two: "x pw/with space y", three: `x ${encodeURIComponent("pw/with space")} y`, four: "plain" });
  assert.equal(entry.one, "x[redacted]y", "a one-character secret is masked");
  assert.equal(entry.two, "x [redacted] y");
  assert.equal(entry.three, "x [redacted] y");
  assert.equal(entry.four, "plain");
});

test("config: a credential shorter than the minimum is refused when the facade is built", async (t) => {
  const stack = await startStack();
  t.after(() => stack.close());
  assert.throws(() => createFacade({ ...stack.config, upstreamToken: "short" }, { tls: { key: "", cert: "" } }), /at least 16 characters/);
});

test("audit: host enrollments and revocations are recorded and shown by the audit route", async (t) => {
  const stack = await startStack();
  t.after(() => stack.close());
  const admin = await stack.enroll("admin", "admin device");
  const other = await stack.enroll("normal", "other device");
  const env = { HERMES_FACADE_STATE_DIR: stack.dir };

  const enrolled = await run(env, "enroll", "--role", "admin");
  const code = /code (\S+)/.exec(enrolled.out)[1];
  assert.equal((await run(env, "revoke", other.device_id)).code, 0);
  assert.equal((await run(env, "revoke", "dev_0000000000000000")).code, 1);
  assert.equal((await run(env, "revoke", "not-a-device-but-secret-looking-0123456789abcdef0123456789")).code, 1);

  const file = fs.readFileSync(stack.config.auditFile, "utf8");
  assert.ok(!file.includes(code) && !file.includes(code.replace(/-/g, "")), "the code itself is not audited");
  const events = file.trim().split("\n").map((l) => JSON.parse(l));
  const created = events.find((e) => e.event === "enrollment_created" && e.device === "host");
  assert.equal(created.role, "admin");
  assert.ok(events.some((e) => e.event === "revoke" && e.device === "host" && e.target === other.device_id));
  const denied = events.filter((e) => e.event === "revoke_denied");
  assert.equal(denied.length, 2);
  assert.ok(denied.every((e) => e.reason === "unknown_device" && e.target === undefined), "the raw argument is not logged");

  const viaApi = (await stack.call({ path: "/facade/audit?limit=500", token: admin.token })).json.events;
  assert.ok(viaApi.some((e) => e.event === "enrollment_created" && e.device === "host"), "the route shows what the host commands did");
  assert.ok(viaApi.some((e) => e.event === "revoke" && e.target === other.device_id));
});

test("revocation: a host-side revocation stops events before the next sweep", async (t) => {
  const stack = await startStack({ sweepMs: 3_600_000 });
  t.after(() => stack.close());
  const device = await stack.enroll("normal");
  const socket = await stack.ws({ token: device.token });
  await socket.call("ping");

  const revoked = await run({ HERMES_FACADE_STATE_DIR: stack.dir }, "revoke", device.device_id);
  assert.equal(revoked.code, 0);
  stack.hermes.emit({ type: "message.delta", payload: "after revocation" });

  const leaked = await socket.wait((m) => m.method === "event" && m.params.type === "message.delta", 1000);
  assert.equal(leaked, null, "no event reached the revoked device, the socket closed instead");
  assert.equal(await socket.closed(), 1008);
});

test("smoke guard: writes need a marked disposable instance that reports the marked directory", async (t) => {
  const home = tmp("facade-disposable-");
  const other = tmp("facade-other-");
  const fake = await startFakeHermes({ home });
  t.after(async () => {
    await fake.close();
    fs.rmSync(home, { recursive: true, force: true });
    fs.rmSync(other, { recursive: true, force: true });
  });
  const base = { port: fake.port, token: fake.token };

  await assert.rejects(assertDisposable({ ...base, home: undefined }), /HERMES_TEST_HOME is required/);
  await assert.rejects(assertDisposable({ ...base, home }), /marker|missing/i, "no marker, no write");
  fs.writeFileSync(path.join(home, MARKER_NAME), "something else\n");
  await assert.rejects(assertDisposable({ ...base, home }), /expected text/);
  fs.writeFileSync(path.join(home, MARKER_NAME), MARKER_TEXT);
  assert.equal(await assertDisposable({ ...base, home }), true);

  fs.writeFileSync(path.join(other, MARKER_NAME), MARKER_TEXT);
  await assert.rejects(assertDisposable({ ...base, home: other }), /does not use the marked data directory/, "a marked directory that the instance does not run on is refused");
  await assert.rejects(assertDisposable({ ...base, home, status: async () => ({ version: "x" }) }), /does not report its data directory/);
  await assert.rejects(assertDisposable({ ...base, home, status: async () => ({ hermes_home: path.join(home, "missing") }) }), /does not exist here/);
  await assert.rejects(assertDisposable({ ...base, home, status: async () => { throw new Error("down"); } }), /down/);
});

test("smoke guard: the smoke script refuses before it writes anything", async (t) => {
  const home = tmp("facade-disposable-");
  const fake = await startFakeHermes({ home });
  t.after(async () => {
    await fake.close();
    fs.rmSync(home, { recursive: true, force: true });
  });
  const script = path.join(__dirname, "../../facade/testkit/live-smoke.js");
  const env = { ...process.env, HERMES_TEST_PORT: String(fake.port), HERMES_TEST_TOKEN: fake.token, HERMES_TEST_HOME: home };
  const result = await new Promise((resolve) => {
    execFile(process.execPath, [script], { env }, (error, stdout, stderr) => resolve({ code: error ? error.code : 0, stdout, stderr }));
  });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /refusing to write/);
  assert.ok(!/PASS/.test(result.stdout), "no check ran");
  assert.equal(Object.keys(fake.calls).length, 0, "no JSON-RPC call reached the instance");
  assert.ok(fake.requests.every((r) => r.method === "GET" && r.url === "/api/status"), "only the read-only status probe was sent");
});
