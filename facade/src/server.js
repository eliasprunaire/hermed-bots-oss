"use strict";

const fs = require("node:fs");
const https = require("node:https");
const { Audit } = require("./audit");
const { Bridge } = require("./bridge");
const { MAX_BODY_BYTES, validate } = require("./config");
const { checkExposure } = require("./exposure");
const { Idempotency } = require("./idempotency");
const { FACADE_ADMIN, httpReadAllowed } = require("./policy");
const { fetchUpstreamStatus, json, projectStatus, proxyRead } = require("./proxy");
const { RateLimiter } = require("./ratelimit");
const { ROLES, Store } = require("./store");
const { acceptUpgrade } = require("./websocket");

const MINUTE = 60_000;
const HTTP_METHODS = new Set(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]);
const MAX_SOCKETS_PER_DEVICE = 8;
const NAME_PATTERN = /^[\p{L}\p{N} ._'()-]{1,64}$/u;

function bearer(req) {
  const match = /^Bearer ([^\s]+)$/.exec(String(req.headers.authorization || ""));
  return match ? match[1] : null;
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        if (size - chunk.length > MAX_BODY_BYTES) return;
        req.pause();
        reject(Object.assign(new Error("too large"), { status: 413 }));
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      try {
        const value = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
        if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("shape");
        resolve(value);
      } catch {
        reject(Object.assign(new Error("bad json"), { status: 400 }));
      }
    });
    req.on("error", reject);
  });
}

