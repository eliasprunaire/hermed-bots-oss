"use strict";

const assert = require("node:assert/strict");
const { cpSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } = require("node:fs");
const http = require("node:http");
const https = require("node:https");
const net = require("node:net");
const { X509Certificate } = require("node:crypto");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const facade = require("../scripts/hermes-facade.js");

const UP_KEY = "cle-de-test-0123456789";
const T0 = 1_800_000_000_000;

// one CA and server certificate for the whole file, a second CA for the wrong-anchor case
const MASTER = mkdtempSync(join(tmpdir(), "hb-facade-ca-"));
const OTHER = mkdtempSync(join(tmpdir(), "hb-facade-other-"));
const TLS = facade.initTls(MASTER);
const OTHER_TLS = facade.initTls(OTHER);
process.on("exit", () => {
  rmSync(MASTER, { recursive: true, force: true });
  rmSync(OTHER, { recursive: true, force: true });
});

function startUpstream(handler) {
  const calls = [];
  const sockets = new Set();
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const call = { method: req.method, url: req.url, headers: req.headers, body: Buffer.concat(chunks).toString() };
      calls.push(call);
      (handler || defaultUpstream)(req, res, call, calls);
    });
  });
  server.on("connection", (s) => { sockets.add(s); s.on("close", () => sockets.delete(s)); });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve({
    port: server.address().port,
    calls,
    close: () => new Promise((r) => { for (const s of sockets) s.destroy(); server.close(r); }),
  })));
}

function defaultUpstream(req, res) {
  res.writeHead(req.method === "POST" ? 202 : 200, {
    "content-type": "application/json",
    server: "uvicorn",
    "set-cookie": "hermes_session=abc",
    "www-authenticate": "Bearer realm=hermes",
    "x-powered-by": "hermes-internal",
  });
  res.end(JSON.stringify({ run_id: "run_1", status: "started" }));
}

async function withFacade(opts, fn) {
  const dataDir = mkdtempSync(join(tmpdir(), "hb-facade-data-"));
  cpSync(join(MASTER, "tls"), join(dataDir, "tls"), { recursive: true });
  const upstream = opts.upstream || await startUpstream(opts.upstreamHandler);
  let now = T0;
  const f = await facade.startFacade({
    dataDir,
    upstream: `http://127.0.0.1:${upstream.port}`,
    upstreamKey: UP_KEY,
    host: "127.0.0.1",
    port: 0,
    clock: () => now,
    sweepMs: 20,
    ...opts.config,
  });
  const ctx = {
    dataDir,
    upstream,
    port: f.port,
    now: () => now,
    advance: (ms) => { now += ms; },
    call: (o) => call(f.port, o),
  };
  try {
    await fn(ctx);
  } finally {
    await f.close();
    if (!opts.upstream) await upstream.close();
    rmSync(dataDir, { recursive: true, force: true });
  }
}

function tlsOptions(tlsInfo = TLS) {
  return facade.pinnedTlsOptions({ ca: tlsInfo.caPem, pin: tlsInfo.serverPin });
}

function call(port, { method = "GET", path = "/", headers = {}, body, token, tlsOpts } = {}) {
  const h = { ...headers };
  if (token) h.authorization = `Bearer ${token}`;
  const payload = body === undefined ? undefined : (typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body));
  if (payload !== undefined && !h["content-type"]) h["content-type"] = "application/json";
  return new Promise((resolve, reject) => {
    const r = https.request({ host: "127.0.0.1", port, method, path, headers: h, agent: false, ...(tlsOpts || tlsOptions()) }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString();
        let json;
        try { json = JSON.parse(text); } catch { json = undefined; }
        resolve({ status: res.statusCode, headers: res.headers, text, json });
      });
    });
    r.on("error", reject);
    r.end(payload);
  });
}

async function enrol(ctx, role = "normal", name = "phone") {
  const { code } = facade.createEnrolCode(ctx.dataDir, role, ctx.now());
  const r = await ctx.call({ method: "POST", path: "/facade/enrol", body: { code, name } });
  assert.equal(r.status, 201, r.text);
  return r.json;
}

