"use strict";

// Fixes for the third independent review of PR-1: a journal compaction that ran before the
// change it belongs to, and WebSocket continuation frames with no payload that were never
// counted.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const { EventEmitter } = require("node:events");
const os = require("node:os");
const path = require("node:path");
const { MAX_WS_FRAGMENTS } = require("../../facade/src/config");
const { Idempotency, fingerprint } = require("../../facade/src/idempotency");
const { WebSocketPeer, encodeFrame } = require("../../facade/src/websocket");
const { startStack } = require("../../facade/testkit/stack");

const PRINT = fingerprint("prompt.submit", { a: 1 });
const THRESHOLD = 3;

function journal(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "facade-compact-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "j.jsonl");
  return { dir, file, make: () => new Idempotency({ file, compactAfterRecords: THRESHOLD }) };
}

test("journal compaction: the record that reaches the threshold is not lost", (t) => {
  const { file, make } = journal(t);
  let idem = make();
  assert.equal(idem.begin("d", "key-00000001", PRINT).state, "new");
  assert.equal(idem.begin("d", "key-00000002", PRINT).state, "new");
  assert.equal(idem.begin("d", "key-00000003", PRINT).state, "new", "this begin is the third record");
  idem.close();
  assert.match(fs.readFileSync(file, "utf8"), /key-00000003/, "the begin is on disk after the compaction");
  idem = make();
  assert.equal(idem.begin("d", "key-00000003", PRINT).state, "unknown", "a restart must not run the write again");
  idem.close();
});

test("journal compaction: a result that reaches the threshold is kept", (t) => {
  const { make } = journal(t);
  let idem = make();
  idem.begin("d", "key-00000001", PRINT);
  idem.begin("d", "key-00000002", PRINT);
  idem.complete("d", "key-00000001", { ok: 1 });
  idem.close();
  idem = make();
  assert.deepEqual(idem.begin("d", "key-00000001", PRINT), { state: "replay", result: { ok: 1 } });
  idem.close();
});

test("journal compaction: a release that reaches the threshold is kept", (t) => {
  const { make } = journal(t);
  let idem = make();
  idem.begin("d", "key-00000001", PRINT);
  idem.begin("d", "key-00000002", PRINT);
  idem.release("d", "key-00000001");
  idem.close();
  idem = make();
  assert.equal(idem.begin("d", "key-00000001", PRINT).state, "new", "a released key stays free");
  idem.close();
});

test("journal compaction: a compaction that fails does not fail the change or break the journal", (t) => {
  const { file, make } = journal(t);
  const blocker = `${file}.${process.pid}.tmp`;
  let idem = make();
  fs.mkdirSync(blocker);
  idem.begin("d", "key-00000001", PRINT);
  idem.begin("d", "key-00000002", PRINT);
  assert.equal(idem.begin("d", "key-00000003", PRINT).state, "new", "the begin is on disk, the write may go on");
  idem.complete("d", "key-00000003", { ok: 3 });
  idem.close();
  fs.rmdirSync(blocker);
  idem = make();
  assert.deepEqual(idem.begin("d", "key-00000003", PRINT), { state: "replay", result: { ok: 3 } }, "the journal still takes records");
  idem.close();
});

function peerPair(options) {
  const socket = new EventEmitter();
  socket.write = () => {};
  socket.end = () => {};
  socket.destroy = () => {};
  const peer = new WebSocketPeer(socket, options);
  const out = { socket, peer, messages: [], closes: [] };
  peer.on("message", (m) => out.messages.push(m));
  peer.on("close", (c) => out.closes.push(c));
  return out;
}

const raw = (opcode, payload, { fin = true } = {}) => {
  const f = encodeFrame(opcode, payload, { mask: true });
  if (!fin) f[0] &= 0x7f;
  return f;
};

test("websocket: a message made of up to the allowed number of fragments is delivered", () => {
  const p = peerPair({ maxFragments: 3 });
  p.socket.emit("data", raw(1, "a", { fin: false }));
  p.socket.emit("data", raw(0, "b", { fin: false }));
  p.socket.emit("data", raw(0, "c"));
  assert.deepEqual(p.messages, ["abc"]);
  assert.deepEqual(p.closes, []);
});

test("websocket: one more fragment than allowed closes with 1009, empty or not", () => {
  for (const piece of ["", "x"]) {
    const p = peerPair({ maxFragments: 3 });
    p.socket.emit("data", raw(1, piece, { fin: false }));
    p.socket.emit("data", raw(0, piece, { fin: false }));
    p.socket.emit("data", raw(0, piece, { fin: false }));
    assert.deepEqual(p.closes, [], "three fragments are allowed");
    p.socket.emit("data", raw(0, piece, { fin: false }));
    assert.deepEqual(p.closes, [1009], `fourth fragment ${JSON.stringify(piece)}`);
  }
});

test("websocket: endless empty continuation frames are cut at the default limit and retain a bounded amount", () => {
  const p = peerPair();
  p.socket.emit("data", raw(1, "", { fin: false }));
  let sent = 1;
  while (!p.closes.length && sent < 100_001) {
    p.socket.emit("data", raw(0, "", { fin: false }));
    sent += 1;
  }
  assert.deepEqual(p.closes, [1009]);
  assert.equal(sent, MAX_WS_FRAGMENTS + 1, "the first frame over the limit closes the socket");
  assert.ok(p.peer.fragments.length <= MAX_WS_FRAGMENTS);
});

test("websocket: a device that never ends a message is closed by the facade", async (t) => {
  const stack = await startStack();
  t.after(() => stack.close());
  const device = await stack.enroll("normal");
  const socket = await stack.ws({ token: device.token });
  const first = raw(1, "", { fin: false });
  const more = raw(0, "", { fin: false });
  socket.peer.write(Buffer.concat([first, ...Array.from({ length: 1000 }, () => more)]));
  assert.equal(await socket.closed(), 1009);
});
