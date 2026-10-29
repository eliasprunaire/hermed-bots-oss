"use strict";

const crypto = require("node:crypto");
const { EventEmitter } = require("node:events");
const { MAX_WS_FRAGMENTS, MAX_WS_MESSAGE_BYTES } = require("./config");

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const OP = { CONT: 0x0, TEXT: 0x1, BINARY: 0x2, CLOSE: 0x8, PING: 0x9, PONG: 0xa };

function acceptKey(key) {
  return crypto.createHash("sha1").update(key + GUID).digest("base64");
}

function encodeFrame(opcode, payload, { mask = false } = {}) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  let header;
  if (body.length < 126) {
    header = Buffer.from([0x80 | opcode, body.length]);
  } else if (body.length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(body.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(body.length), 2);
  }
  if (!mask) return Buffer.concat([header, body]);
  const key = crypto.randomBytes(4);
  header[1] |= 0x80;
  const masked = Buffer.from(body);
  for (let i = 0; i < masked.length; i++) masked[i] ^= key[i % 4];
  return Buffer.concat([header, key, masked]);
}

// RFC 6455 endpoint over an upgraded socket. Emits "message" (text), "close" (code).
// `expectMasked` is true on the server side: a client frame that is not masked is a protocol error.
class WebSocketPeer extends EventEmitter {
  constructor(socket, { expectMasked = true, maxMessageBytes = MAX_WS_MESSAGE_BYTES, maxFragments = MAX_WS_FRAGMENTS } = {}) {
    super();
    this.socket = socket;
    this.expectMasked = expectMasked;
    this.maxMessageBytes = maxMessageBytes;
    this.maxFragments = maxFragments;
    this.buffer = Buffer.alloc(0);
    this.fragments = [];
    this.fragmentBytes = 0;
    this.fragmentOpcode = null;
    this.closed = false;
    socket.on("data", (chunk) => this.onData(chunk));
    socket.on("close", () => this.finish(1006));
    socket.on("error", () => this.finish(1006));
  }

  onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      const frame = this.readFrame();
      if (!frame) return;
      if (this.closed) return;
      this.onFrame(frame);
    }
  }

  readFrame() {
    const buf = this.buffer;
    if (buf.length < 2) return null;
    const fin = Boolean(buf[0] & 0x80);
    if (buf[0] & 0x70) return this.fail(1002);
    const opcode = buf[0] & 0x0f;
    const masked = Boolean(buf[1] & 0x80);
    let length = buf[1] & 0x7f;
    let offset = 2;
    if (length === 126) {
      if (buf.length < 4) return null;
      length = buf.readUInt16BE(2);
      offset = 4;
    } else if (length === 127) {
      if (buf.length < 10) return null;
      const big = buf.readBigUInt64BE(2);
      if (big > BigInt(this.maxMessageBytes)) return this.fail(1009);
      length = Number(big);
      offset = 10;
    }
    if (masked !== this.expectMasked) return this.fail(1002);
    if (length > this.maxMessageBytes) return this.fail(1009);
    const need = offset + (masked ? 4 : 0) + length;
    if (buf.length < need) return null;
    let payload = buf.subarray(offset + (masked ? 4 : 0), need);
    if (masked) {
      const key = buf.subarray(offset, offset + 4);
      payload = Buffer.from(payload);
      for (let i = 0; i < payload.length; i++) payload[i] ^= key[i % 4];
    }
    this.buffer = buf.subarray(need);
    return { fin, opcode, payload };
  }

  onFrame({ fin, opcode, payload }) {
    if (opcode >= 0x8) {
      if (!fin || payload.length > 125) return this.fail(1002);
      if (opcode === OP.PING) return this.write(encodeFrame(OP.PONG, payload, { mask: !this.expectMasked }));
      if (opcode === OP.CLOSE) {
        const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1005;
        this.close(code === 1005 ? 1000 : code);
        return this.finish(code);
      }
      return undefined;
    }
    if (opcode === OP.TEXT || opcode === OP.BINARY) {
      if (this.fragmentOpcode !== null) return this.fail(1002);
      this.fragmentOpcode = opcode;
    } else if (opcode !== OP.CONT || this.fragmentOpcode === null) {
      return this.fail(1002);
    }
    this.fragmentBytes += payload.length;
    // empty fragments add no bytes, so only their count bounds the memory and the work of one message
    if (this.fragmentBytes > this.maxMessageBytes || this.fragments.length >= this.maxFragments) return this.fail(1009);
    if (opcode === OP.CONT) this.emit("fragment");
    this.fragments.push(payload);
    if (!fin) return undefined;
    const message = Buffer.concat(this.fragments);
    const kind = this.fragmentOpcode;
    this.fragments = [];
    this.fragmentBytes = 0;
    this.fragmentOpcode = null;
    if (kind === OP.BINARY) return this.fail(1003);
    let text;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(message);
    } catch {
      return this.fail(1007);
    }
    this.emit("message", text);
    return undefined;
  }

  fail(code) {
    this.close(code);
    this.finish(code);
    return null;
  }

  write(buffer) {
    if (!this.socket.destroyed) this.socket.write(buffer);
  }

  send(text) {
    if (this.closed) return;
    this.write(encodeFrame(OP.TEXT, text, { mask: !this.expectMasked }));
  }

  close(code = 1000, reason = "") {
    if (this.closed) return;
    const payload = Buffer.alloc(2 + Buffer.byteLength(reason));
    payload.writeUInt16BE(code, 0);
    payload.write(reason, 2);
    this.write(encodeFrame(OP.CLOSE, payload, { mask: !this.expectMasked }));
    this.closing = true;
    setTimeout(() => this.socket.destroy(), 1000).unref();
  }

  finish(code) {
    if (this.closed) return;
    this.closed = true;
    this.socket.end();
    this.emit("close", code);
  }
}

function acceptUpgrade(req, socket, head) {
  const key = req.headers["sec-websocket-key"];
  const upgrade = String(req.headers.upgrade || "").toLowerCase();
  if (upgrade !== "websocket" || !key || req.headers["sec-websocket-version"] !== "13") return null;
  socket.write(
    [
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      `Sec-WebSocket-Accept: ${acceptKey(key)}`,
      "",
      "",
    ].join("\r\n"),
  );
  const peer = new WebSocketPeer(socket);
  if (head && head.length) setImmediate(() => peer.onData(head));
  return peer;
}

module.exports = { OP, WebSocketPeer, acceptKey, acceptUpgrade, encodeFrame };