const writeHeaders = (key) => ({ "idempotency-key": key });

test("1. no access without a valid token", async () => {
  await withFacade({ config: { limits: { fail: { burst: 100, perSecond: 100 } } } }, async (ctx) => {
    const good = await enrol(ctx);
    const [id, secret] = good.token.split(".");
    const bad = [
      undefined,
      "Basic Zm9vOmJhcg==",
      "Bearer ",
      "Bearer garbage",
      `Bearer ${id}.${"A".repeat(43)}`,
      `Bearer ../../x.${secret}`,
      `Bearer ${id}.${secret}x`,
      `Bearer ${id}`,
    ];
    for (const authorization of bad) {
      const r = await ctx.call({ path: "/p/hv-bot-a/v1/capabilities", headers: authorization ? { authorization } : {} });
      assert.equal(r.status, 401, String(authorization));
      assert.deepEqual(r.json, { error: "invalid_token" });
    }
    // an unknown route gives the same answer: no route enumeration without a token
    assert.equal((await ctx.call({ path: "/api/config" })).status, 401);
    assert.equal((await ctx.call({ path: "/facade/devices" })).status, 401);
    assert.equal(ctx.upstream.calls.length, 0);
    assert.equal((await ctx.call({ path: "/v1/capabilities", token: good.token })).status, 200);
    assert.equal(ctx.upstream.calls.length, 1);
  });
});

test("1b. a damaged device file is a 401, not a crash", async () => {
  await withFacade({}, async (ctx) => {
    const dev = await enrol(ctx);
    const file = join(ctx.dataDir, "devices", `${dev.device_id}.json`);
    for (const damaged of [JSON.stringify({ id: dev.device_id, role: "admin" }), "{broken", ""]) {
      writeFileSync(file, damaged);
      assert.equal((await ctx.call({ path: "/v1/capabilities", token: dev.token })).status, 401);
    }
    assert.equal(ctx.upstream.calls.length, 0);
  });
});

test("2. a revoked token is refused at once, also through the file the CLI writes", async () => {
  await withFacade({}, async (ctx) => {
    const admin = await enrol(ctx, "admin", "admin-phone");
    const a = await enrol(ctx, "normal", "a");
    const b = await enrol(ctx, "normal", "b");
    assert.equal((await ctx.call({ path: "/v1/capabilities", token: a.token })).status, 200);

    const rev = await ctx.call({ method: "POST", path: `/facade/devices/${a.device_id}/revoke`, token: admin.token });
    assert.equal(rev.status, 200);
    assert.equal((await ctx.call({ path: "/v1/capabilities", token: a.token })).status, 401);
    assert.equal((await ctx.call({ method: "POST", path: `/facade/devices/${a.device_id}/revoke`, token: admin.token })).status, 200, "revoke is idempotent");
    assert.equal((await ctx.call({ path: "/v1/capabilities", token: b.token })).status, 200, "other devices keep working");

    // CLI path: another process rewrites the device file, no restart, no signal
    facade.revokeDevice(ctx.dataDir, b.device_id, ctx.now());
    assert.equal((await ctx.call({ path: "/v1/capabilities", token: b.token })).status, 401);
  });
});

test("2b. revocation cuts an open event stream", async () => {
  const upstreamHandler = (req, res) => {
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(": open\n\n");
  };
  await withFacade({ upstreamHandler }, async (ctx) => {
    const dev = await enrol(ctx);
    const cut = new Promise((resolve, reject) => {
      const r = https.request({ host: "127.0.0.1", port: ctx.port, path: "/p/hv-bot-a/v1/runs/run_1/events", headers: { authorization: `Bearer ${dev.token}` }, agent: false, ...tlsOptions() }, (res) => {
        res.on("data", () => {});
        res.on("close", resolve);
        res.on("error", resolve);
      });
      r.on("error", resolve);
      r.setTimeout(5000, () => reject(new Error("stream was not cut")));
      r.end();
    });
    await new Promise((r) => setTimeout(r, 100));
    facade.revokeDevice(ctx.dataDir, dev.device_id, ctx.now());
    await cut;
  });
});

