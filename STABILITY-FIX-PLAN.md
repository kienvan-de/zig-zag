# zig-zag Stability Review & Fix Plan

**Context:** Post-migration instability after upgrading Zig 0.15.2 → 0.16.0 (commit `49cf132`).
**Symptom:** Server runs fine initially, then crashes after some requests.
**Reviewed:** 2026-08-26 · Working tree at `d20a9c1` (no code changes applied yet).
**Method:** Manual code review of all hot paths + **verification of every hypothesis against the actual Zig 0.16.0 stdlib sources** installed at `/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std`.

---

## 1. Executive Summary

| # | Severity | Issue | File(s) | Status |
|---|----------|-------|---------|--------|
| F1 | 🔴 Critical | SIGPIPE no longer ignored → client disconnect kills whole process | `core/net.zig`, `main.zig`, `lib.zig` | ✅ already fixed |
| F2 | 🔴 Critical | Pricing auto-update UAF: `pricing.deinit()` runs before worker pool joins curl task | `main.zig`, `lib.zig` | ✅ already fixed |
| F3 | 🟠 High | All threads share one `init_single_threaded` `Io.Threaded` (racy lazy-init state, broken limits) | `core/time.zig` + entry points | ✅ fixed: added `init()` to `time.zig` |
| F4 | 🟠 High | SSE events > 8 KiB silently dropped → corrupted streams | `http.zig:104` | ✅ fixed: dynamic ArrayList buffer |
| F5 | 🟠 High | `req.connection.?` force-unwraps can panic mid-request | `core/client.zig:358,443,510` | ✅ fixed: guarded unwraps |
| F6 | 🟡 Medium | `Connection.writeAll` uses raw `std.c.write` — no EINTR retry | `core/net.zig:22` | ✅ fixed: EINTR loop |
| F7 | 🟡 Medium | `accept()` spins hot on persistent errors; EINTR/ECONNABORTED not retried | `core/net.zig:84`, `server.zig:146` | ✅ fixed: exponential backoff |
| F8 | 🟡 Medium | LF-only request headers → Content-Length parsed as 0 → truncated body | `server.zig:281` | ✅ fixed: split on `\n`, trim `\r` |
| F9 | 🟡 Medium | Listener fd double-close hazard on shutdown path | `core/net.zig:91` | ✅ fixed: fd >= 0 guard + reset |
| F10 | 🟡 Medium | Streaming loops allocate per-chunk buffers from long-lived arena | `core/completion.zig` | ✅ fixed: scratch ArenaAllocator |
| A1–A5 | ℹ️ Advisory | Architecture/perf observations for multi-request handling | §5 | ☐ advisory |

---

## 2. What Was Done (Review Log)

### Investigated & confirmed
- **Migration surface mapped:** commit `49cf132` replaced ~179 stdlib usages with hand-written POSIX wrappers (`src/core/{net,sync,time,env,fs}.zig`) specifically to *avoid* threading `io: std.Io` parameters through the call chain.
- **F1 confirmed via stdlib:** Zig 0.16's `start.zig` contains **zero** SIGPIPE handling (grep verified). The ignore-handler moved into `Io.Threaded.init()` (`Threaded.zig:1661`: `posix.sigaction(.PIPE, &act, ...)`). Our code uses `init_single_threaded` which hardcodes `have_signal_handler = false` (`Threaded.zig:1684`). Project grep shows **no** SIGPIPE/sigaction/MSG_NOSIGNAL anywhere in `src/`.
- **F2 confirmed:** Defer order traced in both entry points: exit order is `pricing.deinit()` → … → `worker_pool.deinit()` (which is what joins the in-flight `autoUpdateTask`). Freeing tables under a running task = UAF.
- **F3 confirmed via stdlib:** `init_single_threaded` sets `allocator = .failing`, `async_limit = .nothing`, `concurrent_limit = .nothing`, `have_signal_handler = false`. `Io.Limit.nothing == 0` (`Io.zig:627`). Consequences:
  - `busy_count(0) >= async_limit(0)` → every async op runs **inline on caller thread** (this is why it works *at all*).
  - Any `io.concurrent()` → `error.ConcurrencyUnavailable` forever.
  - Lazy-initialized shared fields (`csprng`, `pipe_file`, environ memoization, `dl`) are first touched concurrently by server workers → data-race exposure exactly matching "crashes after some requests".
