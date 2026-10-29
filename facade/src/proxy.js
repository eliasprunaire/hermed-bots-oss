"use strict";

const http = require("node:http");

const STRIP_QUERY = ["token", "ticket", "internal"];
const KEEP_HEADERS = ["content-type", "content-length", "cache-control", "etag", "last-modified"];
const UPSTREAM_TIMEOUT_MS = 30_000;

function json(res, status, body, headers = {}) {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(text),
    "cache-control": "no-store",
    ...headers,
  });
  res.end(text);
}

// Forward one allowed read. The device credential never goes upstream, the Hermes credential
// never comes back, and only a short list of response headers crosses the facade.
function proxyRead(req, res, url, config) {
  return new Promise((resolve) => {
    const search = new URLSearchParams(url.search);
    for (const key of STRIP_QUERY) search.delete(key);
    const query = search.toString();
    const upstream = http.request(
      {
        host: config.upstreamHost.replace(/^\[|\]$/g, ""),
        port: config.upstreamPort,
        method: "GET",
        path: url.pathname + (query ? `?${query}` : ""),
        headers: {
          host: `${config.upstreamHost}:${config.upstreamPort}`,
          "x-hermes-session-token": config.upstreamToken,
          accept: req.headers.accept || "application/json",
          "accept-encoding": "identity",
          connection: "close",
        },
        timeout: UPSTREAM_TIMEOUT_MS,
      },
      (reply) => {
        if (reply.statusCode >= 300 && reply.statusCode < 400) {
          reply.resume();
          json(res, 502, { error: "upstream_unavailable" });
          resolve(502);
          return;
        }
        const headers = { "cache-control": "no-store" };
        for (const name of KEEP_HEADERS) if (reply.headers[name]) headers[name] = reply.headers[name];
        res.writeHead(reply.statusCode, headers);
        reply.pipe(res);
        reply.on("end", () => resolve(reply.statusCode));
        reply.on("error", () => {
          res.destroy();
          resolve(502);
        });
      },
    );
    const fail = () => {
      upstream.destroy();
      if (!res.headersSent) json(res, 502, { error: "upstream_unavailable" });
      else res.destroy();
      resolve(502);
    };
    upstream.on("timeout", fail);
    upstream.on("error", fail);
    upstream.end();
  });
}

// The facade's own status, projected from the Hermes one. Install paths and identifiers stay behind.
function projectStatus(raw) {
  const pick = (key, type) => (typeof raw[key] === type ? raw[key] : null);
  return {
    hermes_version: pick("version", "string"),
    gateway_running: pick("gateway_running", "boolean"),
    active_sessions: pick("active_sessions", "number"),
    overall: pick("overall", "string"),
  };
}

function fetchUpstreamStatus(config) {
  return new Promise((resolve, reject) => {
    const upstream = http.request(
      {
        host: config.upstreamHost.replace(/^\[|\]$/g, ""),
        port: config.upstreamPort,
        method: "GET",
        path: "/api/status",
        headers: {
          host: `${config.upstreamHost}:${config.upstreamPort}`,
          "x-hermes-session-token": config.upstreamToken,
          connection: "close",
        },
        timeout: 10_000,
      },
      (reply) => {
        const chunks = [];
        reply.on("data", (chunk) => chunks.push(chunk));
        reply.on("end", () => {
          try {
            if (reply.statusCode !== 200) throw new Error("status");
            resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
          } catch (err) {
            reject(err);
          }
        });
      },
    );
    upstream.on("timeout", () => upstream.destroy(new Error("timeout")));
    upstream.on("error", reject);
    upstream.end();
  });
}

module.exports = { fetchUpstreamStatus, json, projectStatus, proxyRead };