test("3. TLS is validated by the pinned anchor", async () => {
  await withFacade({}, async (ctx) => {
    const dev = await enrol(ctx);
    assert.equal((await ctx.call({ path: "/v1/capabilities", token: dev.token })).status, 200);

    // another CA as the only anchor
    await assert.rejects(ctx.call({ path: "/v1/capabilities", token: dev.token, tlsOpts: tlsOptions(OTHER_TLS) }), /certificate|self.signed|issuer/i);
    // right anchor, wrong pin on the server certificate
    await assert.rejects(ctx.call({ path: "/v1/capabilities", token: dev.token, tlsOpts: facade.pinnedTlsOptions({ ca: TLS.caPem, pin: OTHER_TLS.serverPin }) }), /pin/i);
    // system roots only
    await assert.rejects(ctx.call({ path: "/v1/capabilities", token: dev.token, tlsOpts: { minVersion: "TLSv1.3" } }), /certificate|self.signed|issuer/i);
    // TLS 1.2 client
    await assert.rejects(ctx.call({ path: "/v1/capabilities", token: dev.token, tlsOpts: { ...tlsOptions(), minVersion: "TLSv1.2", maxVersion: "TLSv1.2" } }), /protocol|alert|version/i);
    assert.equal(ctx.upstream.calls.length, 1);
  });
  // the pin is the SPKI hash and survives a new certificate on the same key
  const again = facade.initTls(MASTER);
  assert.equal(again.serverPin, TLS.serverPin);
  assert.equal(again.caFingerprint, TLS.caFingerprint);
  const leaf = new X509Certificate(readFileSync(join(MASTER, "tls", "server.crt")));
  assert.ok(leaf.checkIP("127.0.0.1"));
  assert.ok(leaf.checkHost("localhost"));
  assert.ok(leaf.verify(new X509Certificate(TLS.caPem).publicKey));
});

test("4. the device never sees Hermes in HTTP", async () => {
  await withFacade({}, async (ctx) => {
    const dev = await enrol(ctx);
    // plain HTTP on the facade port gets no HTTP answer
    await assert.rejects(new Promise((resolve, reject) => {
      const r = http.request({ host: "127.0.0.1", port: ctx.port, path: "/v1/capabilities", agent: false, headers: { authorization: `Bearer ${dev.token}` } }, resolve);
      r.on("error", reject);
      r.setTimeout(3000, () => reject(new Error("no answer")));
      r.end();
    }));
    assert.equal(ctx.upstream.calls.length, 0);

    const r = await ctx.call({
      path: "/p/hv-bot-a/v1/runs/run_1",
      token: dev.token,
      headers: { "x-hermes-session-token": "dashboard-secret", cookie: "hermes_session=mine", "x-forwarded-for": "1.2.3.4" },
    });
    assert.equal(r.status, 200);
    const sent = ctx.upstream.calls[0].headers;
    assert.equal(sent.authorization, `Bearer ${UP_KEY}`);
    assert.equal(sent["x-hermes-session-token"], undefined);
    assert.equal(sent.cookie, undefined);
    assert.equal(sent["x-forwarded-for"], undefined);
    for (const h of ["server", "set-cookie", "www-authenticate", "x-powered-by"]) assert.equal(r.headers[h], undefined, h);
    assert.ok(!JSON.stringify(r.headers).includes(UP_KEY) && !r.text.includes(UP_KEY));
  });
  // the upstream has to be on the host loopback and plain HTTP
  const base = { dataDir: MASTER, upstreamKey: UP_KEY, host: "127.0.0.1", port: 0 };
  for (const upstream of ["http://203.0.113.7:8642", "http://0.0.0.0:8642", "http://example.invalid:8642", "https://127.0.0.1:8642", "http://user@127.0.0.1:8642", "http://127.0.0.1:8642/x", "not a url"]) {
    await assert.rejects(facade.startFacade({ ...base, upstream }).then((f) => f.close()), /FACADE_UPSTREAM/, upstream);
  }
});

