"use strict";

// Fixes for the first independent review of PR-1: malformed upgrade targets, a durable
// idempotency journal, audit masking by value, and the device limit.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const tls = require("node:tls");
const { Audit } = require("../../facade/src/audit");
const { Idempotency, fingerprint } = require("../../facade/src/idempotency");
const { Store } = require("../../facade/src/store");
const { connectWs, request } = require("../../facade/testkit/client");
const { startChild } = require("../../facade/testkit/child");
const { startFakeHermes } = require("../../facade/testkit/fake-hermes");
const { pki, startStack } = require("../../facade/testkit/stack");

const T0 = Date.parse("2026-10-29T12:00:00Z");
const WRITE = { session_id: "s1", text: "hello" };

function tmp(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

// Values with the shape of real credentials, built at run time.
function secretShapes(upstream) {
  const jwt = ["eyJhbGciOiJIUzI1NiJ9", Buffer.from(JSON.stringify({ sub: "device" })).toString("base64url"), "c2lnbmF0dXJlMTIzNDU2"].join(".");
  return {
    jwt,
    sk: `sk-proj-${"A1b2C3d4".repeat(5)}`,
    github: `ghp_${"x9Y8".repeat(9)}`,
    aws: `AKIA${"ABCDEFGHIJKLMNOP"}`,
    device: `hbf_${"Z".repeat(43)}`,
    code: "ABCDE-FGHJK-MNPQR-STVWX",
    bearer: "Bearer abc123def456ghi789",
    hex: "0123456789abcdef".repeat(3),
    long: "q".repeat(48),
    upstream,
  };
}

function rawTls(port, text) {
  const pin = pki();
  return new Promise((resolve) => {
    const socket = tls.connect({ host: "127.0.0.1", port, ca: pin.caCert, servername: "localhost" }, () => socket.write(text));
    const chunks = [];
    socket.on("data", (c) => chunks.push(c));
    socket.on("close", () => resolve(Buffer.concat(chunks).toString("latin1")));
    socket.on("error", () => resolve(Buffer.concat(chunks).toString("latin1")));
    setTimeout(() => socket.destroy(), 2000).unref();
  });
}

test("a malformed request target is refused and the process stays up", async (t) => {
  assert.throws(() => new URL("//[", "https://localhost"), "the target used below is one that URL parsing rejects");
  const stack = await startStack();
  t.after(() => stack.close());
  const device = await stack.enroll("normal");

  const upgrade = await rawTls(
    stack.port,
    "GET //[ HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
  );
  assert.match(upgrade, /^HTTP\/1\.1 400 /, "a controlled refusal");
  const plain = await rawTls(stack.port, "GET //[ HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
  assert.match(plain, /^HTTP\/1\.1 400 /);
  assert.doesNotMatch(upgrade + plain, /Error|at \w+/, "no stack trace on the wire");

  const alive = await stack.call({ path: "/facade/whoami", token: device.token });
  assert.equal(alive.status, 200, "the facade still answers");
  const socket = await stack.ws({ token: device.token });
  assert.deepEqual((await socket.call("ping")).result, { pong: true });
  socket.close();
});

test("idempotency journal: a restart after a write replays it", async (t) => {
  const stack = await startStack();
  t.after(() => stack.close());
  const device = await stack.enroll("normal");
  const first = await (await stack.ws({ token: device.token })).call("prompt.submit", { ...WRITE, idempotency_key: "key-durable-1" });
  assert.equal(first.result.status, "streaming");
  assert.equal(stack.hermes.calls["prompt.submit"], 1);

  await stack.restart();
  const socket = await stack.ws({ token: device.token });
  const again = await socket.call("prompt.submit", { ...WRITE, idempotency_key: "key-durable-1" });
  assert.equal(again.idempotent_replay, true);
  assert.deepEqual(again.result, first.result);
  assert.equal(stack.hermes.calls["prompt.submit"], 1, "Hermes ran the write once across the restart");
  const clash = await socket.call("prompt.submit", { ...WRITE, text: "other", idempotency_key: "key-durable-1" });
  assert.equal(clash.error.code, 4009, "the fingerprint survives too");
  socket.close();
  assert.equal(fs.statSync(stack.config.idempotencyFile).mode & 0o777, 0o600);
});

test("idempotency journal: a restart during a write never runs it again", async (t) => {
  const stack = await startStack({ delayMs: 600 });
  t.after(() => stack.close());
  const device = await stack.enroll("normal");
  const socket = await stack.ws({ token: device.token });
  const inFlight = socket.call("prompt.submit", { ...WRITE, idempotency_key: "key-during-01" }, "p1").catch(() => null);
  await new Promise((resolve) => setTimeout(resolve, 100));
  await stack.restart();
  await inFlight;
  const retry = await stack.ws({ token: device.token });
  const answer = await retry.call("prompt.submit", { ...WRITE, idempotency_key: "key-during-01" });
  assert.equal(answer.error.code, 4010);
  assert.equal(stack.hermes.calls["prompt.submit"], 1);
  retry.close();
});

test("idempotency journal: a crash (SIGKILL) during and after a write", async (t) => {
  const dir = tmp("facade-crash-");
  const hermes = await startFakeHermes({ delayMs: 700 });
  t.after(async () => {
    await hermes.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  const store = new Store({ file: path.join(dir, "state.json") });
  const trust = { ca: pki().caCert, pin: pki().pin };
  let child = await startChild({ dir, hermes });
  t.after(() => child.kill());
  const enroll = async (port) => {
    const { code } = store.createEnrollment({ role: "normal" });
    return (await request({ port, ...trust, method: "POST", path: "/facade/enroll", body: { code, name: "crash test" } })).json;
  };
  const device = await enroll(child.port);

  const done = await connectWs({ port: child.port, token: device.token, ...trust });
  const finished = await done.call("prompt.submit", { ...WRITE, idempotency_key: "key-after-001" });
  assert.equal(finished.result.status, "streaming");

  const running = await connectWs({ port: child.port, token: device.token, ...trust });
  running.call("prompt.submit", { ...WRITE, idempotency_key: "key-crash-001" }, "p1").catch(() => null);
  await new Promise((resolve) => setTimeout(resolve, 150));
  await child.kill();
  assert.equal(hermes.calls["prompt.submit"], 2);

  child = await startChild({ dir, hermes });
  t.after(() => child.kill());
  const socket = await connectWs({ port: child.port, token: device.token, ...trust });
  const replayed = await socket.call("prompt.submit", { ...WRITE, idempotency_key: "key-after-001" });
  assert.equal(replayed.idempotent_replay, true, "a finished write is replayed after a crash");
  assert.deepEqual(replayed.result, finished.result);
  const lost = await socket.call("prompt.submit", { ...WRITE, idempotency_key: "key-crash-001" });
  assert.equal(lost.error.code, 4010, "a write that was running is never run again");
  assert.equal(hermes.calls["prompt.submit"], 2, "Hermes saw no third call");
  socket.close();
});

test("idempotency journal: unit behaviour of the file", () => {
  const dir = tmp("facade-journal-");
  const file = path.join(dir, "idem.jsonl");
  let now = T0;
  const make = () => new Idempotency({ now: () => now, ttlMs: 1000, file });
  const print = fingerprint("prompt.submit", { a: 1 });

  let idem = make();
  assert.equal(idem.begin("d", "key-00000001", print).state, "new");
  idem.complete("d", "key-00000001", { ok: 1 });
  assert.equal(idem.begin("d", "key-00000002", print).state, "new");
  assert.equal(idem.begin("d", "key-00000003", print).state, "new");
  idem.release("d", "key-00000003");
  assert.equal(idem.begin("d", "key-00000004", print).state, "new");
  idem.markUnknown("d", "key-00000004");
  idem.close();

  idem = make();
  assert.deepEqual(idem.begin("d", "key-00000001", print), { state: "replay", result: { ok: 1 } });
  assert.equal(idem.begin("d", "key-00000002", print).state, "unknown", "a write that was running becomes unknown");
  assert.equal(idem.begin("d", "key-00000003", print).state, "new", "a released key is free");
  assert.equal(idem.begin("d", "key-00000004", print).state, "unknown");
  assert.equal(idem.begin("d", "key-00000001", "other").state, "conflict");
  idem.close();

  fs.appendFileSync(file, '{"op":"done","scope":"d","key":"key-000000');
  idem = make();
  assert.equal(idem.begin("d", "key-00000001", print).state, "replay", "a torn last line is ignored");
  idem.close();

  now += 1000;
  idem = make();
  assert.equal(idem.begin("d", "key-00000001", print).state, "new", "entries expire across a restart");
  idem.close();
  const text = fs.readFileSync(file, "utf8");
  assert.ok(!text.includes("key-00000002"), "compaction drops the dead entries");
  assert.deepEqual(fs.readdirSync(dir), ["idem.jsonl"], "no temporary file is left");
  fs.rmSync(dir, { recursive: true, force: true });
});

test("idempotency journal: a result too large to keep makes the key unknown, not lost", () => {
  const dir = tmp("facade-journal-big-");
  const idem = new Idempotency({ file: path.join(dir, "j.jsonl") });
  idem.begin("d", "key-big-0001", "p");
  idem.complete("d", "key-big-0001", { blob: "x".repeat(70_000) });
  assert.equal(idem.begin("d", "key-big-0001", "p").state, "unknown");
  idem.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

test("idempotency journal: an unwritable journal stops the write before Hermes", async (t) => {
  const stack = await startStack();
  t.after(() => stack.close());
  const device = await stack.enroll("normal");
  fs.closeSync(stack.facade.idempotency.fd);
  const socket = await stack.ws({ token: device.token });
  const refused = await socket.call("prompt.submit", { ...WRITE, idempotency_key: "key-nojournal" });
  assert.equal(refused.error.code, 4012);
  assert.equal(stack.hermes.calls["prompt.submit"], undefined);
  socket.close();
  stack.facade.idempotency.fd = null;
});

test("audit: nothing a device controls is logged raw, secret shapes are masked by value", async (t) => {
  let now = T0;
  const stack = await startStack({ now: () => now });
  t.after(() => stack.close());
  const admin = await stack.enroll("admin", "admin device");
  const secrets = secretShapes(stack.hermes.token);
  const shapes = Object.entries(secrets);

  const socket = await stack.ws({ token: admin.token });
  for (const [, value] of shapes) {
    const reply = await socket.call(value, {});
    assert.equal(reply.error.code, 4003);
  }
  socket.close();

  for (const [label, value] of shapes) {
    if (/[^A-Za-z0-9._ '()-]/.test(value) || value.length > 64) continue;
    now += 301_000;
    const { code } = stack.facade.store.createEnrollment({ role: "normal" });
    const res = await stack.call({ method: "POST", path: "/facade/enroll", body: { code, name: value } });
    assert.equal(res.status, 201, `a device named like a ${label}`);
  }

  for (const [, value] of shapes) {
    await stack.call({ path: `/api/${encodeURIComponent(value)}`, token: admin.token });
    await stack.call({ path: `/${encodeURIComponent(value)}`, token: admin.token });
    await stack.call({ path: `/api/sessions/${encodeURIComponent(value).replace(/%/g, "")}`, token: admin.token });
    await stack.call({ method: "GET", path: "/facade/whoami", token: admin.token, headers: { "x-probe": value } });
  }
  await stack.call({ method: "PROPFIND", path: "/facade/whoami", token: admin.token });

  const fileText = fs.readFileSync(stack.config.auditFile, "utf8");
  const viaApi = (await stack.call({ path: "/facade/audit?limit=500", token: admin.token })).body;
  for (const [label, value] of shapes) {
    const bare = value.replace(/^Bearer /, "");
    for (const [where, text] of [["the audit file", fileText], ["the audit route", viaApi]]) {
      assert.ok(!text.includes(bare), `a ${label} shape reached ${where}`);
    }
  }
  const denied = fileText.split("\n").filter((l) => l.includes('"rpc_denied"')).map((l) => JSON.parse(l));
  assert.equal(denied.length, shapes.length);
  for (const entry of denied) {
    assert.equal(entry.method, undefined, "the raw method is not a field");
    assert.match(entry.method_digest, /^[0-9a-f]{12}$/);
  }
  const enrolls = fileText.split("\n").filter((l) => l.includes('"enroll"')).map((l) => JSON.parse(l));
  assert.ok(enrolls.length > 0);
  for (const entry of enrolls) assert.equal(entry.name, undefined, "the device name is not logged");
  assert.ok(fileText.includes('"method":"other"'), "an odd HTTP method is logged as other");
  assert.ok(fileText.includes('"path":"[unlisted]"'));
});

test("audit: unit masking by value, by field name, and for known secrets", () => {
  const known = "short-upstream-pw";
  const audit = new Audit({ now: () => T0, secrets: [known, "tiny"] });
  const s = secretShapes(known);
  const entry = audit.record("probe", {
    a: `prefix ${s.jwt} suffix`,
    b: s.sk,
    c: `${s.github} and ${s.aws}`,
    d: s.device,
    e: s.code,
    f: s.bearer,
    g: s.hex,
    h: s.long,
    i: `contains ${known} inside tiny`,
    j: { nested: s.sk },
    k: "line\nbreak\u0000",
    l: "x".repeat(500),
    m: 7,
    n: null,
    token: "anything",
    safe: "dev_0123456789abcdef",
  });
  for (const key of ["a", "b", "c", "d", "e", "f", "g", "h", "j"]) assert.match(entry[key], /\[redacted\]/, key);
  assert.ok(!entry.i.includes(known));
  assert.ok(!entry.i.includes("tiny"), "a configured secret is masked whatever its length");
  assert.equal(entry.k, "line break ");
  assert.ok(entry.l.length <= 203);
  assert.equal(entry.m, 7);
  assert.equal(entry.n, null);
  assert.equal(entry.token, "[redacted]");
  assert.equal(entry.safe, "dev_0123456789abcdef");
});

test("device limit: revoked devices do not count", () => {
  const dir = tmp("facade-limit-");
  const store = new Store({ file: path.join(dir, "state.json"), now: () => T0, maxDevices: 3 });
  const enroll = () => store.redeemEnrollment(store.createEnrollment({ role: "normal" }).code, "d");
  const live = [enroll(), enroll(), enroll()];
  assert.ok(live.every((r) => r.ok));
  assert.deepEqual({ ok: false, reason: "device_limit" }, enroll(), "three live devices fill the limit");
  store.revoke(live[0].device.id);
  const replacement = enroll();
  assert.equal(replacement.ok, true, "a revoked device frees its place");
  for (let i = 0; i < 6; i++) {
    store.revoke(store.list().find((d) => !d.revokedAt).id);
    assert.equal(enroll().ok, true, `replacement ${i + 1}`);
  }
  assert.equal(store.list().filter((d) => !d.revokedAt).length, 3);
  assert.ok(store.list().length > 3, "revoked devices stay on record");
  fs.rmSync(dir, { recursive: true, force: true });
});