- **F4 confirmed:** `http.zig:106` — `bufPrint(&buf /*8192*/ , ...) catch return;` silently discards oversized events.
- **F5 confirmed:** three `req.connection.?` unwraps after body-send; a dropped upstream socket panics instead of erroring.
- **F7 confirmed:** `net.zig accept()` maps *any* negative libc return to one error; `server.zig` worker loop `continue`s → tight spin under e.g. EMFILE.

### Reviewed & CLEARED (do not re-chase these)
- ✅ **SSEIterator.next() error path is NOT a double-free.** Initially suspected; disproved against stdlib: `Writer.Allocating.fromArrayList` immediately sets the source list to `.empty` ("taking ownership"), so after `writer.deinit()` the stale `self.line_buffer` is an empty list — later `deinit()` frees nothing. (`Writer.zig:2557-2590`)
- ✅ `metrics.zig` — all counters are `std.atomic.Value(u64)`; thread-safe.
- ✅ `pricing.getCost/loadTables` — correct `RwLock` shared/exclusive usage.
- ✅ `worker_pool.zig` — queue mutex/cond logic correct; `join()` waits out in-flight tasks (important guarantee that F2's fix relies on).
- ✅ `Response.reader()` returns `*Reader` pointing into heap-stable `result.request` (`http/Client.zig:736`) — pointer stability OK.
- ✅ Per-connection arena pattern in `handleConnection` is sound.
- ✅ `DebugAllocator` default config is thread-safe (`thread_safe = !single_threaded`).

---

## 3. Root Cause of the Crash

```
Client disconnects mid-stream (cancel / timeout / keep-alive probe)
        │
        ▼
net.Connection.writeAll() → std.c.write(dead_socket)
        │
        ▼
Kernel raises SIGPIPE   (default action: TERMINATE PROCESS)
        │
        ▼
Proxy dies. In ≤0.15 this was masked because std.start ignored SIGPIPE;
in 0.16 that safety net moved into Io backend init(), which this project bypasses.
```

Secondary contributor (macOS app restart cycles): F2 shutdown UAF.
Latent contributor under concurrent load: F3 lazy-init races inside the shared Io instance.

Integration tests missed all of this because the mock client never disconnects early, responses are small (<8 KiB), and runs are short-lived.

---

## 4. Detailed Fix Plan

> Conventions: snippets are starting points; adapt names/types to compile.
> Build/test toolchain: `/opt/homebrew/opt/zig@0.16/bin/zig` (not on PATH).

### F1 — Restore SIGPIPE protection 🔴

**Files:** `src/core/net.zig` (new helper), callers: `src/main.zig`, `src/lib.zig`

```zig
// src/core/net.zig
/// Ignore SIGPIPE so writes to sockets closed by the peer return EPIPE
/// (error.BrokenPipe) instead of terminating the process.
///
/// Zig ≤0.15 installed this automatically from std.start; in 0.16 the handler
/// install moved into Io backend init(), which we bypass (see core/time.zig),
/// so we must install it ourselves.
pub fn ignoreSigpipe() void {
    const posix = std.posix;
    if (builtin.os.tag == .windows) return;
    if (posix.SIG != void and @hasField(posix.SIG, "PIPE")) {
        const act = posix.Sigaction{
            // Option A: SIG.IGN (see os/linux.zig:3952 for the type shape)
            // Option B (if SIG.IGN doesn't coerce on darwin/libc targets):
            //   define `fn doNothing(_: i32, _: ?*posix.signinfo_t) callconv(.c) void {}`
            //   and use `.handler = .{ .handler = doNothing }`
            // Reference pattern: std/Io/Threaded.zig:1654-1662
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(.PIPE, &act, null);
    }
}
```

Call sites:
- `main()` — first statement.
- `lib.zig startServer()` — before spawning server thread.
- Belt-and-suspenders: also called by F3's `time.init()` (a properly `init()`-ed Threaded installs its own handler; ours stays harmless).

**Acceptance:**
- [ ] Compiles on macOS + Linux targets
- [ ] Manual repro: `curl` a streaming request and Ctrl-C the curl mid-stream → proxy survives, logs a warn
- [ ] `kill -PIPE <pid>` no longer terminates the proxy

---

### F2 — Fix shutdown deinit ordering 🔴

**Files:** `src/main.zig`, `src/lib.zig (serverThreadFn)`

Problem: defers run in reverse declaration order, so `pricing.deinit()` currently executes **before** `worker_pool.deinit()` (which is what joins the running `autoUpdateTask`).

Fix (minimal-diff reorder — move pricing init **above** worker_pool init, split `scheduleAutoUpdate` to stay *after* pool init):

```zig
// main.zig — new declaration order (exit runs bottom-up):
pricing.init(allocator, provider_names_buf[0..provider_name_count]);
defer pricing.deinit();                       // now runs AFTER pool shutdown ✓

app_cache.init(allocator);  defer app_cache.deinit();
token_cache.init(allocator); defer token_cache.deinit();

var cfg = try app_config.AppConfig.loadFromFile(...);
defer cfg.deinit();

try worker_pool.init(allocator, ...);         // defer worker_pool.deinit()
                                              // → joins autoUpdateTask BEFORE pricing.deinit ✓
try log_impl.init(cfg.log, allocator);        // defer log_impl.deinit()

metrics.load();             defer metrics.persist();
...
pricing.scheduleAutoUpdate();                 // pool exists here ✓
try server.start(allocator, &cfg);
```

Mirror the same order in `lib.zig serverThreadFn` (steps 1/3/6 blocks).

**Invariant to preserve:** `worker_pool.deinit()` (joins tasks) must always run **before** anything a task touches is freed (`pricing`, and after F3: the Io backend).

**Acceptance:**
- [ ] Exit-order assertion logging added temporarily during dev, removed after
- [ ] Rapid `startServer`/`stopServer` ×20 in macOS app with network flaky (airplane-mode toggle) → no crash
- [ ] `zig build test` green

---

### F3 — Properly initialized Io backend 🟠

**Files:** `src/core/time.zig`, `src/main.zig`, `src/lib.zig`

Replace the shared `init_single_threaded` global with a properly initialized `Threaded` created once at startup:

```zig
// src/core/time.zig
var threaded_instance: std.Io.Threaded = undefined;
var threaded_ready: bool = false;

/// Legacy fallback used only before init()/after deinit().
var legacy_single_threaded: std.Io.Threaded = .init_single_threaded;

pub fn init(allocator: std.mem.Allocator, environ: ?std.process.Environ) !void {
    if (threaded_ready) return error.AlreadyInitialized;
    threaded_instance = try std.Io.Threaded.init(allocator, .{
        // Real limits: internal locking active, worker pool usable,
        // SIGPIPE/SIGIO handlers installed (have_sig_pipe).
        .environ = environ orelse .empty,
    });
    threaded_ready = true;
}

pub fn deinit() void {
    if (!threaded_ready) return;
    threaded_instance.deinit();
    threaded_ready = false;
}

pub fn io() std.Io {
    if (threaded_ready) return threaded_instance.io();
    return legacy_single_threaded.io(); // startup/shutdown window only
}
```

Entry points:
- `main.zig`: `try core.time.init(allocator, init.environ);` — `std.process.Init.Minimal` carries a real `Environ` (verified: `process.zig:51-56`). Declare this init **first** among subsystems so its deinit runs **last** (after `worker_pool.deinit()`).
- `lib.zig`: call `core.time.init(allocator, null)` in `serverThreadFn` step 0 (real OS environ isn't reachable via C ABI without extra work — see Follow-up FU-2). Deinit after `server.start()` returns, still inside `serverThreadFn`, **after** `worker_pool.deinit()`'s equivalent ordering holds (i.e., declare its defer accordingly or deinit explicitly at end).

**Why this matters beyond hygiene:** a properly initialized Threaded (a) installs the SIGPIPE ignore (defense-in-depth for F1), (b) enables real async/concurrent capacity instead of everything-inline, (c) removes concurrent-first-touch races on `csprng`/lazy fields, (d) stops returning `ConcurrencyUnavailable` from any stdlib internals that use `io.concurrent()`.

**Acceptance:**
- [ ] Two parallel streaming requests succeed concurrently
- [ ] Pricing auto-update curl subprocess still executes (env caveat → FU-2)
- [ ] No regression in HAI/Copilot auth flows (they use curl wrapper, not Io)

---

### F4 — Dynamic buffer for SSE events 🟠

**File:** `src/http.zig:104`

`sendSseEvent` currently drops any event > 8 KiB **silently**. No callers exist today (verified), so changing the signature is free:

```zig
pub fn sendSseEvent(
    connection: net.Connection,
    allocator: std.mem.Allocator,
    data: []const u8,
) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "data: {s}\n\n", .{data});
    try sendSseChunk(connection, buf.items);
}
```

**Acceptance:**
- [ ] Unit test: event of 100 KiB arrives intact as one chunk frame
- [ ] Doc comment updated (remove "silently dropped" paragraph)

---

### F5 — Remove force-unwraps on upstream connection 🟠

**File:** `src/core/client.zig:358,443,510`

```zig
// before: try req.connection.?.flush();
const conn = req.connection orelse return error.UpstreamError;
conn.flush() catch |err| {
    log.err("HTTP flush failed: {}", .{err});
    return err;
};
```

Apply identically in `post()`, `postJson()`, `postStreaming()`.

**Acceptance:**
- [ ] Kill upstream TCP mid-upload (test harness) → clean 502, no panic

---

### F6 — EINTR-safe `writeAll` 🟡

**File:** `src/core/net.zig:22-30`

Raw `std.c.write` doesn't retry `EINTR` → a stray signal truncates an HTTP response. Use `std.posix.write` (handles EINTR internally; verify in 0.16 `posix.zig`, else loop manually):

```zig
pub fn writeAll(self: Connection, data: []const u8) !void {
    var remaining = data;
    while (remaining.len > 0) {
        const n = std.posix.write(self.handle, remaining) catch |err| switch (err) {
            error.WouldBlock => return error.WriteFailed, // SO_SNDTIMEO expiry
            else => return err,
        };
        if (n == 0) return error.WriteFailed;
        remaining = remaining[n..];
    }
}
```

**Acceptance:** [ ] Streaming 5 MB response completes under `SIGCHLD` noise (spawn subprocesses during transfer)

---

### F7 — Harden accept path 🟡

**Files:** `src/core/net.zig:84`, `src/server.zig:146`

- `TcpServer.accept`: retry `EINTR`; map `ECONNABORTED` to a distinct error (caller skips); keep others as errors.
- `workerThread`: on persistent accept failure, exponential-ish backoff (cap ~200 ms), reset on success:

```zig
var fail_streak: u32 = 0;
while (true) {
    const conn = ctx.listener.accept() catch |err| {
        // ... existing shutdown/listener-closed break logic ...
        fail_streak += 1;
        const backoff_ms: u64 = @min(50 * (1 << @min(fail_streak, 3)), 200);
        core.time.sleep(backoff_ms * std.time.ns_per_ms);
        continue;
    };
    fail_streak = 0;
    ...
}
```

(`std.time.ns_per_ms` verified present in 0.16 `time.zig:5`.)

**Acceptance:** [ ] Simulated EMFILE (raise `ulimit -n` exhaustion) → CPU flat, recovers when fds freed

---

### F8 — Content-Length parsing for LF-only headers 🟡

**File:** `server.zig:281-292`

Header-end detection already accepts `\n\n` (line 232) but parsing splits only on `\r\n` → LF-only clients get `content_length = 0` and truncated bodies.

```zig
fn parseContentLength(headers: []const u8) ?usize {
    var it = std.mem.splitScalar(u8, headers, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r"); // trimRight was renamed in 0.16
        const prefix = "content-length:";
        if (line.len <= prefix.len) continue;
        if (std.ascii.startsWithIgnoreCase(line, prefix)) {
            const value = std.mem.trim(u8, line[prefix.len..], " \t");
            return std.fmt.parseUnsigned(usize, value, 10) catch null;
        }
    }
    return null;
}
```

**Acceptance:** [ ] Integration case with `\n`-only framing posts JSON body successfully

---

### F9 — Double-close guard on listener 🟡

**File:** `core/net.zig:91-93`

```zig
pub fn deinit(self: *TcpServer) void {
    if (self.fd >= 0) {
        _ = std.c.close(self.fd);
        self.fd = -1;
    }
}
```

Note: closing an fd another thread blocks on in `accept()` remains POSIX gray-area (works on macOS/Linux today). Full fix = self-pipe/poll wakeup — deferred to FU-4; the guard removes the sharp edge cheaply.

---

### F10 — Bounded per-chunk allocations in streaming 🟡

**File:** `core/completion.zig` (`chatStreaming`, OpenAI path)

Per chunk we build an ArrayList from the connection-lifetime arena; arena can only reuse its most-recent allocation, so growth creeps over long streams. Add a scratch sub-arena reset **per iteration**, used ONLY for the serialize buffer:

```zig
var scratch = std.heap.ArenaAllocator.init(allocator);
defer scratch.deinit();
...
while (true) {
    _ = scratch.reset(.retain_capacity);
    const sa = scratch.allocator();
    var buffer = std.ArrayList(u8).empty;      // uses sa
    defer buffer.deinit(sa);
    buffer.print(sa, "data: {f}\n\n", .{std.json.fmt(chunk.value, .{})}) catch continue;
    try writer.writeAll(buffer.items);
}
```

⚠️ **Do NOT** point `Transformer.StreamState` / `transformStreamLine` at `sa` — stream state accumulates across chunks by design. Anthropic path (`messagesStreaming`) keeps `allocator` for `transformStreamLineToAnthropic` outputs; optionally apply the same scratch-arena only if its transformer contract allows (verify before touching).

**Acceptance:** [ ] 30-minute continuous stream → RSS stable within ±10 MB

---

## 5. Architecture & Performance Assessment (multi-request handling)

Answering your question directly: **yes, there are architectural constraints worth knowing about.** None are bugs; all are trade-offs of the "blocking server, avoid `std.Io` threading" strategy the migration chose.

| # | Observation | Impact | Recommendation |
|---|-------------|--------|----------------|
| A1 | **Fixed blocking worker pool; one connection monopolizes one worker for the whole stream** (LLM streams run seconds→minutes). Pool size = `server.http_pool_size` (small default). Extra requests sit in kernel backlog → head-of-line latency spikes. | High under concurrency | Short term: raise `http_pool_size` (threads are cheap; blocked-on-upstream ≈ 8 KB stack + idle fd). Medium term: spawn-per-connection with a cap, or async accept loop |
| A2 | **No upstream connection pooling**: fresh `std.http.Client` (+TCP+TLS handshake) per request adds ~100–300 ms to remote providers. | Medium (latency) | Cache one client per provider behind a mutex, or per-worker clients; measure TLS handshake share first |
| A3 | **HTTP keep-alive unsupported** (every response `Connection: close`) → clients reconnect per request. Fine for localhost, but UI5/browser agents reuse sockets and will churn. | Low–Medium | Optional: loop `handleConnection` while `Connection: keep-alive` requested and body fully drained |
| A4 | **`DebugAllocator` in release builds**: safety-checked, slower paths than `SmpAllocator`. | Low (perf) | Build-option switch: `.safety=false` for ReleaseFast, or `std.heap.smp_allocator` |
| A5 | **Global mutable config singleton** (`core_config.set`) — read-only post-startup; acceptable. Metrics atomics: good. | — | None |

**Verdict:** architecture is fundamentally sound for a local dev proxy once F1–F5 land. A1 is the biggest lever for multi-request throughput; A2 is the biggest lever for per-request latency.

---

## 6. Consolidated Checklist

### P0 — crash fixes (do first)
- [x] F1 `ignoreSigpipe()` helper + calls in `main.zig`, `lib.zig`
- [x] F2 reorder pricing/pool init-defers in `main.zig` + `lib.zig serverThreadFn`
- [ ] Verify: curl-disconnect repro survives; 20× start/stop cycle clean

### P1 — correctness under load
- [x] F3 `time.init/deinit` + real Threaded backend; wire `init.environ` in CLI
- [x] F4 dynamic `sendSseEvent` (+100 KiB unit test)
- [x] F5 replace 3× `req.connection.?`
- [ ] Parallel-streaming + kill-upstream manual tests

### P2 — robustness/polish
- [x] F6 EINTR-safe `writeAll`
- [x] F7 accept retry/backoff
- [x] F8 LF header Content-Length
- [x] F9 fd double-close guard
- [x] F10 scratch arena in `chatStreaming`

### Validation gate
- [x] `zig build` (both targets: exe + dylib)
- [x] `zig build test` → 21/21 integration cases green
- [ ] New regression cases added (§7)
- [ ] Human co-worker code review → approval
- [ ] ⚠️ Commit only after explicit consent (per AGENTS.md workflow)

---

## 7. Regression Tests to Add (TDD-first per project workflow)

| Case | Setup | Expectation |
|------|-------|-------------|
| `case-N: disconnect-mid-stream` | Mock client closes socket after receiving SSE headers; proxy sends ≥1 chunk | Proxy stays alive; subsequent request succeeds (would have caught F1) |
| `case-N: large-sse-event` | Upstream emits 100 KiB single event | Client receives full event (F4) |
| `case-N: upstream-reset-mid-body` | Mock upstream RST during POST upload | Clean 502 to agent, no crash (F5) |
| `case-N: lf-only-framing` | Request with `\n` headers + body | Body parsed (F8) |

> Per AGENTS.md: discuss these cases with human co-worker before implementing.

---

## 8. Verified Zig 0.16 API Notes (for implementers)

| Fact | Source (stdlib) |
|------|----------------|
| `Io.Limit.nothing == 0`, `unlimited == maxInt` | `Io.zig:626-634` |
| `init_single_threaded`: failing alloc, both limits `.nothing`, **no signal handlers** | `Io/Threaded.zig:1674-1691` |
| `Threaded.init(gpa, InitOptions)`; `InitOptions.environ` defaults `.empty`; async_limit default = cpu_count−1 | `Io/Threaded.zig:1607+,1599-1602` |
| Threaded installs PIPE/IO handlers only when properly init'ed | `Io/Threaded.zig:1654-1662` |
| `std.start` has **no** SIGPIPE handling in 0.16 | grep of `start*.zig` |
| `Init.Minimal = { environ: Environ, args: Args }` | `process.zig:51-56` |
| `Sigaction` shape + sigemptyset usage pattern | `Io/Threaded.zig:1654-1661`, `posix.zig:131` |
| `SIG.IGN = @ptrFromInt(1)` (linux shape; verify darwin coercion) | `os/linux.zig:3952` |
| `Allocating.fromArrayList` takes ownership (source set to `.empty`) — SSEIterator error path safe | `Io/Writer.zig:2557-2576,2586-2590` |
| `Response.reader(buf) -> *Reader` points into request (heap-stable) | `http/Client.zig:736-742` |
| `std.time.ns_per_ms/ns_per_s` still exist | `time.zig:5-6` |
| `trimRight` renamed `trimEnd` | MIGRATION-0.16.md #1 |

---

## 9. Out of Scope / Follow-ups

- **FU-1** Upstream connection pooling (A2) — needs `std.http.Client` thread-safety audit in 0.16 first.
- **FU-2** Real OS environ for the dylib's Io backend (`_NSGetEnviron` on macOS / `/proc/self/environ` on Linux) so spawned `curl` inherits `PATH`; until then verify pricing auto-update still resolves curl (it may already be broken under `.empty` environ — check logs for "Failed to download pricing archive").
- **FU-3** HTTP keep-alive support (A3).
- **FU-4** Self-pipe/poll-based listener shutdown replacing close-under-accept.
- **FU-5** Spawn-per-connection or async accept loop (A1) — larger redesign, discuss first.