test("4b. upstream answers that would leak or confuse are replaced", async () => {
  const cases = [
    [(req, res) => { res.writeHead(302, { location: "http://127.0.0.1:8642/login" }); res.end(); }, 502, "upstream_redirect"],
    [(req, res) => { res.writeHead(401, { "www-authenticate": "Bearer" }); res.end("{}"); }, 502, "upstream_rejected"],
  ];
  for (const [upstreamHandler, status, error] of cases) {
    await withFacade({ upstreamHandler }, async (ctx) => {
      const dev = await enrol(ctx);
      const r = await ctx.call({ path: "/v1/capabilities", token: dev.token });
      assert.equal(r.status, status);
      assert.deepEqual(r.json, { error });
      assert.equal(r.headers.location, undefined);
      assert.equal(r.headers["www-authenticate"], undefined);
    });
  }
  // upstream down
  const dead = await startUpstream();
  const port = dead.port;
  await dead.close();
  await withFacade({ upstream: { port, calls: [] } }, async (ctx) => {
    const dev = await enrol(ctx);
    const r = await ctx.call({ path: "/v1/capabilities", token: dev.token });
    assert.equal(r.status, 502);
    assert.deepEqual(r.json, { error: "upstream_unavailable" });
  });
});

test("4c. one upstream key per profile, fail closed when none applies", async () => {
  await withFacade({ config: { upstreamKey: undefined, upstreamKeys: { "hv-bot-a": "cle-de-test-profile-a" } } }, async (ctx) => {
    const dev = await enrol(ctx);
    assert.equal((await ctx.call({ path: "/p/hv-bot-a/v1/capabilities", token: dev.token })).status, 200);
    assert.equal(ctx.upstream.calls[0].headers.authorization, "Bearer cle-de-test-profile-a");
    const r = await ctx.call({ path: "/p/hv-bot-b/v1/capabilities", token: dev.token });
    assert.equal(r.status, 502);
    assert.deepEqual(r.json, { error: "upstream_key_missing" });
    assert.equal(ctx.upstream.calls.length, 1);
  });
});

test("4d. the dashboard port is checked for exposure outside the loopback", async () => {
  const open = net.createServer().listen(0, "0.0.0.0");
  const closed = net.createServer().listen(0, "127.0.0.1");
  await Promise.all([new Promise((r) => open.once("listening", r)), new Promise((r) => closed.once("listening", r))]);
  try {
    assert.deepEqual(await facade.findExposure(open.address().port, { addresses: ["127.0.0.1"] }), ["127.0.0.1"]);
    assert.deepEqual(await facade.findExposure(closed.address().port, { addresses: ["127.0.0.2"], timeoutMs: 300 }), []);
  } finally {
    open.close();
    closed.close();
  }
});

test("5. an expired, reused or unknown enrolment code is refused", async () => {
  assert.equal(facade.ENROL_CODE_TTL_MS, 5 * 60 * 1000);
  await withFacade({ config: { limits: { enrol: { burst: 100, perSecond: 100 } } } }, async (ctx) => {
    const enrolWith = (code) => ctx.call({ method: "POST", path: "/facade/enrol", body: { code, name: "x" } });

    const used = facade.createEnrolCode(ctx.dataDir, "normal", ctx.now());
    assert.equal((await enrolWith(used.code)).status, 201);
    const reuse = await enrolWith(used.code);
    assert.equal(reuse.status, 403);
    assert.deepEqual(reuse.json, { error: "invalid_code" });

    const late = facade.createEnrolCode(ctx.dataDir, "normal", ctx.now());
    ctx.advance(facade.ENROL_CODE_TTL_MS);
    const expired = await enrolWith(late.code);
    assert.equal(expired.status, 403);
    assert.deepEqual(expired.json, reuse.json, "expired, used and unknown look the same");
    assert.deepEqual((await enrolWith("ABCD-EFGH-JKMN")).json, reuse.json);

    const edge = facade.createEnrolCode(ctx.dataDir, "normal", ctx.now());
    ctx.advance(facade.ENROL_CODE_TTL_MS - 1);
    assert.equal((await enrolWith(edge.code)).status, 201, "valid until the last millisecond");

    // the code is typed by a person: case, dashes and look-alike letters do not matter
    const typed = facade.createEnrolCode(ctx.dataDir, "normal", ctx.now());
    assert.equal((await enrolWith(typed.code.toLowerCase().replaceAll("-", " "))).status, 201);

    // two clients redeem the same code at the same time: one wins
    const race = facade.createEnrolCode(ctx.dataDir, "normal", ctx.now());
    const results = await Promise.all([1, 2, 3, 4].map(() => enrolWith(race.code)));
    assert.deepEqual(results.map((r) => r.status).sort(), [201, 403, 403, 403]);
  });
});

