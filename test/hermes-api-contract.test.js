"use strict";
// Contract tests (HA-02): every route of docs/api/hermes-product.openapi.json is called through the
// facade with a fake upstream, and every answer has to be declared by the contract
// The fake upstream answers with the example of the contract, so these tests prove the facade side:
// the route list, the pass-through, the error shapes, the idempotency rules, the roles

const assert = require("node:assert/strict");
const { cpSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, utimesSync, writeFileSync } = require("node:fs");
const http = require("node:http");
const https = require("node:https");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const facade = require("../scripts/hermes-facade.js");
const { scanText } = require("../scripts/infra-guard-ci.js");

const API_DIR = join(__dirname, "..", "docs", "api");
const CONTRACT = JSON.parse(readFileSync(join(API_DIR, "hermes-product.openapi.json"), "utf8"));

const UP_KEY = "cle-de-test-0123456789";
const T0 = 1_800_000_000_000;
const SAMPLE = { profile: "hv-bot-a", run_id: "run_1", session_id: "api_1", device_id: "0123456789abcdef" };
const LOOSE = {
  device: { burst: 10_000, perSecond: 10_000 },
  write: { burst: 10_000, perSecond: 10_000 },
  fail: { burst: 10_000, perSecond: 10_000 },
};

const MASTER = mkdtempSync(join(tmpdir(), "hb-contract-ca-"));
const TLS = facade.initTls(MASTER);
process.on("exit", () => rmSync(MASTER, { recursive: true, force: true }));

// ---------------------------------------------------------------- the contract

const deref = (node) => (node && node.$ref ? deref(node.$ref.slice(2).split("/").reduce((o, k) => o[k], CONTRACT)) : node);

const OPS = {};
for (const [path, item] of Object.entries(CONTRACT.paths)) {
  for (const [method, op] of Object.entries(item)) OPS[op.operationId] = { ...op, method: method.toUpperCase(), path };
}
const PRODUCT = Object.values(OPS).filter((op) => op.path.startsWith("/p/{profile}/"));

const fill = (path, params = {}) => path.replace(/\{(\w+)\}/g, (_, k) => params[k] ?? SAMPLE[k]);
const needsKey = (op) => (op.parameters || []).some((p) => deref(p).name === "Idempotency-Key");
const successOf = (op) => {
  const [status, def] = Object.entries(op.responses).find(([s]) => s[0] === "2");
  const [type, media] = Object.entries(def.content)[0];
  return { status: Number(status), type, example: media.example, headers: def.headers || {} };
};

// the part of JSON Schema that the contract uses
function validate(schema, value, where) {
  if (schema.$ref) return validate(deref(schema), value, where);
  const is = {
    string: (v) => typeof v === "string",
    integer: Number.isInteger,
    number: (v) => typeof v === "number",
    boolean: (v) => typeof v === "boolean",
    array: Array.isArray,
    null: (v) => v === null,
    object: (v) => v !== null && typeof v === "object" && !Array.isArray(v),
  };
  if (schema.type) assert.ok([].concat(schema.type).some((t) => is[t](value)), `${where}: expected ${schema.type}, got ${JSON.stringify(value)}`);
  if (schema.enum) assert.ok(schema.enum.includes(value), `${where}: ${JSON.stringify(value)} is not in the contract`);
  if (schema.oneOf) {
    const fits = (s) => { try { validate(s, value, where); return true; } catch { return false; } };
    assert.ok(schema.oneOf.some(fits), `${where}: no schema of oneOf fits ${JSON.stringify(value)}`);
  }
  if (is.object(value)) {
    for (const k of schema.required || []) assert.ok(k in value, `${where}: ${k} is missing`);
    for (const [k, s] of Object.entries(schema.properties || {})) if (k in value) validate(s, value[k], `${where}.${k}`);
  }
  if (schema.items && Array.isArray(value)) value.forEach((v, i) => validate(schema.items, v, `${where}[${i}]`));
  return undefined;
}

// an answer is part of the contract when its status is declared for the operation and its JSON body fits the schema
function documented(id, res) {
  const responses = OPS[id].responses;
  const def = deref(responses[String(res.status)] || responses[`${String(res.status)[0]}XX`]);
  assert.ok(def, `${id}: status ${res.status} is not in the contract: ${res.text.slice(0, 120)}`);
  const media = (def.content || {})["application/json"];
  if (media && media.schema && String(res.headers["content-type"]).startsWith("application/json")) {
    assert.notEqual(res.json, undefined, `${id}: the body is not JSON`);
    validate(media.schema, res.json, id);
  }
  return res;
}

