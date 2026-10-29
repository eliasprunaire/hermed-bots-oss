"use strict";

const fs = require("node:fs");
const path = require("node:path");

const SECRET_KEY = /token|secret|authorization|cookie|password|^code$/i;
const RING_SIZE = 500;

// Append-only JSON lines. Every timestamp is UTC (ISO 8601 with a Z suffix).
// Values under secret-looking keys are masked so a token or a code can never reach the file.
class Audit {
  constructor({ file = null, now = Date.now } = {}) {
    this.file = file;
    this.now = now;
    this.ring = [];
    if (file) fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  }

  record(event, fields = {}) {
    const entry = { ts: new Date(this.now()).toISOString(), event };
    for (const [key, value] of Object.entries(fields)) {
      entry[key] = SECRET_KEY.test(key) ? "[redacted]" : value;
    }
    this.ring.push(entry);
    if (this.ring.length > RING_SIZE) this.ring.shift();
    if (this.file) fs.appendFileSync(this.file, `${JSON.stringify(entry)}\n`, { mode: 0o600 });
    return entry;
  }

  recent(limit = 100) {
    const n = Math.max(1, Math.min(Number(limit) || 100, RING_SIZE));
    return this.ring.slice(-n);
  }
}

module.exports = { Audit };