test("5b. codes and tokens are stored hashed, with the role of the code", async () => {
  await withFacade({}, async (ctx) => {
    const { code } = facade.createEnrolCode(ctx.dataDir, "admin", ctx.now());
    const raw = code.replaceAll("-", "");
    const dev = await enrol(ctx, "admin", "tablet");
    assert.equal(dev.role, "admin");
    const secret = dev.token.split(".")[1];
    for (const dir of ["codes", "devices"]) {
      for (const f of readdirSync(join(ctx.dataDir, dir))) {
        const text = readFileSync(join(ctx.dataDir, dir, f), "utf8");
        assert.ok(!text.includes(raw) && !text.includes(secret) && !f.includes(raw), `${dir}/${f}`);
      }
    }
    const listed = facade.listDevices(ctx.dataDir).find((d) => d.id === dev.device_id);
    assert.deepEqual([listed.name, listed.role], ["tablet", "admin"]);
    assert.throws(() => facade.createEnrolCode(ctx.dataDir, "root", ctx.now()), /role/);
  });
});

test("5c. the enrolment endpoint is rate limited", async () => {
  await withFacade({}, async (ctx) => {
    let last;
    for (let i = 0; i < 6; i++) last = await ctx.call({ method: "POST", path: "/facade/enrol", body: { code: "AAAA-AAAA-AAAA" } });
    assert.equal(last.status, 429);
    assert.ok(Number(last.headers["retry-after"]) >= 1);
    ctx.advance(60_000);
    assert.equal((await ctx.call({ method: "POST", path: "/facade/enrol", body: { code: "AAAA-AAAA-AAAA" } })).status, 403);
    assert.equal((await ctx.call({ method: "POST", path: "/facade/enrol", body: "{nope" })).status, 400);
    assert.equal((await ctx.call({ method: "GET", path: "/facade/enrol" })).status, 405);
  });
});

