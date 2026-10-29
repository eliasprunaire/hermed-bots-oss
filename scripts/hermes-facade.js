"use strict";
// Hermes facade (PR-1): TLS termination with an internal CA, one opaque token per device,
// revocation, roles, UTC audit and rate limits in front of a Hermes that listens on the host
// loopback only; Hermes credentials stay inside this process; no dependency but node and openssl

const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const https = require("node:https");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const tls = require("node:tls");
const { execFileSync } = require("node:child_process");

const ENROL_CODE_TTL_MS = 5 * 60 * 1000;
const IDEMPOTENCY_TTL_MS = 24 * 60 * 60 * 1000;
const IDEMPOTENCY_MAX_ENTRIES = 10_000;
const IDEMPOTENCY_MAX_BODY = 16 * 1024;
const MAX_BODY = 1024 * 1024;
const UPSTREAM_TIMEOUT_MS = 30_000;
const ROLES = ["admin", "normal"];
const CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

const DEFAULT_LIMITS = {
  enrol: { burst: 5, perSecond: 5 / 60 },
  enrolAll: { burst: 30, perSecond: 0.5 },
  fail: { burst: 10, perSecond: 10 / 60 },
  device: { burst: 60, perSecond: 20 },
  write: { burst: 20, perSecond: 5 },
};

// Allowlist, deny by default: the tail of each route after the optional /p/<profile> prefix
// Not forwarded on purpose: /api/config, /api/env, /auth/*, the dashboard, and the streamed
// chat route (its answer cannot be replayed for an idempotent retry)
const ID = "[A-Za-z0-9_-]{1,128}";
const route = (method, tail, name, kind) => ({
  method,
  name,
  kind,
  re: new RegExp(`^(?:/p/([A-Za-z0-9][A-Za-z0-9_-]{0,63}))?${tail}$`),
});
const ROUTES = [
  route("GET", "/health", "health"),
  route("GET", "/v1/capabilities", "capabilities"),
  route("GET", "/v1/models", "models"),
  route("GET", `/v1/runs/${ID}`, "run.get"),
  route("GET", `/v1/runs/${ID}/events`, "run.events", "stream"),
  route("POST", "/v1/runs", "run.create", "write"),
  route("POST", `/v1/runs/${ID}/approval`, "run.approval", "write"),
  route("POST", `/v1/runs/${ID}/stop`, "run.stop", "write"),
  route("GET", "/api/sessions", "session.list"),
  route("GET", `/api/sessions/${ID}`, "session.get"),
  route("GET", `/api/sessions/${ID}/messages`, "session.messages"),
  route("POST", "/api/sessions", "session.create", "write"),
  route("POST", `/api/sessions/${ID}/model`, "session.model", "write"),
  route("POST", `/api/sessions/${ID}/chat`, "session.chat", "write"),
];

const sha256hex = (v) => crypto.createHash("sha256").update(v).digest("hex");
const randomB64url = (n) => crypto.randomBytes(n).toString("base64url");
const iso = (ms) => new Date(ms).toISOString();

function httpError(status, error) {
  return Object.assign(new Error(error), { status, error });
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}

