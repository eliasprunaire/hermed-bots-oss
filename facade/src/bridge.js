"use strict";

const net = require("node:net");
const { Idempotency, fingerprint } = require("./idempotency");
const { rpcClass } = require("./policy");

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
    this.inflight = new Map();
    this.pending = [];
    this.ready = false;
    this.deviceGone = false;
    this.upstream = new WebSocket(upstreamUrl(config));
    this.upstream.addEventListener("open", () => this.onUpstreamOpen());
    this.upstream.addEventListener("message", (event) => this.onUpstreamMessage(event.data));
    this.upstream.addEventListener("close", () => this.onUpstreamClose());
    this.upstream.addEventListener("error", () => this.onUpstreamClose());
    ws.on("message", (text) => this.onDeviceMessage(text));
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

  onUpstreamMessage(data) {
    if (typeof data !== "string") return;
    let parsed = null;
    try {
      parsed = JSON.parse(data);
    } catch {
      parsed = null;
    }
    if (parsed && parsed.id !== undefined && this.inflight.has(parsed.id) && ("result" in parsed || "error" in parsed)) {
      const key = this.inflight.get(parsed.id);
      this.inflight.delete(parsed.id);
      if ("error" in parsed) this.idempotency.release(this.device.id, key);
      else this.idempotency.complete(this.device.id, key, parsed.result);
      if (this.deviceGone && this.inflight.size === 0) this.upstream.close();
    }
    this.ws.send(data);
  }

  onUpstreamClose() {
    if (this.upstreamDone) return;
    this.upstreamDone = true;
    this.ready = false;
    for (const key of this.inflight.values()) this.idempotency.markUnknown(this.device.id, key);
    this.inflight.clear();
    this.ws.close(1012, "upstream_closed");
  }

  onDeviceClose() {
    this.deviceGone = true;
    if (this.inflight.size === 0) {
      this.upstream.close();
      return;
    }
    setTimeout(() => this.upstream.close(), DRAIN_MS).unref();
  }

  terminate(reason) {
    for (const key of this.inflight.values()) this.idempotency.markUnknown(this.device.id, key);
    this.inflight.clear();
    this.ws.close(1008, reason);
    this.upstream.close();
  }

  async onDeviceMessage(text) {
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
    const id = message.id;
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
      this.audit.record("rpc_denied", { device: this.device.id, method: message.method.slice(0, 64) });
      this.ws.send(rpcError(id, CODE.denied, "method not allowed"));
      return;
    }
    if (message.params !== undefined && (typeof message.params !== "object" || message.params === null || Array.isArray(message.params))) {
      this.ws.send(rpcError(id, CODE.badParams, "params must be an object"));
      return;
    }
    if (kind === "read") {
      this.toUpstream(text);
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
    if (this.inflight.has(id)) {
      this.ws.send(rpcError(id, CODE.badParams, "this id is already in flight"));
      return;
    }
    const outcome = this.idempotency.begin(this.device.id, key, fingerprint(method, params));
    const resolved = outcome.state === "pending" ? await outcome.wait : outcome;
    const audit = (result) => this.audit.record("write", { device: this.device.id, method, result });
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
        this.inflight.set(id, key);
        this.toUpstream(JSON.stringify({ ...message, params }));
    }
  }
}

module.exports = { Bridge, CODE, rpcError };