test("6. writes are idempotent", async () => {
  await withFacade({ config: { limits: { write: { burst: 100, perSecond: 100 } } } }, async (ctx) => {
    const dev = await enrol(ctx);
    const post = (key, body, path = "/p/hv-bot-a/v1/runs", token = dev.token) =>
      ctx.call({ method: "POST", path, token, body, headers: key === undefined ? {} : writeHeaders(key) });

    assert.equal((await post(undefined, { input: "x" })).status, 400);
    assert.equal((await post("a b", { input: "x" })).status, 400);
    assert.equal((await post("k".repeat(129), { input: "x" })).status, 400);
    assert.equal(ctx.upstream.calls.length, 0);

    const first = await post("k1", { input: "bonjour" });
    const second = await post("k1", { input: "bonjour" });
    assert.equal(first.status, 202);
    assert.equal(first.headers["idempotency-replayed"], undefined);
    assert.equal(second.status, 202);
    assert.equal(second.headers["idempotency-replayed"], "true");
    assert.equal(second.text, first.text);
    assert.equal(ctx.upstream.calls.length, 1, "one upstream call for two sends");
    assert.equal(ctx.upstream.calls[0].headers["idempotency-key"], `${dev.device_id}:k1`);
    assert.equal(ctx.upstream.calls[0].url, "/p/hv-bot-a/v1/runs");

    const conflict = await post("k1", { input: "autre" });
    assert.equal(conflict.status, 409);
    assert.deepEqual(conflict.json, { error: "idempotency_key_conflict" });
    assert.equal(ctx.upstream.calls.length, 1);

    // same key on another device or another route is a different write
    const other = await enrol(ctx, "normal", "other");
    assert.equal((await post("k1", { input: "bonjour" }, "/p/hv-bot-a/v1/runs", other.token)).status, 202);
    assert.equal((await post("k1", {}, "/p/hv-bot-a/v1/runs/run_1/stop")).status, 202);
    assert.equal(ctx.upstream.calls.length, 3);

    // approval and stop have no key on the Hermes side: the facade deduplicates them
    for (const route of ["approval", "stop"]) {
      const path = `/p/hv-bot-a/v1/runs/run_9/${route}`;
      await post(`k-${route}`, { request_id: "r1", choice: "deny" }, path);
      const again = await post(`k-${route}`, { request_id: "r1", choice: "deny" }, path);
      assert.equal(again.headers["idempotency-replayed"], "true");
    }
    assert.equal(ctx.upstream.calls.length, 5);

    // concurrent sends of one write reach Hermes once
    const before = ctx.upstream.calls.length;
    const burst = await Promise.all([1, 2, 3, 4, 5].map(() => post("k-burst", { input: "x" })));
    assert.equal(new Set(burst.map((r) => r.text)).size, 1);
    assert.equal(ctx.upstream.calls.length, before + 1);

    // the memory of a key ends after 24 hours, like the Hermes one
    ctx.advance(24 * 60 * 60 * 1000);
    assert.equal((await post("k1", { input: "bonjour" })).headers["idempotency-replayed"], undefined);
    assert.equal(ctx.upstream.calls.length, before + 2);
  });
});

test("6b. an upstream failure is not remembered, a body over the limit is refused", async () => {
  let n = 0;
  const upstreamHandler = (req, res) => {
    n++;
    res.writeHead(n === 1 ? 500 : 202, { "content-type": "application/json" });
    res.end("{}");
  };
  await withFacade({ upstreamHandler, config: { maxBody: 1024 } }, async (ctx) => {
    const dev = await enrol(ctx);
    const send = (body, key = "k") => ctx.call({ method: "POST", path: "/v1/runs", token: dev.token, body, headers: writeHeaders(key) });
    assert.equal((await send({ input: "x" })).status, 500);
    const retry = await send({ input: "x" });
    assert.equal(retry.status, 202);
    assert.equal(retry.headers["idempotency-replayed"], undefined);
    assert.equal((await send("x".repeat(2048), "big")).status, 413);
    assert.equal(n, 2);
  });
});

test("7. routes outside the allowlist never reach Hermes", async () => {
  await withFacade({}, async (ctx) => {
    const dev = await enrol(ctx);
    const probes = [
      ["GET", "/api/config"],
      ["GET", "/api/env"],
      ["GET", "/auth/native/authorize"],
      ["GET", "/p/hv-bot-a/api/config"],
      ["GET", "/p/hv-bot-a/v1/runs/../../api/env"],
      ["GET", "/p/hv-bot-a/v1/runs/%2e%2e/x"],
      ["GET", "/p/hv-bot-a//v1/runs/run_1"],
      ["GET", "/v1/runs/run_1/events/extra"],
      ["POST", "/api/sessions/run_1/chat/stream"],
    ];
    for (const [method, path] of probes) {
      const r = await ctx.call({ method, path, token: dev.token, headers: writeHeaders("k") });
      assert.equal(r.status, 404, `${method} ${path}`);
      assert.deepEqual(r.json, { error: "route_not_allowed" });
    }
    const wrongMethod = await ctx.call({ method: "DELETE", path: "/v1/runs/run_1", token: dev.token });
    assert.equal(wrongMethod.status, 405);
    assert.equal((await ctx.call({ path: '/api/sessions?q="x"', token: dev.token })).status, 400);
    assert.equal(ctx.upstream.calls.length, 0);

    // the query of a read is forwarded, the query of a write is dropped
    assert.equal((await ctx.call({ path: "/p/hv-bot-a/api/sessions?limit=3&offset=0", token: dev.token })).status, 200);
    assert.equal((await ctx.call({ method: "POST", path: "/v1/runs?profile=other", token: dev.token, body: {}, headers: writeHeaders("q") })).status, 202);
    assert.deepEqual(ctx.upstream.calls.map((c) => c.url), ["/p/hv-bot-a/api/sessions?limit=3&offset=0", "/v1/runs"]);
  });
});

