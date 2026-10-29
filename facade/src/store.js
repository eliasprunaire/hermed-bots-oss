"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { EventEmitter } = require("node:events");
const { ENROLLMENT_TTL_MS } = require("./config");

const ROLES = Object.freeze(["admin", "normal"]);
const TOKEN_PREFIX = "hbf_";
const CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const LOCK_STALE_MS = 10_000;
const KEEP_EXPIRED_MS = 24 * 60 * 60 * 1000;
const MAX_DEVICES = 200;

function sha256(text) {
  return crypto.createHash("sha256").update(text).digest("hex");
}

function newToken() {
  return TOKEN_PREFIX + crypto.randomBytes(32).toString("base64url");
}

function newCode() {
  let out = "";
  for (const byte of crypto.randomBytes(20)) out += CODE_ALPHABET[byte & 31];
  return out.match(/.{5}/g).join("-");
}

function normalizeCode(raw) {
  return String(raw || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function emptyState() {
  return { version: 1, devices: {}, enrollments: {} };
}

// Device and enrollment state, persisted as one JSON file that holds hashes only.
// A second process (the host CLI) may edit the file, so every read re-checks it.
class Store extends EventEmitter {
  constructor({ file, now = Date.now }) {
    super();
    this.file = file;
    this.now = now;
    this.state = emptyState();
    this.signature = null;
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    this.refresh();
  }

  fileSignature() {
    try {
      const st = fs.statSync(this.file, { bigint: true });
      return `${st.ino}:${st.size}:${st.mtimeNs}`;
    } catch (err) {
      if (err.code === "ENOENT") return "absent";
      throw err;
    }
  }

  refresh() {
    const signature = this.fileSignature();
    if (signature === this.signature) return;
    const before = this.state;
    this.state = signature === "absent" ? emptyState() : JSON.parse(fs.readFileSync(this.file, "utf8"));
    this.signature = signature;
    for (const [id, device] of Object.entries(this.state.devices)) {
      if (device.revokedAt && !(before.devices[id] && before.devices[id].revokedAt)) this.emit("revoked", id);
    }
  }

  withLock(fn) {
    const lock = `${this.file}.lock`;
    const started = Date.now();
    for (;;) {
      try {
        fs.mkdirSync(lock, { mode: 0o700 });
        break;
      } catch (err) {
        if (err.code !== "EEXIST") throw err;
        let age = 0;
        try {
          age = Date.now() - fs.statSync(lock).mtimeMs;
        } catch {
          continue;
        }
        if (age > LOCK_STALE_MS) {
          fs.rmSync(lock, { recursive: true, force: true });
          continue;
        }
        if (Date.now() - started > LOCK_STALE_MS) throw new Error("state lock timeout");
        sleepSync(5);
      }
    }
    try {
      this.signature = null;
      this.refresh();
      const result = fn(this.state);
      this.persist();
      return result;
    } finally {
      fs.rmSync(lock, { recursive: true, force: true });
    }
  }

  persist() {
    const tmp = `${this.file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.state, null, 2), { mode: 0o600 });
    fs.renameSync(tmp, this.file);
    this.signature = this.fileSignature();
  }

  createEnrollment({ role = "normal", createdBy = "host" } = {}) {
    if (!ROLES.includes(role)) throw new Error("unknown role");
    const code = newCode();
    const createdAt = this.now();
    const expiresAt = createdAt + ENROLLMENT_TTL_MS;
    this.withLock((state) => {
      for (const [hash, entry] of Object.entries(state.enrollments)) {
        if (entry.expiresAt + KEEP_EXPIRED_MS < createdAt) delete state.enrollments[hash];
      }
      state.enrollments[sha256(normalizeCode(code))] = { role, createdAt, expiresAt, usedAt: null, createdBy };
    });
    return { code, role, expiresAt };
  }

  // One-use code to device token. The failure reason is for the audit trail only.
  redeemEnrollment(rawCode, name) {
    const hash = sha256(normalizeCode(rawCode));
    const at = this.now();
    return this.withLock((state) => {
      const entry = state.enrollments[hash];
      if (!entry) return { ok: false, reason: "unknown" };
      if (entry.usedAt) return { ok: false, reason: "reused" };
      if (at >= entry.expiresAt) return { ok: false, reason: "expired" };
      if (Object.keys(state.devices).length >= MAX_DEVICES) return { ok: false, reason: "device_limit" };
      entry.usedAt = at;
      const token = newToken();
      const id = `dev_${crypto.randomBytes(8).toString("hex")}`;
      state.devices[id] = {
        id,
        name,
        role: entry.role,
        tokenHash: sha256(token),
        createdAt: at,
        lastSeenAt: null,
        revokedAt: null,
      };
      return { ok: true, token, device: this.publicDevice(state.devices[id]) };
    });
  }

  authenticate(token) {
    this.refresh();
    if (typeof token !== "string" || !token.startsWith(TOKEN_PREFIX) || token.length > 128) return null;
    const hash = sha256(token);
    for (const device of Object.values(this.state.devices)) {
      if (device.tokenHash === hash && !device.revokedAt) return this.publicDevice(device);
    }
    return null;
  }

  isActive(deviceId) {
    this.refresh();
    const device = this.state.devices[deviceId];
    return Boolean(device && !device.revokedAt);
  }

  revoke(deviceId) {
    const at = this.now();
    const done = this.withLock((state) => {
      const device = state.devices[deviceId];
      if (!device) return null;
      if (!device.revokedAt) device.revokedAt = at;
      return this.publicDevice(device);
    });
    if (done) this.emit("revoked", deviceId);
    return done;
  }

  list() {
    this.refresh();
    return Object.values(this.state.devices).map((device) => this.publicDevice(device));
  }

  publicDevice(device) {
    return {
      id: device.id,
      name: device.name,
      role: device.role,
      createdAt: device.createdAt,
      revokedAt: device.revokedAt,
    };
  }
}

module.exports = { Store, ROLES, TOKEN_PREFIX, normalizeCode };
