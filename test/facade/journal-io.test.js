"use strict";

// Fourth independent review of PR-1: the idempotency journal must survive a short or failed
// write, and a compaction must never leave the open descriptor on a replaced file
// Failure modes of the journal I/O, each covered below:
//   1. writeSync returns fewer bytes than asked (append and compaction)
//   2. writeSync returns 0
//   3. writeSync writes part of a record, then throws
//   4. fsync throws after the record is written
//   5. the compaction cannot create its temporary file (journal-frames.test.js)
//   6. the rename that publishes the compacted journal fails
//   7. the journal path cannot be opened after the rename

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { Idempotency, fingerprint } = require("../../facade/src/idempotency");

const PRINT = fingerprint("prompt.submit", { a: 1 });
const THRESHOLD = 3;
const key = (n) => `key-${String(n).padStart(8, "0")}`;
const eio = () => Object.assign(new Error("EIO: i/o error"), { code: "EIO" });

function journal(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "facade-journal-io-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "j.jsonl");
  return { dir, file, make: () => new Idempotency({ file, compactAfterRecords: THRESHOLD }) };
}

// replaces one fs function for the duration of fn only, so the test runner keeps the real one
function patched(name, impl, fn) {
  const real = fs[name];
  fs[name] = (...args) => impl(real, ...args);
  try {
    return fn();
  } finally {
    fs[name] = real;
  }
}

// the string form (fd, text) and the buffer form (fd, buffer, offset, length) both end here
function bytesOf(data, rest) {
  if (typeof data === "string") return Buffer.from(data);
  const offset = rest[0] ?? 0;
  return data.subarray(offset, offset + (rest[1] ?? data.length - offset));
}

const shortWrites = (limit) => (real, fd, data, ...rest) => {
  const bytes = bytesOf(data, rest);
  const part = bytes.subarray(0, limit);
  return real(fd, part, 0, part.length);
};

test("journal write: a short write is completed, so the record is whole on disk", (t) => {
  const { file, make } = journal(t);
  let idem = make();
  patched("writeSync", shortWrites(7), () => {
    assert.equal(idem.begin("d", key(1), PRINT).state, "new");
    idem.complete("d", key(1), { ok: 1 });
    assert.equal(idem.begin("d", key(2), PRINT).state, "new");
  });
  idem.close();
  const lines = fs.readFileSync(file, "utf8").split("\n").filter(Boolean);
  for (const line of lines) assert.doesNotThrow(() => JSON.parse(line), `a whole record: ${line}`);
  idem = make();
  assert.deepEqual(idem.begin("d", key(1), PRINT), { state: "replay", result: { ok: 1 } });
  assert.equal(idem.begin("d", key(2), PRINT).state, "unknown", "a restart must not run the write again");
  idem.close();
});

test("journal write: a short write during a compaction does not truncate the published journal", (t) => {
  const { make } = journal(t);
  let idem = make();
  patched("writeSync", shortWrites(5), () => {
    for (let n = 1; n <= THRESHOLD; n++) assert.equal(idem.begin("d", key(n), PRINT).state, "new");
  });
  idem.close();
  idem = make();
  for (let n = 1; n <= THRESHOLD; n++) assert.equal(idem.begin("d", key(n), PRINT).state, "unknown", key(n));
  idem.close();
});

test("journal write: a write that returns 0 bytes fails the change and does not spin", (t) => {
  const { make } = journal(t);
  const idem = make();
  patched("writeSync", () => 0, () => {
    assert.throws(() => idem.begin("d", key(1), PRINT), /EIO|journal/);
  });
  idem.close();
});

test("journal write: after a write that fails midway, the next record is not merged into the torn line", (t) => {
  const { file, make } = journal(t);
  let idem = make();
  let failed = false;
  patched(
    "writeSync",
    (real, fd, data, ...rest) => {
      const bytes = bytesOf(data, rest);
      if (failed) return real(fd, bytes, 0, bytes.length);
      failed = true;
      real(fd, bytes.subarray(0, 5), 0, 5);
      throw eio();
    },
    () => assert.throws(() => idem.begin("d", key(1), PRINT), /EIO/, "the change fails, nothing may reach Hermes"),
  );
  assert.equal(idem.begin("d", key(2), PRINT).state, "new");
  idem.close();
  assert.ok(fs.readFileSync(file, "utf8").split("\n").some((l) => l.includes(key(2))), "the record sits on a line of its own");
  idem = make();
  assert.equal(idem.begin("d", key(2), PRINT).state, "unknown", "a restart must not run the write again");
  assert.equal(idem.begin("d", key(1), PRINT).state, "new", "the failed begin was never forwarded");
  idem.close();
});

test("journal write: an fsync that fails refuses the change, and the journal goes on", (t) => {
  const { make } = journal(t);
  let idem = make();
  let failed = false;
  patched(
    "fsyncSync",
    (real, fd) => {
      if (failed) return real(fd);
      failed = true;
      throw eio();
    },
    () => assert.throws(() => idem.begin("d", key(1), PRINT), /EIO/),
  );
  assert.equal(idem.begin("d", key(2), PRINT).state, "new");
  idem.close();
  idem = make();
  assert.equal(idem.begin("d", key(2), PRINT).state, "unknown");
  assert.equal(idem.begin("d", key(1), PRINT).state, "unknown", "the record reached the file, so the key is never run again");
  idem.close();
});

test("journal compaction: a rename that fails keeps the current journal in use and leaves no temporary file", (t) => {
  const { dir, make } = journal(t);
  let idem = make();
  patched(
    "renameSync",
    () => {
      throw eio();
    },
    () => {
      for (let n = 1; n <= THRESHOLD; n++) assert.equal(idem.begin("d", key(n), PRINT).state, "new", "the change itself succeeds");
    },
  );
  assert.deepEqual(fs.readdirSync(dir), ["j.jsonl"], "the temporary file is removed");
  assert.equal(idem.begin("d", key(THRESHOLD + 1), PRINT).state, "new");
  idem.close();
  idem = make();
  for (let n = 1; n <= THRESHOLD + 1; n++) assert.equal(idem.begin("d", key(n), PRINT).state, "unknown", key(n));
  idem.close();
});

test("journal compaction: records written after a compaction reach the published file when every later open fails", (t) => {
  const { file, make } = journal(t);
  let idem = make();
  let broken = false;
  patched(
    "openSync",
    (real, p, ...rest) => {
      if (broken || p === file) throw eio();
      return real(p, ...rest);
    },
    () => {
      for (let n = 1; n <= THRESHOLD; n++) assert.equal(idem.begin("d", key(n), PRINT).state, "new", key(n));
      // from here no compaction can run again, so a record is on disk only if the descriptor is on the published file
      broken = true;
      for (let n = THRESHOLD + 1; n <= THRESHOLD + 2; n++) assert.equal(idem.begin("d", key(n), PRINT).state, "new", key(n));
    },
  );
  idem.close();
  idem = make();
  for (let n = 1; n <= THRESHOLD + 2; n++) assert.equal(idem.begin("d", key(n), PRINT).state, "unknown", `${key(n)} must survive a restart`);
  idem.close();
});
