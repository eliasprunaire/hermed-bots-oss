"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { IDEMPOTENCY_TTL_MS } = require("./config");

const KEY_PATTERN = /^[A-Za-z0-9._:-]{8,128}$/;
const MAX_ENTRIES = 20_000;
const MAX_RESULT_BYTES = 64 * 1024;
const COMPACT_AFTER_RECORDS = 5000;

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function fingerprint(method, params) {
  return crypto.createHash("sha256").update(`${method}\n${canonical(params)}`).digest("hex");
}

// A write runs at most once per (device, key). A successful result is replayed. A failed
// call frees the key. A call whose outcome was lost (the upstream closed first, or the
// facade stopped while the call ran) is never run again: the key answers "unknown" until
// it expires.
//
// With a `file`, every change is appended to a journal and synced before the caller goes on.
// `begin` is on disk before the write is forwarded, so a crash at any point leaves a record.
// At start the journal is replayed, a write that was still running becomes "unknown", and the
// journal is rewritten (temporary file, sync, rename) with the live entries only.
class Idempotency {
  constructor({ now = Date.now, ttlMs = IDEMPOTENCY_TTL_MS, file = null } = {}) {
    this.now = now;
    this.ttlMs = ttlMs;
    this.file = file;
    this.entries = new Map();
    this.fd = null;
    this.records = 0;
    if (file) this.open();
  }

  static validKey(key) {
    return typeof key === "string" && KEY_PATTERN.test(key);
  }

  open() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true, mode: 0o700 });
    this.replay();
    this.compact();
  }

  replay() {
    let text = "";
    try {
      text = fs.readFileSync(this.file, "utf8");
    } catch (err) {
      if (err.code !== "ENOENT") throw err;
    }
    const at = this.now();
    for (const line of text.split("\n")) {
      if (!line) continue;
      let rec;
      try {
        rec = JSON.parse(line);
      } catch {
        continue;
      }
      if (!rec || typeof rec.scope !== "string" || typeof rec.key !== "string") continue;
      const id = `${rec.scope}\0${rec.key}`;
      const entry = this.entries.get(id);
      if (rec.op === "begin") {
        this.entries.set(id, { print: rec.print, state: "pending", waiters: [], expiresAt: rec.expiresAt });
      } else if (!entry) {
        continue;
      } else if (rec.op === "done") {
        entry.state = "done";
        entry.result = rec.result;
      } else if (rec.op === "unknown") {
        entry.state = "unknown";
      } else if (rec.op === "release") {
        this.entries.delete(id);
      }
    }
    for (const [id, entry] of this.entries) {
      if (entry.state === "pending") entry.state = "unknown";
      if (at >= entry.expiresAt) this.entries.delete(id);
    }
  }

  compact() {
    if (this.fd !== null) fs.closeSync(this.fd);
    const tmp = `${this.file}.${process.pid}.tmp`;
    const lines = [];
    for (const [id, entry] of this.entries) {
      const [scope, key] = id.split("\0");
      lines.push(JSON.stringify({ op: "begin", scope, key, print: entry.print, expiresAt: entry.expiresAt }));
      if (entry.state === "done") lines.push(JSON.stringify({ op: "done", scope, key, result: entry.result }));
      if (entry.state === "unknown") lines.push(JSON.stringify({ op: "unknown", scope, key }));
    }
    const fd = fs.openSync(tmp, "w", 0o600);
    fs.writeSync(fd, lines.length ? `${lines.join("\n")}\n` : "");
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fs.renameSync(tmp, this.file);
    this.fd = fs.openSync(this.file, "a", 0o600);
    this.records = 0;
  }

  journal(record) {
    if (this.fd === null) return;
    fs.writeSync(this.fd, `${JSON.stringify(record)}\n`);
    fs.fsyncSync(this.fd);
    this.records += 1;
    if (this.records >= COMPACT_AFTER_RECORDS) this.compact();
  }

  close() {
    if (this.fd !== null) fs.closeSync(this.fd);
    this.fd = null;
  }

  begin(scope, key, print) {
    const id = `${scope}\0${key}`;
    this.expire();
    let entry = this.entries.get(id);
    if (entry && entry.state !== "pending" && this.now() >= entry.expiresAt) {
      this.entries.delete(id);
      entry = undefined;
    }
    if (!entry) {
      const expiresAt = this.now() + this.ttlMs;
      this.journal({ op: "begin", scope, key, print, expiresAt });
      this.entries.set(id, { print, state: "pending", waiters: [], expiresAt });
      return { state: "new" };
    }
    if (entry.print !== print) return { state: "conflict" };
    if (entry.state === "done") return { state: "replay", result: entry.result };
    if (entry.state === "unknown") return { state: "unknown" };
    return { state: "pending", wait: new Promise((resolve) => entry.waiters.push(resolve)) };
  }

  complete(scope, key, result) {
    const entry = this.entries.get(`${scope}\0${key}`);
    if (!entry) return;
    if (Buffer.byteLength(JSON.stringify(result === undefined ? null : result)) > MAX_RESULT_BYTES) {
      this.markUnknown(scope, key);
      return;
    }
    this.journal({ op: "done", scope, key, result });
    entry.state = "done";
    entry.result = result;
    this.settle(entry, { state: "replay", result });
  }

  release(scope, key) {
    const id = `${scope}\0${key}`;
    const entry = this.entries.get(id);
    if (!entry) return;
    this.journal({ op: "release", scope, key });
    this.entries.delete(id);
    this.settle(entry, { state: "released" });
  }

  markUnknown(scope, key) {
    const entry = this.entries.get(`${scope}\0${key}`);
    if (!entry || entry.state !== "pending") return;
    this.journal({ op: "unknown", scope, key });
    entry.state = "unknown";
    this.settle(entry, { state: "unknown" });
  }

  settle(entry, outcome) {
    const waiters = entry.waiters;
    entry.waiters = [];
    for (const resolve of waiters) resolve(outcome);
  }

  expire() {
    if (this.entries.size < MAX_ENTRIES) return;
    const at = this.now();
    for (const [id, entry] of this.entries) {
      if (entry.state !== "pending" && at >= entry.expiresAt) this.entries.delete(id);
    }
  }
}

module.exports = { Idempotency, fingerprint };
