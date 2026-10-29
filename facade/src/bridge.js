"use strict";

const crypto = require("node:crypto");
const net = require("node:net");
const { Idempotency, fingerprint } = require("./idempotency");
const { RPC_ADMIN_WRITES, RPC_WRITES, rpcClass } = require("./policy");

const DRAIN_MS = 60_000;

const CODE = {
  parse: -32700,
  invalid: -32600,
  badParams: 4000,
  denied: 4003,
  keyRequired: 4004,
  keyReused: 4009,
  unknownOutcome: 4010,
  originalFailed: 4011,
  journal: 4012,
  rateLimited: 4029,
  upstream: 4502,
};

function rpcError(id, code, message, data) {
  const error = { code, message };
  if (data) Object.assign(error, data);
  return JSON.stringify({ jsonrpc: "2.0", id: id === undefined ? null : id, error });
}

function upstreamUrl(config) {
  const host = net.isIPv6(config.upstreamHost.replace(/^\[|\]$/g, "")) ? `[${config.upstreamHost.replace(/^\[|\]$/g, "")}]` : config.upstreamHost;
  return `ws://${host}:${config.upstreamPort}/api/ws?token=${encodeURIComponent(config.upstreamToken)}`;
}

// One bridge per device socket: a JSON-RPC message pump between the device (TLS) and the
// Hermes gateway on the loopback. Messages are checked one by one, so a method that the
// policy does not name never leaves the facade.
class Bridge {
  constructor({ ws, device, config, store, idempotency, limiter, audit }) {
    this.ws = ws;
    this.device = device;
    this.store = store;
    this.idempotency = idempotency;
    this.limiter = limiter;
    this.audit = audit;
    this.routes = new Map();
    this.idPrefix = crypto.randomBytes(6).toString("hex");
    this.idCounter = 0;
    this.pending = [];
    this.ready = false;
    this.deviceGone = false;
    this.upstream = new WebSocket(upstreamUrl(config));
    this.upstream.addEventListener("open", () => this.onUpstreamOpen());
    this.upstream.addEventListener("message", (event) => this.onUpstreamMessage(event.data));
    this.upstream.addEventListener("close", () => this.onUpstreamClose());
    this.upstream.addEventListener("error", () => this.onUpstreamClose());
    ws.on("message", (text) => this.onDeviceMessage(text));
    ws.on("fragment", () => this.onFragment());
    ws.on("close", () => this.onDeviceClose());
  }

  onUpstreamOpen() {
    this.ready = true;
    for (const text of this.pending) this.upstream.send(text);
    this.pending = [];
  }

  toUpstream(text) {
    if (this.ready) this.upstream.send(text);
    else this.pending.push(text);
  }

  // Every request leaves under an id the facade made, so a response is matched by the facade's
  // id and never by one a device chose. A device id is put back on the way out.
  nextUpstreamId() {
    this.idCounter += 1;
    return `fb-${this.idPrefix}-${this.idCounter}`;
  }

  forward(message, route) {
    if (!route) {
      const { id: _dropped, ...rest } = message;
      this.toUpstream(JSON.stringify(rest));
      return;
    }
    const upstreamId = this.nextUpstreamId();
    this.routes.set(upstreamId, route);
    this.toUpstream(JSON.stringify({ ...message, id: upstreamId }));
  }

  onUpstreamMessage(data) {
    if (typeof data !== "string") return;
    if (!this.deviceGone && !this.store.isActive(this.device.id)) {
      this.terminate("revoked");
      return;
    }
    let parsed = null;
    try {
      parsed = JSON.parse(data);
    } catch {
      parsed = null;
    }
    const isResponse = parsed && typeof parsed === "object" && ("result" in parsed || "error" in parsed) && !("method" in parsed);
    if (!isResponse) {
      if (!this.deviceGone) this.ws.send(data);
      return;
    }
    const route = typeof parsed.id === "string" ? this.routes.get(parsed.id) : undefined;
    if (!route) return;
    this.routes.delete(parsed.id);
    if (route.key !== undefined) {
      try {
        if ("error" in parsed) this.idempotency.release(this.device.id, route.key);
        else this.idempotency.complete(this.device.id, route.key, parsed.result);
      } catch {
        this.audit.record("journal_error", { device: this.device.id });
      }
    }
    if (this.deviceGone) {
      if (!this.hasWrites()) {
        clearTimeout(this.drain);
        this.upstream.close();
      }
      return;
    }
    this.ws.send(JSON.stringify({ ...parsed, id: route.id }));
  }

  onUpstreamClose() {
    if (this.upstreamDone) return;
    this.upstreamDone = true;
    this.ready = false;
    this.forgetInflight();
    this.ws.close(1012, "upstream_closed");
  }

  onDeviceClose() {
    this.deviceGone = true;
    if (!this.hasWrites()) {
      this.upstream.close();
      return;
    }
    this.drain = setTimeout(() => this.upstream.close(), DRAIN_MS);
    this.drain.unref();
  }

