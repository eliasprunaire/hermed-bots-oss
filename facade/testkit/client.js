"use strict";

const https = require("node:https");
const { WebSocketPeer, acceptKey, encodeFrame } = require("../src/websocket");
const crypto = require("node:crypto");
const { pinnedClientOptions } = require("../src/tls");

function tlsOptions({ ca, pin }) {
  return pinnedClientOptions({ caPem: ca, pin });
}

// One HTTPS call through the pinned trust. Resolves { status, headers, body, json }.
function request({ port, method = "GET", path, token, body, ca, pin, headers = {}, servername = "localhost" }) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? null : JSON.stringify(body);
    const req = https.request(
      {
        host: "127.0.0.1",
        port,
        method,
        path,
        servername,
        ...tlsOptions({ ca, pin }),
        headers: {
          ...(token ? { authorization: `Bearer ${token}` } : {}),
          ...(payload ? { "content-type": "application/json", "content-length": Buffer.byteLength(payload) } : {}),
          ...headers,
        },
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let parsed = null;
          try {
            parsed = JSON.parse(text);
          } catch {
            parsed = null;
          }
          resolve({ status: res.statusCode, headers: res.headers, body: text, json: parsed });
        });
      },
    );
    req.on("error", reject);
    req.end(payload || undefined);
  });
}

// A device WebSocket over the pinned TLS. Resolves a client, or rejects with { status } when refused.
function connectWs({ port, token, ca, pin, path = "/api/ws", servername = "localhost" }) {
  return new Promise((resolve, reject) => {
    const key = crypto.randomBytes(16).toString("base64");
    const req = https.request({
      host: "127.0.0.1",
      port,
      path,
      servername,
      ...tlsOptions({ ca, pin }),
      headers: {
        connection: "Upgrade",
        upgrade: "websocket",
        "sec-websocket-version": "13",
        "sec-websocket-key": key,
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
    });
    req.on("response", (res) => {
      res.resume();
      reject(Object.assign(new Error(`refused ${res.statusCode}`), { status: res.statusCode }));
    });
    req.on("error", reject);
    req.on("upgrade", (res, socket, head) => {
      if (res.headers["sec-websocket-accept"] !== acceptKey(key)) {
        reject(new Error("bad accept key"));
        return;
      }
      const peer = new WebSocketPeer(socket, { expectMasked: false });
      const inbox = [];
      const waiters = [];
      let closeCode = null;
      peer.on("message", (text) => {
        const message = JSON.parse(text);
        const waiter = waiters.findIndex((w) => w.match(message));
        if (waiter >= 0) waiters.splice(waiter, 1)[0].resolve(message);
        else inbox.push(message);
      });
      peer.on("close", (code) => {
        closeCode = code;
        for (const w of waiters.splice(0)) w.resolve(null);
      });
      if (head && head.length) peer.onData(head);
      const wait = (match, ms = 5000) =>
        new Promise((resolveWait, rejectWait) => {
          const at = inbox.findIndex(match);
          if (at >= 0) return resolveWait(inbox.splice(at, 1)[0]);
          if (closeCode !== null) return resolveWait(null);
          const timer = setTimeout(() => rejectWait(new Error("timeout waiting for a message")), ms);
          return waiters.push({ match, resolve: (m) => { clearTimeout(timer); resolveWait(m); } });
        });
      resolve({
        peer,
        call(method, params, id = crypto.randomUUID()) {
          const payload = params === undefined ? { jsonrpc: "2.0", id, method } : { jsonrpc: "2.0", id, method, params };
          const reply = wait((m) => m.id === id);
          peer.write(encodeFrame(0x1, JSON.stringify(payload), { mask: true }));
          return reply;
        },
        sendRaw(text) {
          peer.write(encodeFrame(0x1, text, { mask: true }));
        },
        wait,
        get closeCode() {
          return closeCode;
        },
        closed: () => new Promise((resolveClosed) => (closeCode !== null ? resolveClosed(closeCode) : peer.once("close", resolveClosed))),
        close() {
          peer.close(1000);
        },
      });
    });
    req.end();
  });
}

module.exports = { connectWs, request };