test("7b. an event stream reaches the device as it is produced", async () => {
  let release;
  const gate = new Promise((r) => { release = r; });
  const upstreamHandler = async (req, res) => {
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write("id: 0\ndata: {\"event\":\"message.delta\"}\n\n");
    await gate;
    res.end("id: 1\ndata: {\"event\":\"run.completed\"}\n\n");
  };
  await withFacade({ upstreamHandler }, async (ctx) => {
    const dev = await enrol(ctx);
    await new Promise((resolve, reject) => {
      const r = https.request({ host: "127.0.0.1", port: ctx.port, path: "/p/hv-bot-a/v1/runs/run_1/events", headers: { authorization: `Bearer ${dev.token}`, "last-event-id": "4" }, agent: false, ...tlsOptions() }, (res) => {
        let text = "";
        res.on("data", (c) => {
          text += c;
          if (text.includes("message.delta") && !text.includes("run.completed")) release();
        });
        res.on("end", () => { assert.match(text, /run\.completed/); resolve(); });
      });
      r.on("error", reject);
      r.end();
    });
    assert.equal(ctx.upstream.calls[0].headers["last-event-id"], "4");
  });
});

test("8. roles: only an admin manages devices and codes", async () => {
  await withFacade({}, async (ctx) => {
    const admin = await enrol(ctx, "admin", "admin");
    const user = await enrol(ctx, "normal", "user");
    for (const [method, path] of [["GET", "/facade/devices"], ["POST", "/facade/enrol-codes"], ["POST", `/facade/devices/${admin.device_id}/revoke`]]) {
      assert.equal((await ctx.call({ method, path, token: user.token })).status, 403, path);
    }
    assert.equal((await ctx.call({ path: "/v1/capabilities", token: user.token })).status, 200, "a normal device uses Hermes");

    const list = await ctx.call({ path: "/facade/devices", token: admin.token });
    assert.deepEqual(list.json.devices.map((d) => d.role).sort(), ["admin", "normal"]);
    assert.ok(list.json.devices.every((d) => !("token_sha256" in d)));

    const made = await ctx.call({ method: "POST", path: "/facade/enrol-codes", token: admin.token, body: { role: "normal" } });
    assert.equal(made.status, 201);
    assert.equal(made.json.role, "normal");
    assert.equal(made.json.expires_at, new Date(ctx.now() + facade.ENROL_CODE_TTL_MS).toISOString());
    assert.equal((await ctx.call({ method: "POST", path: "/facade/enrol-codes", token: admin.token, body: { role: "root" } })).status, 400);
    assert.equal((await ctx.call({ method: "POST", path: "/facade/devices/nope/revoke", token: admin.token })).status, 404);
    assert.equal((await ctx.call({ method: "POST", path: `/facade/devices/${"0".repeat(16)}/revoke`, token: admin.token })).status, 404);
  });
});