  hasWrites() {
    for (const route of this.routes.values()) if (route.key !== undefined) return true;
    return false;
  }

  forgetInflight() {
    for (const route of this.routes.values()) {
      if (route.key === undefined) continue;
      try {
        this.idempotency.markUnknown(this.device.id, route.key);
      } catch {
        this.audit.record("journal_error", { device: this.device.id });
      }
    }
    this.routes.clear();
  }

  terminate(reason) {
    this.forgetInflight();
    this.ws.close(1008, reason);
    this.upstream.close();
  }

  // A continuation frame is work too: it costs one call of the device budget, so a message cut in
  // many pieces, empty ones included, cannot be sent faster than the limit allows.
  onFragment() {
    if (this.deviceGone || this.ws.closing) return;
    const taken = this.limiter.take(`device:${this.device.id}`);
    if (taken.ok) return;
    this.audit.record("rate_limited", { device: this.device.id, surface: "ws_fragment" });
    this.forgetInflight();
    this.ws.close(1008, "rate_limited");
  }

  async onDeviceMessage(text) {
    if (this.ws.closing) return;
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      this.ws.send(rpcError(null, CODE.parse, "parse error"));
      return;
    }
    if (!message || typeof message !== "object" || Array.isArray(message) || typeof message.method !== "string") {
      this.ws.send(rpcError(null, CODE.invalid, "invalid request"));
      return;
    }
    const hasId = "id" in message;
    const id = message.id;
    if (hasId && id !== null && typeof id !== "string" && typeof id !== "number") {
      this.ws.send(rpcError(null, CODE.invalid, "id must be a string, a number or null"));
      return;
    }
    if (!this.store.isActive(this.device.id)) {
      this.terminate("revoked");
      return;
    }
    const taken = this.limiter.take(`device:${this.device.id}`);
    if (!taken.ok) {
      this.audit.record("rate_limited", { device: this.device.id, surface: "ws" });
      this.ws.send(rpcError(id, CODE.rateLimited, "rate limited", { retry_after_ms: taken.retryAfterMs }));
      return;
    }
    const kind = rpcClass(this.device.role, message.method);
    if (!kind) {
      this.audit.record("rpc_denied", { device: this.device.id, method_digest: crypto.createHash("sha256").update(message.method).digest("hex").slice(0, 12) });
      this.ws.send(rpcError(id, CODE.denied, "method not allowed"));
      return;
    }
    if (message.params !== undefined && (typeof message.params !== "object" || message.params === null || Array.isArray(message.params))) {
      this.ws.send(rpcError(id, CODE.badParams, "params must be an object"));
      return;
    }
    if (kind === "read") {
      this.forward(message, hasId ? { id } : null);
      return;
    }
    await this.write(message);
  }

  async write(message) {
    const { id, method } = message;
    if (typeof id !== "string" && typeof id !== "number") {
      this.ws.send(rpcError(null, CODE.badParams, "a write needs a string or number id"));
      return;
    }
    const { idempotency_key: key, ...params } = message.params || {};
    if (!Idempotency.validKey(key)) {
      this.ws.send(rpcError(id, CODE.keyRequired, "a write needs params.idempotency_key (8 to 128 characters of A-Z a-z 0-9 . _ : -)"));
      return;
    }
    let outcome;
    try {
      outcome = this.idempotency.begin(this.device.id, key, fingerprint(method, params));
    } catch {
      this.audit.record("journal_error", { device: this.device.id });
      this.ws.send(rpcError(id, CODE.journal, "the idempotency journal is unavailable, nothing was sent to Hermes"));
      return;
    }
    const resolved = outcome.state === "pending" ? await outcome.wait : outcome;
    if (!this.store.isActive(this.device.id)) {
      if (resolved.state === "new") this.settleUnsent(key);
      this.terminate("revoked");
      return;
    }
    const known = [...RPC_WRITES, ...RPC_ADMIN_WRITES].find((name) => name === method) || "[unlisted]";
    const audit = (result) => this.audit.record("write", { device: this.device.id, method: known, result });
    switch (resolved.state) {
      case "conflict":
        audit("key_reused");
        this.ws.send(rpcError(id, CODE.keyReused, "idempotency key already used with a different request"));
        return;
      case "unknown":
        audit("unknown_outcome");
        this.ws.send(rpcError(id, CODE.unknownOutcome, "the first attempt has an unknown outcome, use a new key after checking the session"));
        return;
      case "released":
        audit("original_failed");
        this.ws.send(rpcError(id, CODE.originalFailed, "the first attempt failed, retry with the same key"));
        return;
      case "replay":
        audit("replayed");
        this.ws.send(JSON.stringify({ jsonrpc: "2.0", id, result: resolved.result, idempotent_replay: true }));
        return;
      default:
        audit("forwarded");
        this.forward({ ...message, params }, { id, key });
    }
  }

  settleUnsent(key) {
    try {
      this.idempotency.release(this.device.id, key);
    } catch {
      this.audit.record("journal_error", { device: this.device.id });
    }
  }
}

module.exports = { Bridge, CODE, rpcError };