// ---------------------------------------------------------------- facade and fake upstream

function startUpstream(handler) {
  const calls = [];
  const sockets = new Set();
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      calls.push({ method: req.method, url: req.url, headers: req.headers, body: Buffer.concat(chunks).toString() });
      (handler || contractUpstream)(req, res);
    });
  });
  server.on("connection", (s) => { sockets.add(s); s.on("close", () => sockets.delete(s)); });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve({
    port: server.address().port,
    calls,
    close: () => new Promise((r) => { for (const s of sockets) s.destroy(); server.close(r); }),
  })));
}

// Hermes as the contract describes it: the example of the first success answer of the route
function contractUpstream(req, res) {
  const route = facade.ROUTES.find((r) => r.method === req.method && r.re.test(req.url.split("?")[0]));
  const { status, type, example } = successOf(OPS[route.name]);
  res.writeHead(status, { "content-type": type });
  res.end(typeof example === "string" ? example : JSON.stringify(example));
}

const replyJson = (status, body) => (req, res) => {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};

async function withFacade(opts, fn) {
  const dataDir = mkdtempSync(join(tmpdir(), "hb-contract-data-"));
  cpSync(join(MASTER, "tls"), join(dataDir, "tls"), { recursive: true });
  const upstream = await startUpstream(opts.upstreamHandler);
  const f = await facade.startFacade({
    dataDir,
    upstream: `http://127.0.0.1:${upstream.port}`,
    upstreamKey: UP_KEY,
    host: "127.0.0.1",
    port: 0,
    clock: () => T0,
    sweepMs: 1000,
    limits: LOOSE,
    ...opts.config,
  });
  const ctx = { dataDir, upstream, call: (o) => call(f.port, o), dev: null };
  try {
    await fn(ctx);
  } finally {
    await f.close();
    await upstream.close();
    rmSync(dataDir, { recursive: true, force: true });
  }
}

