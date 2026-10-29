"use strict";

const MAX_KEYS = 10_000;

// Fixed-window counter per key. The clock is injected so tests never sleep.
class RateLimiter {
  constructor({ limit, windowMs, now = Date.now }) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.now = now;
    this.windows = new Map();
  }

  take(key) {
    const at = this.now();
    let entry = this.windows.get(key);
    if (!entry || at >= entry.resetAt) {
      if (this.windows.size >= MAX_KEYS) this.sweep(at);
      entry = { count: 0, resetAt: at + this.windowMs };
      this.windows.set(key, entry);
    }
    if (entry.count >= this.limit) return { ok: false, retryAfterMs: entry.resetAt - at };
    entry.count += 1;
    return { ok: true, retryAfterMs: 0 };
  }

  peek(key) {
    const entry = this.windows.get(key);
    if (!entry || this.now() >= entry.resetAt) return { ok: true, retryAfterMs: 0 };
    return { ok: entry.count < this.limit, retryAfterMs: entry.resetAt - this.now() };
  }

  sweep(at) {
    for (const [key, entry] of this.windows) {
      if (at >= entry.resetAt) this.windows.delete(key);
    }
    if (this.windows.size >= MAX_KEYS) this.windows.clear();
  }
}

module.exports = { RateLimiter };