function createFacade(config, { now = Date.now, tls } = {}) {
  validate(config);
  const material = tls || { key: fs.readFileSync(config.tlsKey), cert: fs.readFileSync(config.tlsCert) };
  const audit = new Audit({ file: config.auditFile || null, now, secrets: [config.upstreamToken] });
  const store = new Store({ file: config.stateFile, now });
  const idempotency = new Idempotency({ now, file: config.idempotencyFile || null });
  const deviceLimiter = new RateLimiter({ limit: config.ratePerMinute, windowMs: MINUTE, now });
  const enrollLimiter = new RateLimiter({ limit: 10, windowMs: 5 * MINUTE, now });
  const failureLimiter = new RateLimiter({ limit: 30, windowMs: MINUTE, now });
  const sockets = new Map();

  const server = https.createServer({ ...material, minVersion: "TLSv1.3" });
  server.headersTimeout = 15_000;
  server.requestTimeout = 30_000;
  server.maxHeadersCount = 64;

  function authenticate(req) {
    const remote = req.socket.remoteAddress || "unknown";
    if (!failureLimiter.peek(remote).ok) return { status: 429, retryAfterMs: failureLimiter.peek(remote).retryAfterMs };
    const device = store.authenticate(bearer(req));
    if (device) return { device };
    failureLimiter.take(remote);
    audit.record("auth_denied", { surface: req.headers.upgrade ? "ws" : "http" });
    return { status: 401 };
  }

  function deny(res, outcome) {
    if (outcome.status === 429) {
      json(res, 429, { error: "rate_limited" }, { "retry-after": String(Math.ceil((outcome.retryAfterMs || MINUTE) / 1000)) });
    } else {
      json(res, 401, { error: "unauthorized" }, { "www-authenticate": "Bearer" });
    }
  }

  async function enroll(req, res) {
    const remote = req.socket.remoteAddress || "unknown";
    const taken = enrollLimiter.take(remote);
    if (!taken.ok) {
      audit.record("enroll_denied", { reason: "rate_limited" });
      json(res, 429, { error: "rate_limited" }, { "retry-after": String(Math.ceil(taken.retryAfterMs / 1000)) });
      return 429;
    }
    let body;
    try {
      body = await readJson(req);
    } catch (err) {
      json(res, err.status || 400, { error: "bad_request" }, { connection: "close" });
      return err.status || 400;
    }
    const name = typeof body.name === "string" ? body.name.trim() : "";
    if (!NAME_PATTERN.test(name) || typeof body.code !== "string" || body.code.length > 64) {
      json(res, 400, { error: "bad_request" });
      return 400;
    }
    const redeemed = store.redeemEnrollment(body.code, name);
    if (!redeemed.ok) {
      audit.record("enroll_denied", { reason: redeemed.reason });
      json(res, 401, { error: "enrollment_invalid" });
      return 401;
    }
    audit.record("enroll", { device: redeemed.device.id, role: redeemed.device.role });
    json(res, 201, { device_id: redeemed.device.id, role: redeemed.device.role, token: redeemed.token });
    return 201;
  }

  async function admin(req, res, url, device) {
    const route = `${req.method} ${url.pathname}`;
    if (route === "POST /facade/enrollments") {
      let body;
      try {
        body = await readJson(req);
      } catch (err) {
        json(res, err.status || 400, { error: "bad_request" }, { connection: "close" });
        return err.status || 400;
      }
      const role = body.role === undefined ? "normal" : body.role;
      if (!ROLES.includes(role)) {
        json(res, 400, { error: "bad_request" });
        return 400;
      }
      const made = store.createEnrollment({ role, createdBy: device.id });
      audit.record("enrollment_created", { device: device.id, role });
      json(res, 201, { code: made.code, role, expires_at: new Date(made.expiresAt).toISOString() });
      return 201;
    }
    if (route === "GET /facade/devices") {
      json(res, 200, {
        devices: store.list().map((d) => ({
          id: d.id,
          name: d.name,
          role: d.role,
          created_at: new Date(d.createdAt).toISOString(),
          revoked_at: d.revokedAt ? new Date(d.revokedAt).toISOString() : null,
        })),
      });
      return 200;
    }
    if (route === "GET /facade/audit") {
      json(res, 200, { events: audit.recent(Number(url.searchParams.get("limit"))) });
      return 200;
    }
    const revoke = /^\/facade\/devices\/(dev_[0-9a-f]{16})$/.exec(url.pathname);
    if (req.method === "DELETE" && revoke) {
      const revoked = store.revoke(revoke[1]);
      if (!revoked) {
        json(res, 404, { error: "not_found" });
        return 404;
      }
      audit.record("revoke", { device: device.id, target: revoked.id });
      res.writeHead(204, { "cache-control": "no-store" });
      res.end();
      return 204;
    }
    json(res, 404, { error: "not_found" });
    return 404;
  }

  function parseTarget(target) {
    try {
      return new URL(target, "https://localhost");
    } catch {
      return null;
    }
  }

  async function handle(req, res) {
    const url = parseTarget(req.url);
    if (!url) {
      json(res, 400, { error: "bad_request" }, { connection: "close" });
      return;
    }
    if (req.method === "POST" && url.pathname === "/facade/enroll") {
      await enroll(req, res);
      return;
    }
    const auth = authenticate(req);
    if (!auth.device) {
      deny(res, auth);
      return;
    }
    const { device } = auth;
    const taken = deviceLimiter.take(`device:${device.id}`);
    if (!taken.ok) {
      audit.record("rate_limited", { device: device.id, surface: "http" });
      json(res, 429, { error: "rate_limited" }, { "retry-after": String(Math.ceil(taken.retryAfterMs / 1000)) });
      return;
    }
    let status;
    const route = `${req.method} ${url.pathname}`;
    if (route === "GET /facade/whoami") {
      json(res, 200, { device_id: device.id, name: device.name, role: device.role });
      status = 200;
    } else if (route === "GET /facade/status") {
      try {
        json(res, 200, projectStatus(await fetchUpstreamStatus(config)));
        status = 200;
      } catch {
        json(res, 502, { error: "upstream_unavailable" });
        status = 502;
      }
    } else if (url.pathname.startsWith("/facade/")) {
      const adminRoute = FACADE_ADMIN.includes(route) || /^\/facade\/devices\/[^/]+$/.test(url.pathname);
      if (adminRoute && device.role !== "admin") {
        json(res, 403, { error: "forbidden" });
        status = 403;
      } else {
        status = await admin(req, res, url, device);
      }
    } else if (httpReadAllowed(req.method, url.pathname)) {
      status = await proxyRead(req, res, url, config);
    } else if (url.pathname.startsWith("/api/")) {
      json(res, 403, { error: "route_not_allowed" });
      status = 403;
    } else {
      json(res, 404, { error: "not_found" });
      status = 404;
    }
    const listed = status !== 404 && !(status === 403 && url.pathname.startsWith("/api/"));
    audit.record("request", { device: device.id, method: HTTP_METHODS.has(req.method) ? req.method : "other", path: listed ? url.pathname : "[unlisted]", status });
  }

  server.on("request", (req, res) => {
    handle(req, res).catch(() => {
      if (!res.headersSent) json(res, 500, { error: "internal_error" });
      else res.destroy();
    });
  });

  function refuse(socket, status, text) {
    socket.end(`HTTP/1.1 ${status} ${text}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n`);
  }

  server.on("upgrade", (req, socket, head) => {
    socket.on("error", () => {});
    try {
      upgrade(req, socket, head);
    } catch {
      refuse(socket, 400, "Bad Request");
    }
  });

  function upgrade(req, socket, head) {
    const url = parseTarget(req.url);
    if (!url) {
      refuse(socket, 400, "Bad Request");
      return;
    }
    if (url.pathname !== "/api/ws") {
      refuse(socket, 404, "Not Found");
      return;
    }
    const auth = authenticate(req);
    if (!auth.device) {
      refuse(socket, auth.status === 429 ? 429 : 401, auth.status === 429 ? "Too Many Requests" : "Unauthorized");
      return;
    }
    const { device } = auth;
    const open = sockets.get(device.id) || new Set();
    if (open.size >= MAX_SOCKETS_PER_DEVICE || !deviceLimiter.take(`device:${device.id}`).ok) {
      refuse(socket, 429, "Too Many Requests");
      return;
    }
    const ws = acceptUpgrade(req, socket, head);
    if (!ws) {
      refuse(socket, 400, "Bad Request");
      return;
    }
    const bridge = new Bridge({ ws, device, config, store, idempotency, limiter: deviceLimiter, audit });
    open.add(bridge);
    sockets.set(device.id, open);
    audit.record("ws_open", { device: device.id });
    ws.on("close", () => {
      open.delete(bridge);
      if (open.size === 0) sockets.delete(device.id);
      audit.record("ws_close", { device: device.id });
    });
  }

  server.on("tlsClientError", () => {});
  server.on("clientError", (_err, socket) => socket.destroy());

  store.on("revoked", (id) => {
    for (const bridge of sockets.get(id) || []) bridge.terminate("revoked");
  });

  let sweep = null;

  return {
    server,
    store,
    audit,
    idempotency,
    async start() {
      if (config.checkExposure) {
        const exposure = await checkExposure({ host: config.upstreamHost, port: config.upstreamPort });
        if (!exposure.ok) {
          audit.record("exposure_refused", { exposedOn: exposure.exposedOn });
          throw new Error("Hermes is reachable beyond the loopback: refusing to start, the facade would be bypassable");
        }
      }
      await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(config.listenPort, config.listenHost, resolve);
      });
      sweep = setInterval(() => store.refresh(), 1000);
      sweep.unref();
      audit.record("start", {});
      return server.address().port;
    },
    async close() {
      if (sweep) clearInterval(sweep);
      for (const set of sockets.values()) for (const bridge of set) bridge.terminate("shutdown");
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      idempotency.close();
    },
  };
}

module.exports = { createFacade };
