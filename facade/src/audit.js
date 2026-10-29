"use strict";

const fs = require("node:fs");
const path = require("node:path");

const SECRET_KEY = /token|secret|authorization|cookie|password|^code$/i;
const RING_SIZE = 500;
const MAX_VALUE = 200;

// Shapes of credentials. A value that carries one is masked wherever it sits, whatever its field is called.
const SECRET_SHAPES = [
  /\bBearer\s+\S+/gi,
  /\bBasic\s+[A-Za-z0-9+/=]{8,}/gi,
  /\bhbf_[A-Za-z0-9_-]{8,}/g,
  /\b[0-9A-Z]{5}(?:-[0-9A-Z]{5}){3}\b/g,
  /\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}(?:\.[A-Za-z0-9_-]*)?/g,
  /\b(?:sk|pk|rk|xox[abprs]|gh[pousr]|github_pat|glpat|AKIA|ASIA|AIza)[-_]?[A-Za-z0-9_-]{12,}/g,
  /\b[A-Fa-f0-9]{32,}\b/g,
  /[A-Za-z0-9_+/=-]{32,}/g,
];

// Append-only JSON lines. Every timestamp is UTC (ISO 8601 with a Z suffix).
// Nothing a device controls goes in raw. A value is masked when its field name looks secret,
// when it holds a known credential shape, or when it equals a secret the audit was told about.
class Audit {
  constructor({ file = null, now = Date.now, secrets = [] } = {}) {
    this.file = file;
    this.now = now;
    this.secrets = secrets.filter((s) => typeof s === "string" && s.length >= 8);
    this.ring = [];
    if (file) fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  }

  mask(value) {
    if (value === null || typeof value === "number" || typeof value === "boolean") return value;
    let text = typeof value === "string" ? value : JSON.stringify(value);
    if (text === undefined) return null;
    for (const secret of this.secrets) text = text.split(secret).join("[redacted]");
    for (const shape of SECRET_SHAPES) text = text.replace(shape, "[redacted]");
    text = text.replace(/[\u0000-\u001f\u007f]/g, " ");
    return text.length > MAX_VALUE ? `${text.slice(0, MAX_VALUE)}...` : text;
  }

  record(event, fields = {}) {
    const entry = { ts: new Date(this.now()).toISOString(), event };
    for (const [key, value] of Object.entries(fields)) {
      entry[key] = SECRET_KEY.test(key) ? "[redacted]" : this.mask(value);
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
