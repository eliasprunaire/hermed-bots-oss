#!/usr/bin/env python3
"""Fake OpenAI-compatible model provider for the spike (Q6, option s1): zero cost, no network.

Behaviour is chosen by the last user message:
  HV_TOOL_SLEEP  -> one `terminal` tool call that runs `sleep 300` (S3: a long tool)
  HV_TOOL_LONG   -> one `terminal` tool call that runs `sleep 400` (HD-05: a stream silent for more than 300 s)
  HV_TOOL_DETACH -> one `terminal` tool call that starts `sleep 303` in its own session, then runs `sleep 300` (S3: a descendant that leaves the tool's process group)
  HV_TOOL_BG     -> one `terminal` tool call with background=true that runs `sleep 301` (S3: a tracked background process)
  HV_LOOP        -> the same `terminal` tool call (`ls /tmp`) after every tool result, LOOP_CALLS times, then `HV-FAKE-TOOL-DONE` (HD-05: a looping turn)
  HV_SLOW        -> a text reply streamed over about 20 s (S2, S3: a long turn without a tool)
  HV_FAIL        -> HTTP 400 from the provider, which Hermes does not retry (S1: a failed turn)
  anything else  -> `HV-FAKE-REPLY model=<requested model> user_msgs=<n>`
After a tool result the reply is `HV-FAKE-TOOL-DONE`.
Every request is logged on stderr as one line, without message bodies beyond 80 characters.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = ["hv-fake-1", "hv-fake-2"]
LOOP_CALLS = 6  # bound of HV_LOOP, so a missed pause does not run forever


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, file=sys.stderr, flush=True)


def text_of(content):
    if isinstance(content, list):
        return " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    return content or ""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def _json(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            return self._json(200, {"object": "list", "data": [{"id": m, "object": "model", "owned_by": "hv"} for m in MODELS]})
        self._json(404, {"error": "not found"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0) or b"{}")
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self._json(404, {"error": "not found"})
        msgs = body.get("messages", [])
        model = body.get("model", MODELS[0])
        last = msgs[-1] if msgs else {}
        last_user = next((text_of(m.get("content")) for m in reversed(msgs) if m.get("role") == "user"), "")
        users = sum(1 for m in msgs if m.get("role") == "user")
        has_terminal = any(t.get("function", {}).get("name") == "terminal" for t in body.get("tools") or [])
        log(f"req model={model} stream={bool(body.get('stream'))} msgs={len(msgs)} last_role={last.get('role')} user={last_user[:80]!r}")
        if "HV_FAIL" in last_user:
            return self._json(400, {"error": {"message": "hv fake provider failure", "type": "invalid_request_error"}})
        tool_call = None
        tool_args = {"command": "sleep 300", "timeout": 600}
        if "HV_TOOL_DETACH" in last_user:
            tool_args["command"] = ("python3 -c \"import os,subprocess; "
                                    "subprocess.Popen(['sleep','303'], start_new_session=True); os.system('sleep 300')\"")
        elif "HV_TOOL_LONG" in last_user:
            tool_args["command"] = "sleep 400"
        elif "HV_TOOL_BG" in last_user:
            tool_args = {"command": "sleep 301", "background": True}
        tool_results = sum(1 for m in msgs if m.get("role") == "tool")
        looping = "HV_LOOP" in last_user and has_terminal and tool_results < LOOP_CALLS
        if looping:
            tool_args = {"command": "ls /tmp"}
        if last.get("role") == "tool" and not looping:
            text = "HV-FAKE-TOOL-DONE"
        elif looping or (any(k in last_user for k in ("HV_TOOL_SLEEP", "HV_TOOL_LONG", "HV_TOOL_DETACH", "HV_TOOL_BG")) and has_terminal):
            text = ""
            tool_call = {"index": 0, "id": f"call_hv_{tool_results + 1}", "type": "function",
                         "function": {"name": "terminal", "arguments": json.dumps(tool_args)}}
        elif "HV_SLOW" in last_user:
            text = " ".join(f"slow{i}" for i in range(20))
        else:
            text = f"HV-FAKE-REPLY model={model} user_msgs={users}"
        if body.get("stream"):
            return self._stream(model, text, tool_call, slow="HV_SLOW" in last_user)
        msg = {"role": "assistant", "content": text or None}
        if tool_call:
            msg["tool_calls"] = [tool_call]
        self._json(200, {"id": "chatcmpl-hv", "object": "chat.completion", "created": int(time.time()), "model": model,
                         "choices": [{"index": 0, "message": msg, "finish_reason": "tool_calls" if tool_call else "stop"}],
                         "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}})

    def _chunk(self, model, delta, finish=None):
        data = {"id": "chatcmpl-hv", "object": "chat.completion.chunk", "created": int(time.time()), "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        payload = f"data: {json.dumps(data)}\n\n".encode()
        self.wfile.write(f"{len(payload):x}\r\n".encode() + payload + b"\r\n")
        self.wfile.flush()

    def _stream(self, model, text, tool_call, slow):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            self._chunk(model, {"role": "assistant", "content": ""})
            if tool_call:
                self._chunk(model, {"tool_calls": [tool_call]})
            else:
                parts = text.split(" ") if slow else [text]
                for i, part in enumerate(parts):
                    self._chunk(model, {"content": part + (" " if i < len(parts) - 1 else "")})
                    if slow:
                        time.sleep(1)
            self._chunk(model, {}, "tool_calls" if tool_call else "stop")
            done = b"data: [DONE]\n\n"
            self.wfile.write(f"{len(done):x}\r\n".encode() + done + b"\r\n0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            log("client closed the stream")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9999
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
