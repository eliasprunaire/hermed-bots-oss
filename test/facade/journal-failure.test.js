"use strict";

// A journal that cannot record the end of a call (EIO) must never leave its key pending: the key
// answers "unknown" at once, the waiters are woken, and the call is not run a second time.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { Idempotency, fingerprint } = require("../../facade/src/idempotency");
const { startStack } = require("../../facade/testkit/stack");

const PRINT = fingerprint("prompt.submit", { a: 1 });
const key = (n) => `key-${String(n).padStart(8, "0")}`;
const eio = () => Object.assign(new Error("EIO: i/o error"), { code: "EIO" });
const settled = (promise) => Promise.race([promise, new Promise((resolve) => setTimeout(() => resolve("still pending"), 500))]);

function journal(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "facade-journal-fail-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "j.jsonl");
  return { file, make: () => new Idempotency({ file }) };
}

function failing(idem, ops) {
  const real = idem.journal.bind(idem);
  idem.journal = (record) => {
    if (ops.includes(record.op)) throw eio();
    return real(record);
  };
}

for (const [op, finish] of [
  ["done", (idem, k) => idem.complete("d", k, { ok: 1 })],
  ["release", (idem, k) => idem.release("d", k)],
  ["unknown", (idem, k) => idem.markUnknown("d", k)],
]) {
  test(`journal failure on ${op}: the key leaves pending, the waiters are woken, the call is not run again`, async (t) => {
    const { file, make } = journal(t);
    let idem = make();
    assert.equal(idem.begin("d", key(1), PRINT).state, "new");
    const waiting = idem.begin("d", key(1), PRINT);
    assert.equal(waiting.state, "pending");

    failing(idem, [op]);
    assert.throws(() => finish(idem, key(1)), /EIO/, "the caller still hears of the failure");

    assert.deepEqual(await settled(waiting.wait), { state: "unknown" }, "the waiter is woken");
    assert.equal(idem.begin("d", key(1), PRINT).state, "unknown", "the key is no longer pending");
    idem.close();

    idem = make();
    assert.equal(idem.begin("d", key(1), PRINT).state, "unknown", "a restart agrees");
    idem.close();
    assert.ok(fs.readFileSync(file, "utf8").includes(key(1)));
  });
}

test("journal failure: other keys keep working and a later record starts on its own line", async (t) => {
  const { file, make } = journal(t);
  let idem = make();
  idem.begin("d", key(1), PRINT);
  failing(idem, ["done"]);
  assert.throws(() => idem.complete("d", key(1), { ok: 1 }), /EIO/);
  idem.journal = Idempotency.prototype.journal.bind(idem);
  assert.equal(idem.begin("d", key(2), PRINT).state, "new");
  idem.complete("d", key(2), { ok: 2 });
  idem.close();
  idem = make();
  assert.equal(idem.begin("d", key(1), PRINT).state, "unknown");
  assert.deepEqual(idem.begin("d", key(2), PRINT), { state: "replay", result: { ok: 2 } });
  idem.close();
  assert.ok(file);
});

const WRITE = { session_id: "s1", text: "hello", idempotency_key: "eio-key-00000001" };

for (const [label, params, expected] of [
  ["done", WRITE, "streaming"],
  ["release", { ...WRITE, extra: true }, null],
]) {
  test(`through the facade: an EIO on ${label} does not leave the key pending after a reconnect`, async (t) => {
    const stack = await startStack({ delayMs: 300 });
    t.after(() => stack.close());
    const device = await stack.enroll("normal");
    const socket = await stack.ws({ token: device.token });

    failing(stack.facade.idempotency, ["done", "release"]);
    socket.sendRaw(JSON.stringify({ jsonrpc: "2.0", id: "w1", method: "prompt.submit", params }));
    await new Promise((resolve) => setTimeout(resolve, 50));
    socket.sendRaw(JSON.stringify({ jsonrpc: "2.0", id: "w2", method: "prompt.submit", params }));

    const first = await socket.wait((m) => m.id === "w1");
    if (expected) assert.equal(first.result.status, expected, "the first caller still gets Hermes' answer");
    else assert.ok(first.error, "the first caller gets Hermes' error");
    const waiter = await socket.wait((m) => m.id === "w2");
    assert.equal(waiter.error && waiter.error.code, 4010, "the caller that was waiting is answered, not left hanging");

    const again = await stack.ws({ token: device.token });
    const retry = await Promise.race([again.call("prompt.submit", params, "w3"), new Promise((resolve) => setTimeout(() => resolve("still pending"), 2000))]);
    assert.equal(retry.error && retry.error.code, 4010, "after a reconnect the same key answers unknown");
    assert.equal(stack.hermes.calls["prompt.submit"], 1, "Hermes ran the request once");
    const events = stack.facade.audit.recent(200).filter((e) => e.event === "journal_error");
    assert.ok(events.length >= 1, "the failure is audited");
  });
}
