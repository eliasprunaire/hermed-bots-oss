"use strict";

const http = require("node:http");
const { acceptUpgrade } = require("../src/websocket");

const TOKEN = "upstream-test-credential-0001";

// A stand-in for `hermes serve` on the loopback. It mimics what the test instance showed:
// the credential as a header or a query token, strict JSON-RPC parameters, a status route
// that carries install paths, and replies that carry headers a device must never see.
async function startFakeHermes({ host = "127.0.0.1", delayMs = 0 } = {}) {
  const calls = {};
  const requests = [];
  const sockets = new Set();
  let nextRow = 1;
  let sessions = 0;

  const server = http.createServer((req, res) => {
    requests.push({ method: req.method, url: req.url, headers: { ...req.headers } });
    if (req.headers["x-hermes-session-token"] !== TOKEN) {
      res.writeHead(401, { "content-type": "application/json" });
      res.end('{"detail":"Unauthorized"}');
      return;
    }
    const send = (status, body, headers = {}) => {
      res.writeHead(status, { "content-type": "application/json", server: "uvicorn", ...headers });
      res.end(JSON.stringify(body));
    };
    const url = new URL(req.url, "http://upstream.invalid");
    if (url.pathname === "/api/sessions") {
      send(200, { sessions: [{ id: "s1", title: "first" }], total: 1 }, {
        "set-cookie": "hermes_session=leak; Path=/",
        "x-hermes-session-token": "leak",
        "www-authenticate": "Bearer realm=hermes",
      });
    } else if (url.pathname === "/api/sessions/moved") {
      send(302, {}, { location: `http://${host}:${server.address().port}/api/sessions` });
    } else if (url.pathname === "/api/sessions/s1/messages") {
      send(200, { messages: [{ role: "user", content: "hello" }] });
    } else if (url.pathname === "/api/status") {
      send(200, {
        version: "0.22.5",
        gateway_running: true,
        active_sessions: 2,
        overall: "ok",
        hermes_home: "/data/example-home",
        config_path: "/data/example-home/config.yaml",
        install_id: "0123456789abcdef",
      });
    } else {
      send(404, { detail: "Not Found" });
    }
  });

  server.on("upgrade", (req, socket) => {
    const url = new URL(req.url, "http://upstream.invalid");
    if (url.pathname !== "/api/ws" || url.searchParams.get("token") !== TOKEN) {
      socket.end("HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n");
      return;
    }
    const peer = acceptUpgrade(req, socket);
    sockets.add(peer);
    peer.on("close", () => sockets.delete(peer));
    peer.send(JSON.stringify({ jsonrpc: "2.0", method: "event", params: { type: "gateway.ready" } }));
    peer.on("message", (text) => {
      const msg = JSON.parse(text);
      const { id, method } = msg;
      const params = msg.params || {};
      calls[method] = (calls[method] || 0) + 1;
      const reply = (result) => peer.send(JSON.stringify({ jsonrpc: "2.0", id, result }));
      const fail = (code, message) => peer.send(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } }));
      const allowed = {
        ping: [],
        "session.list": [],
        "session.create": [],
        "session.resume": ["session_id"],
        "prompt.submit": ["session_id", "text"],
        "approval.respond": ["session_id", "choice"],
        "session.interrupt": ["session_id"],
        "session.delete": ["session_id"],
      };
      if (!allowed[method]) {
        if (method === "boom") {
          peer.socket.destroy();
          return;
        }
        fail(-32601, `unknown method: ${method}`);
        return;
      }
      const extra = Object.keys(params).filter((k) => !allowed[method].includes(k));
      if (extra.length) {
        fail(4000, `invalid params for ${method}: ${extra[0]}: Extra inputs are not permitted`);
        return;
      }
      const done = () => {
        if (method === "ping") reply({ pong: true });
        else if (method === "session.list") reply({ sessions: [] });
        else if (method === "session.create") reply({ session_id: `fake${++sessions}` });
        else if (method === "prompt.submit") reply({ status: "streaming", user_row_id: nextRow++ });
        else if (method === "session.interrupt") reply({ status: "interrupted" });
        else if (method === "approval.respond") reply({ status: "resolved" });
        else reply({ status: "ok" });
      };
      if (delayMs && method === "prompt.submit") setTimeout(done, delayMs);
      else done();
    });
  });

  await new Promise((resolve) => server.listen(0, host, resolve));

  return {
    port: server.address().port,
    token: TOKEN,
    calls,
    requests,
    dropSockets() {
      for (const peer of sockets) peer.socket.destroy();
    },
    async close() {
      for (const peer of sockets) peer.socket.destroy();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

module.exports = { TOKEN, startFakeHermes };