test("9. rate limit per device and per failing address", async () => {
  await withFacade({ config: { limits: { device: { burst: 3, perSecond: 1 }, fail: { burst: 2, perSecond: 0.1 } } } }, async (ctx) => {
    const dev = await enrol(ctx);
    const get = () => ctx.call({ path: "/v1/capabilities", token: dev.token });
    for (let i = 0; i < 3; i++) assert.equal((await get()).status, 200);
    const limited = await get();
    assert.equal(limited.status, 429);
    assert.equal(limited.headers["retry-after"], "1");
    ctx.advance(1000);
    assert.equal((await get()).status, 200);

    // failures drain their own bucket and never lock out a valid token
    const bad = () => ctx.call({ path: "/v1/capabilities", token: "garbage" });
    assert.equal((await bad()).status, 401);
    assert.equal((await bad()).status, 401);
    assert.equal((await bad()).status, 429);
    for (let i = 0; i < 20; i++) await bad();
    const audit = readFileSync(join(ctx.dataDir, "audit.log"), "utf8");
    assert.equal(audit.split("\n").filter((l) => l.includes('"auth.fail"')).length, 2, "a flood of bad tokens does not fill the audit");
    assert.ok(!audit.includes("limited"));
    ctx.advance(5000);
    assert.equal((await get()).status, 200);
  });
});

test("10. the audit is UTC, complete, and holds no secret", async () => {
  await withFacade({}, async (ctx) => {
    const admin = await enrol(ctx, "admin", "admin");
    const { code } = facade.createEnrolCode(ctx.dataDir, "normal", ctx.now());
    const user = await ctx.call({ method: "POST", path: "/facade/enrol", body: { code, name: "user" } });
    await ctx.call({ method: "POST", path: "/p/hv-bot-a/v1/runs/run_1/stop", token: user.json.token, headers: writeHeaders("a1"), body: {} });
    await ctx.call({ path: "/v1/capabilities", token: "garbage" });
    await ctx.call({ method: "POST", path: `/facade/devices/${user.json.device_id}/revoke`, token: admin.token });
    await ctx.call({ path: "/v1/capabilities", token: user.json.token });

    const text = readFileSync(join(ctx.dataDir, "audit.log"), "utf8");
    const lines = text.trim().split("\n").map((l) => JSON.parse(l));
    for (const l of lines) assert.match(l.ts, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
    const events = lines.map((l) => l.event);
    for (const e of ["enrol.ok", "auth.fail", "request", "revoke"]) assert.ok(events.includes(e), e);
    const stop = lines.find((l) => l.event === "request" && l.route === "run.stop");
    assert.equal(stop.device_id, user.json.device_id);
    assert.equal(stop.status, 202);
    assert.equal(stop.path, "/p/hv-bot-a/v1/runs/run_1/stop");
    assert.ok(lines.some((l) => l.event === "auth.fail" && l.reason === "malformed"));
    assert.ok(lines.some((l) => l.event === "auth.fail" && l.reason === "revoked" && l.device_id === user.json.device_id));
    for (const secret of [code.replaceAll("-", ""), admin.token.split(".")[1], user.json.token.split(".")[1], UP_KEY, "garbage"]) {
      assert.ok(!text.includes(secret), "secret in audit");
    }
  });
});

test("11. configuration comes from the environment and fails closed", () => {
  const ok = { FACADE_DATA: "/data", FACADE_UPSTREAM: "http://127.0.0.1:8642", FACADE_UPSTREAM_KEY: UP_KEY };
  const cfg = facade.configFromEnv(ok);
  assert.equal(cfg.host, "127.0.0.1");
  assert.equal(cfg.port, 8643);
  assert.equal(cfg.upstreamKey, UP_KEY);
  assert.deepEqual(facade.configFromEnv({ ...ok, FACADE_UPSTREAM_KEYS: '{"a":"cle-de-test-a"}' }).upstreamKeys, { a: "cle-de-test-a" });
  assert.throws(() => facade.configFromEnv({ ...ok, FACADE_DATA: "" }), /FACADE_DATA/);
  assert.throws(() => facade.configFromEnv({ ...ok, FACADE_UPSTREAM: "" }), /FACADE_UPSTREAM/);
  assert.throws(() => facade.configFromEnv({ ...ok, FACADE_UPSTREAM_KEYS: "[1]" }), /FACADE_UPSTREAM_KEYS/);
  assert.throws(() => facade.configFromEnv({ ...ok, FACADE_LISTEN_PORT: "99999" }), /FACADE_LISTEN_PORT/);
});
