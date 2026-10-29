"use strict";

const crypto = require("node:crypto");
const { IDEMPOTENCY_TTL_MS } = require("./config");

const KEY_PATTERN = /^[A-Za-z0-9._:-]{8,128}$/;
const MAX_ENTRIES = 20_000;

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
// call frees the key. A call whose outcome was lost (the upstream closed first) is never
// run again: the key answers "unknown" until it expires.
class Idempotency {
  constructor({ now = Date.now, ttlMs = IDEMPOTENCY_TTL_MS } = {}) {
    this.now = now;
    this.ttlMs = ttlMs;
    this.entries = new Map();
  }

  static validKey(key) {
    return typeof key === "string" && KEY_PATTERN.test(key);
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
      this.entries.set(id, { print, state: "pending", waiters: [], expiresAt: this.now() + this.ttlMs });
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
    entry.state = "done";
    entry.result = result;
    this.settle(entry, { state: "replay", result });
  }

  release(scope, key) {
    const id = `${scope}\0${key}`;
    const entry = this.entries.get(id);
    if (!entry) return;
    this.entries.delete(id);
    this.settle(entry, { state: "released" });
  }

  markUnknown(scope, key) {
    const entry = this.entries.get(`${scope}\0${key}`);
    if (!entry || entry.state !== "pending") return;
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