// the temporary name stays in the same folder so that rename is atomic
function writeJsonAtomic(file, value) {
  const tmp = `${file}.${randomB64url(6)}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 });
  fs.renameSync(tmp, file);
}

// one JSON line per event, UTC; the CLI and the server append to the same file
function appendAudit(dataDir, event, fields, now = Date.now()) {
  fs.appendFileSync(path.join(ensureDir(dataDir), "audit.log"), `${JSON.stringify({ ts: iso(now), event, ...fields })}\n`, { mode: 0o600 });
}

// ---------------------------------------------------------------- TLS: internal CA and pin

function openssl(args, cwd) {
  execFileSync("openssl", args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
}

const SAN_RE = /^(?:DNS:[A-Za-z0-9.-]{1,253}|IP:[0-9A-Fa-f:.]{2,45})$/;

function spkiPin(pem) {
  const spki = new crypto.X509Certificate(pem).publicKey.export({ type: "spki", format: "der" });
  return crypto.createHash("sha256").update(spki).digest("base64");
}

// Creates the CA once, the server key once (so the pin survives a renewal), and a new server
// certificate each call
// shortcut: the CA key stays in the data folder, move it offline once the certificate is issued
function initTls(dataDir, { sans = [] } = {}) {
  const names = ["DNS:localhost", "IP:127.0.0.1", "IP:::1", ...sans];
  for (const san of names) if (!SAN_RE.test(san)) throw new Error(`bad subject alternative name: ${san}`);
  const dir = ensureDir(path.join(dataDir, "tls"));
  const file = (n) => path.join(dir, n);
  const keyAlg = ["genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"];
  fs.writeFileSync(file("openssl.cnf"), [
    "[req]", "distinguished_name=dn", "[dn]",
    "[ca_ext]", "basicConstraints=critical,CA:TRUE,pathlen:0", "keyUsage=critical,keyCertSign,cRLSign", "subjectKeyIdentifier=hash",
    "[leaf_ext]", "basicConstraints=critical,CA:FALSE", "keyUsage=critical,digitalSignature", "extendedKeyUsage=serverAuth",
    "authorityKeyIdentifier=keyid", `subjectAltName=${names.join(",")}`, "",
  ].join("\n"));
  if (!fs.existsSync(file("ca.key"))) {
    openssl([...keyAlg, "-out", file("ca.key")]);
    openssl(["req", "-new", "-x509", "-key", file("ca.key"), "-sha256", "-days", "3650", "-subj", `/CN=Hermed Facade CA ${randomB64url(4)}`,
      "-config", file("openssl.cnf"), "-extensions", "ca_ext", "-out", file("ca.crt")]);
  }
  if (!fs.existsSync(file("server.key"))) openssl([...keyAlg, "-out", file("server.key")]);
  openssl(["req", "-new", "-key", file("server.key"), "-subj", "/CN=hermes-facade", "-config", file("openssl.cnf"), "-out", file("server.csr")]);
  openssl(["x509", "-req", "-in", file("server.csr"), "-CA", file("ca.crt"), "-CAkey", file("ca.key"), "-CAcreateserial",
    "-sha256", "-days", "365", "-extfile", file("openssl.cnf"), "-extensions", "leaf_ext", "-out", file("server.crt")]);
  fs.rmSync(file("server.csr"));
  for (const k of ["ca.key", "server.key"]) fs.chmodSync(file(k), 0o600);
  const caPem = fs.readFileSync(file("ca.crt"), "utf8");
  return {
    caPem,
    caFingerprint: new crypto.X509Certificate(caPem).fingerprint256,
    serverPin: spkiPin(fs.readFileSync(file("server.crt"), "utf8")),
  };
}

// Options for https.request: the internal CA is the only anchor, and the SPKI hash of the server
// certificate has to match the pin learned at enrolment
function pinnedTlsOptions({ ca, pin }) {
  return {
    ca,
    minVersion: "TLSv1.3",
    checkServerIdentity(host, cert) {
      const err = tls.checkServerIdentity(host, cert);
      if (err) return err;
      if (spkiPin(cert.raw) !== pin) return new Error("server certificate pin mismatch");
      return undefined;
    },
  };
}

// ---------------------------------------------------------------- state: codes, devices, audit
// One file per code and per device: an enrolment is a rename (one winner), a revocation rewrites
// one file, so the CLI and the server never overwrite each other
// shortcut: synchronous fs on files of a few hundred bytes, use a database above a few thousand devices

function normalizeCode(code) {
  return String(code ?? "").toUpperCase().replace(/[^0-9A-Z]/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
}

function createEnrolCode(dataDir, role, now = Date.now()) {
  if (!ROLES.includes(role)) throw new Error("role must be admin or normal");
  const dir = ensureDir(path.join(dataDir, "codes"));
  for (const f of fs.readdirSync(dir)) {
    try {
      if (JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")).expires_at <= now) fs.rmSync(path.join(dir, f));
    } catch { /* another process took it */ }
  }
  const raw = Array.from(crypto.randomBytes(12), (b) => CODE_ALPHABET[b & 31]).join("");
  const expiresAt = now + ENROL_CODE_TTL_MS;
  fs.writeFileSync(path.join(dir, `${sha256hex(raw)}.json`), JSON.stringify({ role, expires_at: expiresAt }), { mode: 0o600, flag: "wx" });
  return { code: raw.replace(/(.{4})(?=.)/g, "$1-"), role, expires_at: iso(expiresAt) };
}

// null when the code is unknown, used or expired: the three cases are not told apart
function redeemEnrolCode(dataDir, code, name, now = Date.now()) {
  const norm = normalizeCode(code);
  if (!/^[0-9A-Z]{12}$/.test(norm)) return null;
  const file = path.join(dataDir, "codes", `${sha256hex(norm)}.json`);
  const claimed = `${file}.${randomB64url(6)}.used`;
  try {
    fs.renameSync(file, claimed);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
  let entry;
  try {
    entry = JSON.parse(fs.readFileSync(claimed, "utf8"));
  } finally {
    fs.rmSync(claimed, { force: true });
  }
  if (!(entry.expires_at > now)) return null;
  const id = crypto.randomBytes(8).toString("hex");
  const secret = randomB64url(32);
  const device = {
    id,
    name: String(name ?? "").replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, 64) || "device",
    role: entry.role,
    created_at: iso(now),
    token_sha256: sha256hex(secret),
  };
  writeJsonAtomic(path.join(ensureDir(path.join(dataDir, "devices")), `${id}.json`), device);
  return { device_id: id, role: device.role, token: `${id}.${secret}` };
}

function readDevice(dataDir, id) {
  if (!/^[0-9a-f]{16}$/.test(id)) return null;
  try {
    return JSON.parse(fs.readFileSync(path.join(dataDir, "devices", `${id}.json`), "utf8"));
  } catch {
    return null;
  }
}

const publicDevice = ({ id, name, role, created_at, revoked_at }) => ({ id, name, role, created_at, revoked_at });

function authenticate(dataDir, token) {
  const m = /^([0-9a-f]{16})\.([A-Za-z0-9_-]{43})$/.exec(token || "");
  if (!m) return { reason: "malformed" };
  const device = readDevice(dataDir, m[1]);
  if (!device) return { reason: "unknown", deviceId: m[1] };
  const got = Buffer.from(sha256hex(m[2]), "hex");
  const want = Buffer.from(String(device.token_sha256), "hex");
  if (got.length !== want.length || !crypto.timingSafeEqual(got, want)) return { reason: "bad_secret", deviceId: m[1] };
  if (device.revoked_at) return { reason: "revoked", deviceId: m[1] };
  return { device };
}

function revokeDevice(dataDir, id, now = Date.now()) {
  const device = readDevice(dataDir, id);
  if (!device) return null;
  if (!device.revoked_at) {
    device.revoked_at = iso(now);
    writeJsonAtomic(path.join(dataDir, "devices", `${id}.json`), device);
  }
  return publicDevice(device);
}

function listDevices(dataDir) {
  const dir = path.join(dataDir, "devices");
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((f) => f.endsWith(".json"))
    .map((f) => readDevice(dataDir, f.slice(0, -5))).filter(Boolean)
    .map(publicDevice).sort((a, b) => a.created_at.localeCompare(b.created_at));
}

class Limiter {
  constructor(clock) {
    this.clock = clock;
    this.buckets = new Map();
  }

  // 0 when allowed, else the seconds to wait; the least recently used bucket leaves first
  take(key, { burst, perSecond }) {
    const now = this.clock();
    const b = this.buckets.get(key) || { tokens: burst, at: now };
    this.buckets.delete(key);
    this.buckets.set(key, b);
    if (this.buckets.size > 10_000) this.buckets.delete(this.buckets.keys().next().value);
    b.tokens = Math.min(burst, b.tokens + ((now - b.at) / 1000) * perSecond);
    b.at = now;
    if (b.tokens >= 1) {
      b.tokens -= 1;
      return 0;
    }
    return Math.ceil((1 - b.tokens) / perSecond);
  }
}

// ---------------------------------------------------------------- upstream and configuration

function parseUpstream(raw) {
  let u;
  try {
    u = new URL(raw);
  } catch {
    throw new Error("FACADE_UPSTREAM must be a URL such as http://127.0.0.1:8642");
  }
  const host = u.hostname.replace(/^\[|\]$/g, "");
  if (u.protocol !== "http:" || !["127.0.0.1", "::1"].includes(host) || u.username || u.password || u.pathname !== "/" || u.search) {
    throw new Error("FACADE_UPSTREAM must be http://127.0.0.1:<port> or http://[::1]:<port>: Hermes stays reachable on the host only");
  }
  return { host, port: Number(u.port || 80) };
}

function configFromEnv(env) {
  if (!env.FACADE_DATA) throw new Error("FACADE_DATA is required");
  if (!env.FACADE_UPSTREAM) throw new Error("FACADE_UPSTREAM is required");
  const port = Number(env.FACADE_LISTEN_PORT || 8643);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error("FACADE_LISTEN_PORT must be a port number");
  let upstreamKeys;
  if (env.FACADE_UPSTREAM_KEYS) {
    try {
      upstreamKeys = JSON.parse(env.FACADE_UPSTREAM_KEYS);
    } catch { /* checked below */ }
    if (!upstreamKeys || typeof upstreamKeys !== "object" || Array.isArray(upstreamKeys) || !Object.values(upstreamKeys).every((v) => typeof v === "string")) {
      throw new Error('FACADE_UPSTREAM_KEYS must be a JSON object such as {"default":"<key>"}');
    }
  }
  return {
    dataDir: env.FACADE_DATA,
    upstream: env.FACADE_UPSTREAM,
    upstreamKey: env.FACADE_UPSTREAM_KEY || undefined,
    upstreamKeys,
    host: env.FACADE_LISTEN_HOST || "127.0.0.1",
    port,
  };
}

function externalAddresses() {
  const out = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const { internal, address } of list || []) if (!internal) out.push(address.startsWith("fe80:") ? `${address}%${name}` : address);
  }
  return out;
}

// Addresses of this host (outside the loopback) that accept a connection on the port
async function findExposure(port, { addresses = externalAddresses(), timeoutMs = 1000 } = {}) {
  const hits = [];
  await Promise.all(addresses.map((host) => new Promise((resolve) => {
    const s = net.connect({ host, port, timeout: timeoutMs });
    s.once("connect", () => { hits.push(host); s.destroy(); resolve(); });
    s.once("error", resolve);
    s.once("timeout", () => { s.destroy(); resolve(); });
  })));
  return hits.sort();
}

// ---------------------------------------------------------------- server

const PASS_HEADERS = ["content-type", "cache-control", "retry-after", "idempotency-replayed"];
const pickHeaders = (h) => Object.fromEntries(PASS_HEADERS.filter((n) => h[n]).map((n) => [n, h[n]]));

function readBody(req, max) {
  if (Number(req.headers["content-length"] || 0) > max) {
    req.resume();
    return Promise.reject(httpError(413, "body_too_large"));
  }
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let over = false;
    req.on("data", (c) => {
      if (over) return;
      size += c.length;
      if (size > max) {
        over = true;
        reject(httpError(413, "body_too_large"));
      } else {
        chunks.push(c);
      }
    });
    req.on("end", () => { if (!over) resolve(Buffer.concat(chunks)); });
    req.on("error", reject);
  });
}

function send(res, status, body, extra = {}) {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(text),
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    ...extra,
  });
  res.end(text);
}

async function startFacade(cfg) {
  const up = parseUpstream(cfg.upstream);
  const dataDir = cfg.dataDir;
  const clock = cfg.clock || Date.now;
  const limits = { ...DEFAULT_LIMITS, ...cfg.limits };
  const maxBody = cfg.maxBody || MAX_BODY;
  const limiter = new Limiter(clock);
  const streams = new Set();
  ensureDir(dataDir);
  const audit = (event, fields) => appendAudit(dataDir, event, fields, clock());
  const upstreamKeyFor = (profile) => (cfg.upstreamKeys && cfg.upstreamKeys[profile]) || cfg.upstreamKey;

  // The journal is the memory of the idempotency keys: one file per key, written before the request
  // leaves, so a restart or a lost answer never sends the same key to Hermes twice
  // state: pending (written, no answer yet), done (answer kept), unknown (Hermes may have run it)
  // shortcut: one synchronous file read per write, use a database above a few thousand writes a day
  const journalDir = ensureDir(path.join(dataDir, "idempotency"));
  const journalMax = cfg.idempotencyMax || IDEMPOTENCY_MAX_ENTRIES;
  const journalFile = (sid) => path.join(journalDir, `${sid}.json`);
  const inflight = new Map();
  let closed = false;

  // a damaged file reads as an unknown outcome: the write is not sent again
  function readJournal(sid, now) {
    let entry;
    try {
      entry = JSON.parse(fs.readFileSync(journalFile(sid), "utf8"));
    } catch (err) {
      return err.code === "ENOENT" ? null : { state: "unknown" };
    }
    if (typeof entry?.expires !== "number") return { state: "unknown" };
    if (entry.expires <= now) {
      fs.rmSync(journalFile(sid), { force: true });
      return null;
    }
    return entry;
  }

  // after close() a new process may own the journal: this one stops writing to it
  function settleJournal(sid, entry) {
    if (closed) return;
    try {
      if (entry) writeJsonAtomic(journalFile(sid), entry);
      else fs.rmSync(journalFile(sid), { force: true });
    } catch {
      console.error("hermes-facade: idempotency journal update failed");
    }
  }

  function purgeJournal(now) {
    for (const f of fs.readdirSync(journalDir)) {
      const file = path.join(journalDir, f);
      try {
        let expires;
        try {
          expires = JSON.parse(fs.readFileSync(file, "utf8")).expires;
        } catch {
          expires = fs.statSync(file).mtimeMs + IDEMPOTENCY_TTL_MS;
        }
        if (!(expires > now)) fs.rmSync(file, { force: true });
      } catch { /* removed by another call */ }
    }
  }

  // a full journal refuses a new key: forgetting a live key would let its write go twice
  function journalHasRoom(now) {
    if (fs.readdirSync(journalDir).length < journalMax) return true;
    purgeJournal(now);
    return fs.readdirSync(journalDir).length < journalMax;
  }

  function callUpstream({ method, target, headers, body, key }) {
    return new Promise((resolve, reject) => {
      const h = { host: net.isIPv6(up.host) ? `[${up.host}]:${up.port}` : `${up.host}:${up.port}`, authorization: `Bearer ${key}`, accept: headers.accept || "*/*" };
      for (const name of ["content-type", "last-event-id"]) if (headers[name]) h[name] = headers[name];
      if (headers["idempotency-key"]) h["idempotency-key"] = headers["idempotency-key"];
      if (body) h["content-length"] = body.length;
      const r = http.request({ host: up.host, port: up.port, method, path: target, headers: h, timeout: UPSTREAM_TIMEOUT_MS }, resolve);
      r.on("timeout", () => r.destroy(Object.assign(new Error("timeout"), { code: "ETIMEDOUT" })));
      r.on("error", reject);
      r.end(body);
    });
  }

  // Hermes answers that must not reach a device: its own auth failure and its redirects
  // Hermes did not run the request in these cases, and when the connection was refused
  function refusal(upRes) {
    if (upRes.statusCode === 401) return "upstream_rejected";
    if (upRes.statusCode >= 300 && upRes.statusCode < 400) return "upstream_redirect";
    return null;
  }

  async function bufferResponse(upRes) {
    const chunks = [];
    let size = 0;
    for await (const c of upRes) {
      size += c.length;
      if (size > MAX_BODY) throw httpError(502, "upstream_response_too_large");
      chunks.push(c);
    }
    return Buffer.concat(chunks);
  }

  function replyBuffered(res, r, extra = {}) {
    res.writeHead(r.status, { ...r.headers, "content-length": r.body.length, ...extra });
    res.end(r.body);
  }

  // One upstream exchange read completely: the unit that a replay returns
  // notRun marks a failure after which Hermes certainly did not run the request: any other
  // failure leaves the outcome unknown
  async function exchange(opts) {
    let upRes;
    try {
      upRes = await callUpstream(opts);
    } catch (err) {
      throw Object.assign(httpError(502, err.code === "ETIMEDOUT" ? "upstream_timeout" : "upstream_unavailable"), { notRun: err.code === "ECONNREFUSED" });
    }
    const refused = refusal(upRes);
    if (refused) {
      upRes.resume();
      throw Object.assign(httpError(502, refused), { notRun: true });
    }
    const body = await bufferResponse(upRes).catch((err) => { throw err.status ? err : httpError(502, "upstream_unavailable"); });
    return { status: upRes.statusCode, headers: pickHeaders(upRes.headers), body };
  }

  async function write(req, res, ctx) {
    const key = req.headers["idempotency-key"];
    if (key === undefined) throw httpError(400, "idempotency_key_required");
    if (!/^[\x21-\x7e]{1,128}$/.test(key)) throw httpError(400, "idempotency_key_invalid");
    const body = await readBody(req, maxBody);
    const hash = sha256hex(body);
    const sid = sha256hex([ctx.device.id, req.method, ctx.pathname, key].join("\n"));
    const now = clock();
    const flying = inflight.get(sid);
    const saved = flying || readJournal(sid, now);
    if (saved && saved.hash && saved.hash !== hash) throw httpError(409, "idempotency_key_conflict");

    let result;
    if (flying) {
      result = await flying.promise;
    } else if (saved) {
      if (saved.state !== "done") throw httpError(502, "write_outcome_unknown");
      result = { status: saved.result.status, headers: saved.result.headers, body: saved.result.body === null ? null : Buffer.from(saved.result.body, "base64") };
    } else {
      if (!journalHasRoom(now)) throw httpError(503, "idempotency_journal_full");
      const record = { hash, expires: now + IDEMPOTENCY_TTL_MS };
      // not caught: when the record cannot be written, the request does not leave
      writeJsonAtomic(journalFile(sid), { ...record, state: "pending" });
      const promise = exchange({
        method: req.method,
        target: ctx.pathname,
        headers: { ...req.headers, "idempotency-key": `${ctx.device.id}:${key}` },
        body,
        key: ctx.upstreamKey,
      }).then((r) => {
        // a refusal to retry later says nothing about the write: the key stays free, the headers stay
        const transient = r.status === 408 || r.status === 429 || r.status >= 500;
        const stored = r.body.length <= IDEMPOTENCY_MAX_BODY ? r.body.toString("base64") : null;
        settleJournal(sid, transient ? null : { ...record, state: "done", result: { status: r.status, headers: r.headers, body: stored } });
        return r;
      }, (err) => {
        if (err.notRun) {
          settleJournal(sid, null);
          throw err;
        }
        settleJournal(sid, { ...record, state: "unknown" });
        throw httpError(502, "write_outcome_unknown");
      }).finally(() => inflight.delete(sid));
      inflight.set(sid, { hash, promise });
      return replyBuffered(res, await promise);
    }
    if (!result.body || result.body.length > IDEMPOTENCY_MAX_BODY) throw httpError(409, "idempotency_replay_unavailable");
    return replyBuffered(res, result, { "idempotency-replayed": "true" });
  }

  async function read(req, res, ctx) {
    let upRes;
    try {
      upRes = await callUpstream({ method: "GET", target: ctx.target, headers: req.headers, key: ctx.upstreamKey });
    } catch (err) {
      throw httpError(502, err.code === "ETIMEDOUT" ? "upstream_timeout" : "upstream_unavailable");
    }
    const refused = refusal(upRes);
    if (refused) {
      upRes.resume();
      throw httpError(502, refused);
    }
    res.writeHead(upRes.statusCode, pickHeaders(upRes.headers));
    const entry = { res, deviceId: ctx.device.id };
    streams.add(entry);
    res.on("close", () => { streams.delete(entry); upRes.destroy(); });
    upRes.on("error", () => res.destroy());
    upRes.pipe(res);
  }

  async function enrol(req, res, ip) {
    if (req.method !== "POST") throw httpError(405, "method_not_allowed");
    const wait = limiter.take(`enrol:${ip}`, limits.enrol) || limiter.take("enrol:all", limits.enrolAll);
    if (wait) return send(res, 429, { error: "rate_limited" }, { "retry-after": String(wait) });
    let input;
    try {
      input = JSON.parse((await readBody(req, 4096)).toString());
    } catch (err) {
      throw err.status ? err : httpError(400, "invalid_json");
    }
    const made = redeemEnrolCode(dataDir, input && input.code, input && input.name, clock());
    if (!made) {
      audit("enrol.fail", { remote: ip });
      return send(res, 403, { error: "invalid_code" });
    }
    audit("enrol.ok", { remote: ip, device_id: made.device_id, role: made.role });
    return send(res, 201, made);
  }

  async function manage(req, res, ctx) {
    if (ctx.device.role !== "admin") throw httpError(403, "forbidden");
    const revoke = /^\/facade\/devices\/([0-9a-f]{16})\/revoke$/.exec(ctx.pathname);
    if (req.method === "GET" && ctx.pathname === "/facade/devices") return send(res, 200, { devices: listDevices(dataDir) });
    if (req.method === "POST" && ctx.pathname === "/facade/enrol-codes") {
      const text = (await readBody(req, 4096)).toString();
      let role = "normal";
      if (text) {
        try {
          role = JSON.parse(text).role ?? "normal";
        } catch {
          throw httpError(400, "invalid_json");
        }
      }
      if (!ROLES.includes(role)) throw httpError(400, "invalid_role");
      const made = createEnrolCode(dataDir, role, clock());
      audit("code.create", { device_id: ctx.device.id, role });
      return send(res, 201, made);
    }
    if (req.method === "POST" && revoke) {
      const done = revokeDevice(dataDir, revoke[1], clock());
      if (!done) throw httpError(404, "unknown_device");
      audit("revoke", { device_id: ctx.device.id, target: revoke[1] });
      return send(res, 200, done);
    }
    throw httpError(404, "not_found");
  }

  async function dispatch(req, res, ctx) {
    const ip = req.socket.remoteAddress;
    const q = req.url.indexOf("?");
    ctx.pathname = q < 0 ? req.url : req.url.slice(0, q);
    const query = q < 0 ? "" : req.url.slice(q + 1);
    if (ctx.pathname === "/facade/enrol") return enrol(req, res, ip);

    const bearer = /^Bearer (\S+)$/.exec(req.headers.authorization || "");
    const auth = authenticate(dataDir, bearer && bearer[1]);
    if (!auth.device) {
      const wait = limiter.take(`fail:${ip}`, limits.fail);
      if (wait) return send(res, 429, { error: "rate_limited" }, { "retry-after": String(wait) });
      audit("auth.fail", { remote: ip, reason: auth.reason, device_id: auth.deviceId });
      return send(res, 401, { error: "invalid_token" });
    }
    ctx.device = auth.device;
    ctx.remote = ip;

    const match = ctx.pathname.startsWith("/facade/") ? null : ROUTES.find((r) => r.method === req.method && r.re.test(ctx.pathname));
    const wait = limiter.take(`dev:${ctx.device.id}`, limits.device) || (match && match.kind === "write" ? limiter.take(`write:${ctx.device.id}`, limits.write) : 0);
    if (wait) return send(res, 429, { error: "rate_limited" }, { "retry-after": String(wait) });
    if (ctx.pathname.startsWith("/facade/")) return manage(req, res, ctx);

    if (!match) {
      throw ROUTES.some((r) => r.re.test(ctx.pathname)) ? httpError(405, "method_not_allowed") : httpError(404, "route_not_allowed");
    }
    ctx.route = match.name;
    const profile = match.re.exec(ctx.pathname)[1] || "default";
    ctx.upstreamKey = upstreamKeyFor(profile);
    if (!ctx.upstreamKey) throw httpError(502, "upstream_key_missing");
    if (match.kind === "write") return write(req, res, ctx);
    if (!/^[A-Za-z0-9_.~%+,=&:-]{0,512}$/.test(query)) throw httpError(400, "invalid_query");
    ctx.target = query ? `${ctx.pathname}?${query}` : ctx.pathname;
    return read(req, res, ctx);
  }

  const server = https.createServer({
    key: fs.readFileSync(path.join(dataDir, "tls", "server.key")),
    cert: fs.readFileSync(path.join(dataDir, "tls", "server.crt"), "utf8") + fs.readFileSync(path.join(dataDir, "tls", "ca.crt"), "utf8"),
    minVersion: "TLSv1.3",
  }, (req, res) => {
    const started = clock();
    const ctx = {};
    res.on("close", () => {
      if (!ctx.device) return;
      try {
        audit("request", {
          device_id: ctx.device.id,
          role: ctx.device.role,
          method: req.method,
          route: ctx.route,
          path: ctx.route ? ctx.pathname : undefined,
          status: res.statusCode,
          ms: clock() - started,
          remote: ctx.remote,
        });
      } catch {
        console.error("hermes-facade: audit write failed");
      }
    });
    dispatch(req, res, ctx).catch((err) => {
      if (res.headersSent) return res.destroy();
      if (err.status) return send(res, err.status, { error: err.error });
      return send(res, 500, { error: "internal_error" });
    });
  });
  server.headersTimeout = 15_000;
  server.requestTimeout = 30_000;
  server.on("tlsClientError", () => {});

  // revocation also cuts the event streams that a device holds open
  const sweeper = setInterval(() => {
    for (const s of streams) {
      const d = readDevice(dataDir, s.deviceId);
      if (!d || d.revoked_at) s.res.destroy();
    }
  }, cfg.sweepMs || 1000);
  sweeper.unref();
  purgeJournal(clock());
  const purger = setInterval(() => purgeJournal(clock()), 60 * 60 * 1000);
  purger.unref();

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(cfg.port, cfg.host, resolve);
  });
  return {
    port: server.address().port,
    close: () => new Promise((resolve) => {
      closed = true;
      clearInterval(sweeper);
      clearInterval(purger);
      server.close(() => setImmediate(resolve));
      server.closeAllConnections();
    }),
  };
}

// ---------------------------------------------------------------- CLI

const USAGE = `usage: hermes-facade.js <command>
  init-tls [--san DNS:name|IP:address]...   create the CA and the server certificate, print the pins
  enrol-code [admin|normal]                 print a one-time code valid ${ENROL_CODE_TTL_MS / 60000} minutes
  devices                                   list devices
  revoke <device-id>                        revoke one device
  serve                                     start the facade
  check-local <port>                        fail when the port answers outside the loopback
environment: FACADE_DATA, FACADE_UPSTREAM, FACADE_UPSTREAM_KEY or FACADE_UPSTREAM_KEYS,
             FACADE_LISTEN_HOST (127.0.0.1), FACADE_LISTEN_PORT (8643)`;

async function main(argv = process.argv.slice(2), env = process.env, out = console.log) {
  const [cmd, ...rest] = argv;
  if (!["check-local", "serve", "init-tls", "enrol-code", "devices", "revoke"].includes(cmd)) throw new Error(USAGE);
  if (cmd === "check-local") {
    const port = Number(rest[0]);
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("check-local needs a port");
    const hits = await findExposure(port);
    for (const a of hits) out(`exposed ${a}`);
    out(hits.length ? "check-local: FAIL, the port answers outside the loopback" : "check-local: ok, the port answers on the loopback only");
    return hits.length ? 1 : 0;
  }
  if (cmd === "serve") {
    const f = await startFacade(configFromEnv(env));
    out(`facade listening on port ${f.port}`);
    const stop = () => f.close().then(() => process.exit(0));
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
    return null;
  }
  if (!env.FACADE_DATA) throw new Error("FACADE_DATA is required");
  const dataDir = env.FACADE_DATA;
  if (cmd === "init-tls") {
    const sans = [];
    for (let i = 0; i < rest.length; i += 2) {
      if (rest[i] !== "--san" || !rest[i + 1]) throw new Error(USAGE);
      sans.push(rest[i + 1]);
    }
    const t = initTls(dataDir, { sans });
    out(`ca_sha256=${t.caFingerprint}`);
    out(`server_spki_sha256_base64=${t.serverPin}`);
    return 0;
  }
  if (cmd === "enrol-code") {
    const c = createEnrolCode(dataDir, rest[0] || "normal");
    out(`code=${c.code} role=${c.role} expires_at=${c.expires_at}`);
    appendAudit(dataDir, "code.create", { source: "cli", role: c.role });
    return 0;
  }
  if (cmd === "devices") {
    for (const d of listDevices(dataDir)) out(`${d.id} ${d.role} ${d.created_at} ${d.revoked_at ? `revoked ${d.revoked_at}` : "active"} ${d.name}`);
    return 0;
  }
  if (cmd === "revoke") {
    const d = revokeDevice(dataDir, rest[0]);
    if (!d) throw new Error("unknown device");
    out(`revoked ${d.id} at ${d.revoked_at}`);
    appendAudit(dataDir, "revoke", { source: "cli", target: d.id });
    return 0;
  }
  throw new Error(USAGE);
}

module.exports = {
  ENROL_CODE_TTL_MS,
  ROUTES,
  configFromEnv,
  createEnrolCode,
  findExposure,
  initTls,
  listDevices,
  main,
  pinnedTlsOptions,
  redeemEnrolCode,
  revokeDevice,
  spkiPin,
  startFacade,
};

if (require.main === module) {
  main().then((code) => { if (code !== null) process.exitCode = code; }, (err) => {
    console.error(`hermes-facade: ${err.message}`);
    process.exitCode = 2;
  });
}