function call(port, { method = "GET", path = "/", headers = {}, body, token } = {}) {
  const h = { ...headers };
  if (token) h.authorization = `Bearer ${token}`;
  const payload = body === undefined ? undefined : (typeof body === "string" ? body : JSON.stringify(body));
  if (payload !== undefined && !h["content-type"]) h["content-type"] = "application/json";
  return new Promise((resolve, reject) => {
    const r = https.request({
      host: "127.0.0.1", port, method, path, headers: h, agent: false,
      ...facade.pinnedTlsOptions({ ca: TLS.caPem, pin: TLS.serverPin }),
    }, (res) => {
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
  const { code } = facade.createEnrolCode(ctx.dataDir, role, T0);
  const r = await send(ctx, "facade.enrol", { body: { code, name }, token: null });
  assert.equal(r.status, 201, r.text);
  return r.json;
}

// One call of an operation of the contract. The body, the path values and the key come from the
// contract examples unless a test sets them. key: null sends no Idempotency-Key
async function send(ctx, id, { token, body, key, params, headers } = {}) {
  const op = OPS[id];
  const h = { ...headers };
  const k = key === undefined && needsKey(op) ? `key-${id}` : key;
  if (k) h["idempotency-key"] = k;
  const media = op.requestBody && op.requestBody.content["application/json"];
  const res = await ctx.call({
    method: op.method,
    path: fill(op.path, params),
    token: token === undefined ? ctx.dev && ctx.dev.token : token,
    headers: h,
    body: body === undefined && media ? media.example : body,
  });
  return documented(id, res);
}

// ---------------------------------------------------------------- the contract and the facade list the same routes

test("1. the contract lists the routes of the facade allowlist, no more, no less", () => {
  assert.equal(CONTRACT.openapi.slice(0, 2), "3.");
  assert.deepEqual(PRODUCT.map((op) => op.operationId).sort(), facade.ROUTES.map((r) => r.name).sort());
  for (const op of PRODUCT) {
    const route = facade.ROUTES.find((r) => r.name === op.operationId);
    const concrete = fill(op.path);
    assert.equal(op.method, route.method, op.operationId);
    assert.equal(route.re.exec(concrete)?.[1], SAMPLE.profile, `${op.operationId}: ${concrete}`);
    assert.equal(needsKey(op), route.kind === "write", `${op.operationId}: Idempotency-Key is for writes only`);
  }
  // one addressing style: every product path has the profile prefix, the rest is the facade itself
  for (const op of Object.values(OPS)) assert.ok(op.path.startsWith("/p/{profile}/") || op.path.startsWith("/facade/"), op.path);
  // not replayable, so out of the contract
  assert.ok(!Object.keys(CONTRACT.paths).some((p) => p.includes("/chat/stream")));
  assert.equal(Object.keys(OPS).length, PRODUCT.length + 4, "the facade routes are enrol, devices, enrol-codes and revoke");
});

test("2. one bot is one named Hermes profile", () => {
  const mapping = CONTRACT.info["x-bot-profile-mapping"];
  assert.equal(mapping.rule, "one bot, one profile");
  assert.equal(mapping.path, "/p/{profile}");
  assert.match(deref(CONTRACT.components.parameters.Profile).description, /bot/i);
  assert.match(CONTRACT.info.description, /never (?:holds|sees) the Hermes/i, "clients never hold the Hermes key");
  for (const op of PRODUCT) assert.ok(op.parameters.some((p) => deref(p).name === "profile"), op.operationId);
});

test("3. the path parameters of the contract are the ones the facade accepts", async () => {
  await withFacade({}, async (ctx) => {
    ctx.dev = await enrol(ctx);
    const cases = [
      ["Profile", "health", "profile", ["a", "A_b-9", "a".repeat(64)], ["-bad", "a".repeat(65), "a.b", "a%2fb"]],
      ["RunId", "run.get", "run_id", ["a", "r_1-X", "a".repeat(128)], ["a".repeat(129), "a.b", "a%2fb"]],
      ["SessionId", "session.get", "session_id", ["a", "api_1-X", "a".repeat(128)], ["a".repeat(129), "a.b", "a%2fb"]],
    ];
    for (const [name, id, param, good, bad] of cases) {
      const pattern = new RegExp(deref(CONTRACT.components.parameters[name]).schema.pattern);
      for (const value of good) {
        assert.match(value, pattern);
        assert.equal((await send(ctx, id, { params: { [param]: value } })).status, 200, `${param}=${value}`);
      }
      for (const value of bad) {
        assert.doesNotMatch(value, pattern);
        const r = await ctx.call({ path: fill(OPS[id].path, { [param]: value }), token: ctx.dev.token });
        assert.deepEqual([r.status, r.json], [404, { error: "route_not_allowed" }], `${param}=${value}`);
      }
    }
  });
});

// ---------------------------------------------------------------- every route, through the facade

test("4. every route reaches Hermes with the Hermes key and returns the declared answer", async () => {
  await withFacade({}, async (ctx) => {
    ctx.dev = await enrol(ctx);
    for (const op of PRODUCT) {
      const before = ctx.upstream.calls.length;
      const r = await send(ctx, op.operationId);
      const want = successOf(op);
      assert.equal(r.status, want.status, op.operationId);
      assert.ok(r.headers["content-type"].startsWith(want.type), op.operationId);
      assert.deepEqual(typeof want.example === "string" ? r.text : r.json, want.example, op.operationId);
      assert.equal(ctx.upstream.calls.length, before + 1, `${op.operationId}: one call to Hermes`);
      const seen = ctx.upstream.calls[before];
      assert.equal(seen.method, op.method);
      assert.equal(seen.url, fill(op.path), "the profile prefix goes to Hermes as it is");
      assert.equal(seen.headers.authorization, `Bearer ${UP_KEY}`, "Hermes gets its own key");
      assert.ok(!JSON.stringify(seen.headers).includes(ctx.dev.token), "Hermes never sees the device token");
      if (needsKey(op)) assert.equal(seen.headers["idempotency-key"], `${ctx.dev.device_id}:key-${op.operationId}`);
    }
  });
});

test("5. every route refuses a request with no valid token", async () => {
  await withFacade({}, async (ctx) => {
    await enrol(ctx);
    for (const op of Object.values(OPS).filter((o) => o.operationId !== "facade.enrol")) {
      assert.deepEqual(op.security ?? CONTRACT.security, [{ deviceToken: [] }], op.operationId);
      for (const token of [null, "garbage", `${SAMPLE.device_id}.${"A".repeat(43)}`]) {
        const r = await send(ctx, op.operationId, { token });
        assert.deepEqual([r.status, r.json], [401, { error: "invalid_token" }], `${op.operationId} ${token}`);
      }
    }
    assert.equal(ctx.upstream.calls.length, 0, "nothing reaches Hermes");
    assert.deepEqual(OPS["facade.enrol"].security, [], "enrolment is the one route with no token");
  });
});

test("6. enrolment and the roles", async () => {
  await withFacade({}, async (ctx) => {
    const admin = await enrol(ctx, "admin", "admin");
    const user = await enrol(ctx, "normal", "user");
    assert.deepEqual([admin.role, user.role], ["admin", "normal"]);
    const bad = await send(ctx, "facade.enrol", { body: { code: "0000-0000-0000", name: "x" }, token: null });
    assert.deepEqual([bad.status, bad.json], [403, { error: "invalid_code" }]);

    for (const id of ["facade.devices.list", "facade.codes.create", "facade.devices.revoke"]) {
      const r = await send(ctx, id, { token: user.token, params: { device_id: admin.device_id } });
      assert.deepEqual([r.status, r.json], [403, { error: "forbidden" }], id);
    }
    const list = await send(ctx, "facade.devices.list", { token: admin.token });
    assert.deepEqual(list.json.devices.map((d) => d.role).sort(), ["admin", "normal"]);
    const code = await send(ctx, "facade.codes.create", { token: admin.token });
    assert.equal(code.status, 201);
    const revoked = await send(ctx, "facade.devices.revoke", { token: admin.token, params: { device_id: user.device_id } });
    assert.equal(revoked.status, 200);
    assert.ok(revoked.json.revoked_at);
    assert.equal((await send(ctx, "health", { token: user.token })).status, 401, "a revoked token is refused at once");
    const unknown = await send(ctx, "facade.devices.revoke", { token: admin.token, params: { device_id: "f".repeat(16) } });
    assert.deepEqual([unknown.status, unknown.json], [404, { error: "unknown_device" }]);
  });
});

// ---------------------------------------------------------------- idempotency

test("7. a write needs a key, a replay returns the first answer, another body is a 409", async () => {
  await withFacade({}, async (ctx) => {
    ctx.dev = await enrol(ctx);
    const run = OPS["run.create"];
    const replayHeader = Object.keys(successOf(run).headers).map((h) => h.toLowerCase());
    assert.ok(replayHeader.includes("idempotency-replayed"), "the contract names the replay header");

    const none = await send(ctx, "run.create", { key: null });
    assert.deepEqual([none.status, none.json], [400, { error: "idempotency_key_required" }]);
    const invalid = await send(ctx, "run.create", { key: "a b" });
    assert.deepEqual([invalid.status, invalid.json], [400, { error: "idempotency_key_invalid" }]);
    assert.equal(ctx.upstream.calls.length, 0);

    const first = await send(ctx, "run.create", { key: "k1" });
    const second = await send(ctx, "run.create", { key: "k1" });
    assert.equal(first.status, 202);
    assert.equal(first.headers["idempotency-replayed"], undefined);
    assert.equal(second.status, 202);
    assert.equal(second.headers["idempotency-replayed"], "true");
    assert.equal(second.text, first.text, "the replay carries the run id of the first answer");
    assert.equal(ctx.upstream.calls.length, 1);

    const conflict = await send(ctx, "run.create", { key: "k1", body: { input: "another body" } });
    assert.deepEqual([conflict.status, conflict.json], [409, { error: "idempotency_key_conflict" }]);

    // every other write is replayed the same way, session.create returns the same session
    const s1 = await send(ctx, "session.create", { key: "s1" });
    const s2 = await send(ctx, "session.create", { key: "s1" });
    assert.equal(s2.headers["idempotency-replayed"], "true");
    assert.equal(s2.json.session.id, s1.json.session.id);
    // the same key on another route is another write
    assert.equal((await send(ctx, "run.stop", { key: "k1" })).headers["idempotency-replayed"], undefined);
  });
});

test("8. a record with no body fingerprint answers 502 for any body, a record with one answers 409", async () => {
  await withFacade({}, async (ctx) => {
    ctx.dev = await enrol(ctx);
    assert.equal((await send(ctx, "run.create", { key: "k1" })).status, 202);
    const dir = join(ctx.dataDir, "idempotency");
    const file = join(dir, readdirSync(dir)[0]);
    assert.ok(JSON.parse(readFileSync(file, "utf8")).hash, "the record keeps the fingerprint");
    assert.equal((await send(ctx, "run.create", { key: "k1", body: { input: "other" } })).status, 409);

    // a record that lost its fingerprint cannot compare bodies
    for (const damaged of ["{}", "null", "", "{broken"]) {
      writeFileSync(file, damaged);
      utimesSync(file, new Date(T0), new Date(T0));
      for (const body of [undefined, { input: "other" }]) {
        const r = await send(ctx, "run.create", { key: "k1", body });
        assert.deepEqual([r.status, r.json], [502, { error: "write_outcome_unknown" }], `${JSON.stringify(damaged)} ${JSON.stringify(body)}`);
      }
    }
    assert.equal(ctx.upstream.calls.length, 1, "Hermes is not called again");
  });
});

test("9. a lost answer, an answer over 1 MiB or a Hermes 5xx leaves the outcome unknown, the key is not sent again", async () => {
  let mode = "drop";
  const upstreamHandler = (req, res) => {
    if (mode === "drop") return req.socket.destroy();
    if (mode === "huge") return replyJson(202, { run_id: "run_1", pad: "x".repeat(1024 * 1024) })(req, res);
    return replyJson(500, { error: "boom" })(req, res);
  };
  await withFacade({ upstreamHandler }, async (ctx) => {
    ctx.dev = await enrol(ctx);
    const lost = await send(ctx, "run.create", { key: "lost" });
    assert.deepEqual([lost.status, lost.json], [502, { error: "write_outcome_unknown" }]);
    const again = await send(ctx, "run.create", { key: "lost" });
    assert.deepEqual([again.status, again.json], [502, { error: "write_outcome_unknown" }]);
    assert.equal((await send(ctx, "run.create", { key: "lost", body: { input: "other" } })).status, 409, "the fingerprint is kept");
    assert.equal(ctx.upstream.calls.length, 1);

    mode = "5xx";
    const five = await send(ctx, "run.create", { key: "five" });
    assert.deepEqual([five.status, five.json], [500, { error: "boom" }], "the first answer is the one of Hermes");
    assert.equal((await send(ctx, "run.create", { key: "five" })).status, 502);
    assert.equal(ctx.upstream.calls.length, 2);

    // the facade reads at most 1 MiB of a buffered answer: the write may have run, so upstream_response_too_large is not a code of the contract
    mode = "huge";
    const huge = await send(ctx, "run.create", { key: "huge" });
    assert.deepEqual([huge.status, huge.json], [502, { error: "write_outcome_unknown" }]);
    assert.ok(!CONTRACT.components.schemas.FacadeError.properties.error.enum.includes("upstream_response_too_large"));
  });
});

test("10. a replay too large to keep is a 409, a full journal is a 503", async () => {
  const big = { run_id: "run_big", status: "started", pad: "x".repeat(20_000) };
  await withFacade({ upstreamHandler: replyJson(202, big), config: { idempotencyMax: 2 } }, async (ctx) => {
    ctx.dev = await enrol(ctx);
    assert.equal((await send(ctx, "run.create", { key: "k1" })).status, 202);
    const replay = await send(ctx, "run.create", { key: "k1" });
    assert.deepEqual([replay.status, replay.json], [409, { error: "idempotency_replay_unavailable" }]);
    assert.equal((await send(ctx, "run.create", { key: "k2" })).status, 202);
    const full = await send(ctx, "run.create", { key: "k3" });
    assert.deepEqual([full.status, full.json], [503, { error: "idempotency_journal_full" }]);
    assert.equal(ctx.upstream.calls.length, 2);
  });
});

// ---------------------------------------------------------------- error shapes

test("11. rate limit, wrong route, wrong method, bad query, body too large", async () => {
  await withFacade({ config: { maxBody: 64 } }, async (ctx) => {
    ctx.dev = await enrol(ctx);
    for (const [method, path] of [["POST", "/p/hv-bot-a/api/sessions/api_1/chat/stream"], ["GET", "/api/config"], ["GET", "/p/hv-bot-a/v1/runs/%2e%2e/x"]]) {
      const r = documented("run.get", await ctx.call({ method, path, token: ctx.dev.token, headers: { "idempotency-key": "k" } }));
      assert.deepEqual([r.status, r.json], [404, { error: "route_not_allowed" }], `${method} ${path}`);
    }
    const method = documented("run.get", await ctx.call({ method: "DELETE", path: "/p/hv-bot-a/v1/runs/run_1", token: ctx.dev.token }));
    assert.deepEqual([method.status, method.json], [405, { error: "method_not_allowed" }]);
    const query = documented("session.list", await ctx.call({ path: '/p/hv-bot-a/api/sessions?q="x"', token: ctx.dev.token }));
    assert.deepEqual([query.status, query.json], [400, { error: "invalid_query" }]);
    const large = await send(ctx, "run.create", { body: { input: "x".repeat(200) } });
    assert.deepEqual([large.status, large.json], [413, { error: "body_too_large" }]);
    assert.equal(ctx.upstream.calls.length, 0);
  });
  await withFacade({ config: { limits: { ...LOOSE, device: { burst: 2, perSecond: 0.001 } } } }, async (ctx) => {
    ctx.dev = await enrol(ctx);
    const throttled = [];
    for (let i = 0; i < 4; i += 1) throttled.push(await send(ctx, "health"));
    const limited = throttled.find((r) => r.status === 429);
    assert.deepEqual(limited.json, { error: "rate_limited" });
    assert.match(limited.headers["retry-after"], /^\d+$/);
    assert.ok(Object.keys(deref(OPS.health.responses["429"]).headers).includes("Retry-After"), "the contract names Retry-After");
  });
});

test("12. Hermes failures reach the device as 502 with no Hermes detail", async () => {
  for (const [handler, error] of [
    [(req, res) => req.socket.destroy(), "upstream_unavailable"],
    [replyJson(401, { error: "gateway_auth_failed" }), "upstream_rejected"],
    [(req, res) => { res.writeHead(302, { location: "http://login.example/start" }); res.end(); }, "upstream_redirect"],
  ]) {
    await withFacade({ upstreamHandler: handler }, async (ctx) => {
      ctx.dev = await enrol(ctx);
      const r = await send(ctx, "session.list");
      assert.deepEqual([r.status, r.json], [502, { error }]);
      assert.ok(!r.text.includes("gateway_auth_failed") && !r.text.includes("login.example"));
      assert.equal(r.headers.location, undefined);
    });
  }
  await withFacade({ config: { upstreamKey: undefined, upstreamKeys: { other: UP_KEY } } }, async (ctx) => {
    ctx.dev = await enrol(ctx);
    const r = await send(ctx, "health");
    assert.deepEqual([r.status, r.json], [502, { error: "upstream_key_missing" }]);
    assert.equal(ctx.upstream.calls.length, 0);
  });
});

test("13. a Hermes answer that is not a facade error passes through with its status", async () => {
  await withFacade({ upstreamHandler: replyJson(404, { error: { code: "run_not_found" } }) }, async (ctx) => {
    ctx.dev = await enrol(ctx);
    const r = await send(ctx, "run.get");
    assert.deepEqual([r.status, r.json], [404, { error: { code: "run_not_found" } }]);
  });
  await withFacade({ upstreamHandler: replyJson(429, { error: "slow down" }) }, async (ctx) => {
    ctx.dev = await enrol(ctx);
    const r = await send(ctx, "run.create", { key: "k1" });
    assert.equal(r.status, 429);
    assert.equal((await send(ctx, "run.create", { key: "k1" })).status, 429, "a 429 of Hermes does not keep the key");
    assert.equal(ctx.upstream.calls.length, 2);
  });
});

// ---------------------------------------------------------------- the files of docs/api

test("14. every error code of the contract exists in the facade, and the files hold no infrastructure detail", () => {
  const source = readFileSync(join(__dirname, "..", "scripts", "hermes-facade.js"), "utf8");
  for (const code of CONTRACT.components.schemas.FacadeError.properties.error.enum) {
    assert.ok(source.includes(`"${code}"`), `${code} is not in the facade`);
  }
  assert.ok(existsSync(join(API_DIR, "README.md")));
  for (const file of ["hermes-product.openapi.json", "README.md"]) {
    const text = readFileSync(join(API_DIR, file), "utf8");
    assert.deepEqual(scanText(file, text), []);
    assert.doesNotMatch(text, /[0-9a-f]{16}\.[A-Za-z0-9_-]{43}/, `${file}: a device token`);
    assert.doesNotMatch(text, /Bearer [A-Za-z0-9_-]{20,}/, `${file}: a bearer value`);
  }
});
