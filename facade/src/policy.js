"use strict";

// Default deny. Hermes exposes shell, config, vault and connector methods on the same
// socket, so a device only reaches what this file names.

const HTTP_READS = [
  /^\/api\/sessions$/,
  /^\/api\/sessions\/search$/,
  /^\/api\/sessions\/stats$/,
  /^\/api\/sessions\/[A-Za-z0-9._:-]+$/,
  /^\/api\/sessions\/[A-Za-z0-9._:-]+\/messages$/,
  /^\/api\/sessions\/[A-Za-z0-9._:-]+\/messages\/around$/,
  /^\/api\/sessions\/[A-Za-z0-9._:-]+\/timeline$/,
];

const RPC_READS = [
  "ping",
  "session.list",
  "session.most_recent",
  "session.active_list",
  "session.resume",
  "session.events.since",
  "session.events.stats",
  "approval.pending",
];

// A write changes state on the Hermes side. Each one needs an idempotency key.
const RPC_WRITES = [
  "session.create",
  "session.close",
  "prompt.submit",
  "approval.respond",
  "session.interrupt",
];

const RPC_ADMIN_WRITES = ["session.delete", "session.archive", "session.title"];

const FACADE_ADMIN = ["POST /facade/enrollments", "GET /facade/devices", "GET /facade/audit"];

function httpReadAllowed(method, pathname) {
  return method === "GET" && HTTP_READS.some((re) => re.test(pathname));
}

function rpcClass(role, method) {
  if (RPC_READS.includes(method)) return "read";
  if (RPC_WRITES.includes(method)) return "write";
  if (role === "admin" && RPC_ADMIN_WRITES.includes(method)) return "write";
  return null;
}

module.exports = {
  FACADE_ADMIN,
  HTTP_READS,
  RPC_ADMIN_WRITES,
  RPC_READS,
  RPC_WRITES,
  httpReadAllowed,
  rpcClass,
};
