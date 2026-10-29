"use strict";

const fs = require("node:fs");
const net = require("node:net");
const path = require("node:path");

const ENROLLMENT_TTL_MS = 5 * 60 * 1000;
const IDEMPOTENCY_TTL_MS = 24 * 60 * 60 * 1000;
const MAX_BODY_BYTES = 4096;
const MAX_WS_MESSAGE_BYTES = 1024 * 1024;
const MAX_WS_FRAGMENTS = 64;
const MIN_SECRET_LENGTH = 16;

function ipv6Groups(text) {
  const zoneless = text.split("%")[0];
  const halves = zoneless.split(/:{2}/);
  if (halves.length > 2) return null;
  const parse = (part) => (part === "" ? [] : part.split(":"));
  const head = parse(halves[0]);
  const tail = halves.length === 2 ? parse(halves[1]) : [];
  const missing = 8 - head.length - tail.length;
  if (halves.length === 1 ? missing !== 0 : missing < 1) return null;
  const groups = [...head, ...Array(halves.length === 2 ? missing : 0).fill("0"), ...tail];
  if (!groups.every((g) => /^[0-9a-f]{1,4}$/i.test(g))) return null;
  return groups.map((g) => parseInt(g, 16));
}

function isLoopbackHost(host) {
  if (typeof host !== "string" || host === "") return false;
  if (host === "localhost") return true;
  const bare = host.startsWith("[") && host.endsWith("]") ? host.slice(1, -1) : host;
  if (net.isIPv4(bare)) return bare.split(".")[0] === "127";
  if (net.isIPv6(bare)) {
    const groups = ipv6Groups(bare);
    return groups !== null && groups.slice(0, 7).every((g) => g === 0) && groups[7] === 1;
  }
  return false;
}

function integer(value, fallback, { min, max, name }) {
  if (value === undefined || value === "") {
    if (fallback === undefined) throw new Error(`${name} is required`);
    return fallback;
  }
  const n = Number(value);
  if (!Number.isInteger(n) || n < min || n > max) {
    throw new Error(`${name} must be an integer between ${min} and ${max}`);
  }
  return n;
}

function upstreamToken(env) {
  if (env.HERMES_FACADE_UPSTREAM_TOKEN_FILE) {
    return fs.readFileSync(env.HERMES_FACADE_UPSTREAM_TOKEN_FILE, "utf8").trim();
  }
  return env.HERMES_FACADE_UPSTREAM_TOKEN || "";
}

function validate(config) {
  if (!isLoopbackHost(config.upstreamHost)) {
    throw new Error("the upstream host must be a loopback address: the facade talks to Hermes locally only");
  }
  if (!config.upstreamToken) {
    throw new Error("the upstream credential is required (HERMES_FACADE_UPSTREAM_TOKEN or HERMES_FACADE_UPSTREAM_TOKEN_FILE)");
  }
  if (config.upstreamToken.length < MIN_SECRET_LENGTH || /\s/.test(config.upstreamToken)) {
    throw new Error(`the upstream credential must be at least ${MIN_SECRET_LENGTH} characters with no whitespace`);
  }
  if (config.listenPort === config.upstreamPort && config.listenPort !== 0) {
    throw new Error("the facade port must differ from the Hermes port");
  }
  if (!config.stateDir) throw new Error("HERMES_FACADE_STATE_DIR is required");
  return config;
}

function upstreamEndpoint(env = process.env) {
  return {
    host: env.HERMES_FACADE_UPSTREAM_HOST || "127.0.0.1",
    port: integer(env.HERMES_FACADE_UPSTREAM_PORT, undefined, { min: 1, max: 65535, name: "HERMES_FACADE_UPSTREAM_PORT" }),
  };
}

function fromEnv(env = process.env) {
  const stateDir = env.HERMES_FACADE_STATE_DIR ? path.resolve(env.HERMES_FACADE_STATE_DIR) : "";
  const tlsDir = env.HERMES_FACADE_TLS_DIR ? path.resolve(env.HERMES_FACADE_TLS_DIR) : stateDir && path.join(stateDir, "tls");
  return validate({
    stateDir,
    stateFile: stateDir && path.join(stateDir, "state.json"),
    auditFile: stateDir && path.join(stateDir, "audit.jsonl"),
    idempotencyFile: stateDir && path.join(stateDir, "idempotency.jsonl"),
    tlsKey: tlsDir && path.join(tlsDir, "server.key"),
    tlsCert: tlsDir && path.join(tlsDir, "server.crt"),
    listenHost: env.HERMES_FACADE_LISTEN_HOST || "127.0.0.1",
    listenPort: integer(env.HERMES_FACADE_LISTEN_PORT, undefined, { min: 0, max: 65535, name: "HERMES_FACADE_LISTEN_PORT" }),
    upstreamHost: env.HERMES_FACADE_UPSTREAM_HOST || "127.0.0.1",
    upstreamPort: integer(env.HERMES_FACADE_UPSTREAM_PORT, undefined, { min: 1, max: 65535, name: "HERMES_FACADE_UPSTREAM_PORT" }),
    upstreamToken: upstreamToken(env),
    ratePerMinute: integer(env.HERMES_FACADE_RATE_LIMIT_PER_MINUTE, 120, { min: 1, max: 100000, name: "HERMES_FACADE_RATE_LIMIT_PER_MINUTE" }),
    checkExposure: true,
  });
}

module.exports = {
  ENROLLMENT_TTL_MS,
  IDEMPOTENCY_TTL_MS,
  MAX_BODY_BYTES,
  MAX_WS_FRAGMENTS,
  MAX_WS_MESSAGE_BYTES,
  MIN_SECRET_LENGTH,
  fromEnv,
  isLoopbackHost,
  upstreamEndpoint,
  validate,
};
