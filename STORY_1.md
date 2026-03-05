# STORY-1: Replace External CLI Dependencies with Cross-Platform Zig-Native Code

## Summary

zig-zag currently shells out to 3 external CLI tools (`curl`, `tar`, `open`) in 4 source files. These tools are not guaranteed to exist on all platforms, and spawning child processes adds overhead and error surface. This story replaces them with cross-platform Zig-native implementations.

## Current State

| CLI | File | Call Site | Purpose |
|-----|------|-----------|---------|
| `curl` | `src/curl.zig` | `CurlClient.request()` | HTTP client for HAI auth (OIDC/OAuth) — SAP IAS servers send `CertificateRequest` during TLS handshake, unsupported by Zig stdlib |
| `curl` | `src/pricing.zig:282` | `downloadFile()` | Download pricing CSV tarball from GitHub |
| `tar` | `src/pricing.zig:310` | `extractFileFromArchive()` | Extract single file from `.tar.gz` archive |
| `tar` | `src/pricing.zig:343` | `extractArchive()` | Extract all files from `.tar.gz` to directory |
| `open` | `src/auth/callback_server.zig:185` | `openBrowser()` | Open default browser for HAI OIDC login |
| `open` | `src/providers/copilot/client.zig:291` | Device flow auth | Open browser for Copilot device flow HTML page |

## Tasks

### Task 1: Replace `open` with Cross-Platform Browser Launcher

**Files:** `src/auth/callback_server.zig`, `src/providers/copilot/client.zig`

**Problem:** Both files hardcode `"open"` which is macOS-only.

**Solution:** Create a `src/platform.zig` utility with a `openUrl()` function that uses comptime OS detection:

```zig
const builtin = @import("builtin");

pub fn openUrl(allocator: Allocator, url: []const u8) !void {
    const argv = switch (builtin.os.tag) {
        .macos => &[_][]const u8{ "open", url },
        .linux => &[_][]const u8{ "xdg-open", url },
        .windows => &[_][]const u8{ "cmd", "/c", "start", url },
        else => @compileError("Unsupported OS for browser open"),
    };
    // ... spawn child process
}
```

**Effort:** Small — straightforward platform switch, 2 call sites to update.

---

### Task 2: Replace `curl` in `pricing.zig` with Zig Stdlib `HttpClient`

**File:** `src/pricing.zig:282`

**Problem:** Uses `curl -sL` to download a tarball from GitHub. This is a plain HTTPS GET — no TLS client cert issues.

**Solution:** Use the existing `src/client.zig` `HttpClient` (Zig stdlib) which already supports HTTPS, redirects, and compression. Or use `std.http.Client` directly since this is a one-shot download.

**Effort:** Small — replace `downloadFile()` subprocess with stdlib HTTP client.

---

### Task 3: Replace `tar` in `pricing.zig` with Zig-Native tar/gzip

**File:** `src/pricing.zig:310, 343`

**Problem:** Uses `tar xzf` to extract `.tar.gz` archives. Not available on Windows.

**Solution:** Zig stdlib includes `std.tar` and `std.compress.gzip` since 0.12:

```zig
const gzip = std.compress.gzip;
const tar = std.tar;

// Decompress + extract
var file = try std.fs.openFileAbsolute(archive_path, .{});
defer file.close();
var decompressed = gzip.decompressor(file.reader());
var piper = tar.pipeToFileSystem(dest_dir, decompressed.reader(), .{});
```

This eliminates both `extractFileFromArchive()` and `extractArchive()` subprocess calls.

**Effort:** Medium — need to handle the "extract single file to memory" case for `extractFileFromArchive()`.

---

### Task 4: Evaluate `curl` in `curl.zig` (HAI Auth)

**File:** `src/curl.zig`

**Problem:** This is the most complex case. SAP IAS servers send a `CertificateRequest` during TLS handshake. Zig's stdlib TLS implementation does not handle this gracefully and fails the connection. System `curl` handles it because it uses OpenSSL/LibreSSL which gracefully ignores unexpected `CertificateRequest`.

**Options:**

| Option | Pros | Cons |
|--------|------|------|
| **A. Keep `curl` (status quo)** | Works reliably, proven | External dependency, not cross-platform on Windows |
| **B. Link system OpenSSL** | Full TLS compat, no subprocess | Build complexity, platform-specific library paths |
| **C. Zig TLS patch** | Pure Zig, no deps | Upstream change needed, may break on Zig updates |
| **D. Ignore `CertificateRequest`** | Minimal change | Requires understanding of Zig TLS internals |

**Recommendation:** Keep `curl` for now (Option A). This is only used for HAI auth (SAP-internal), and `curl` is universally available on macOS and Linux. Revisit if Windows support becomes a priority.

**Effort:** N/A (keep as-is) or Large (Options B-D).

---

## Acceptance Criteria

- [ ] `open` calls replaced with cross-platform `platform.openUrl()`
- [ ] `pricing.zig` no longer shells out to `curl` — uses Zig HTTP client
- [ ] `pricing.zig` no longer shells out to `tar` — uses `std.tar` + `std.compress.gzip`
- [ ] `curl.zig` documented as intentional external dependency (HAI auth TLS compat)
- [ ] All platforms compile: `zig build` on macOS, Linux (Windows: compile-only, no HAI support)
- [ ] Integration tests pass: `zig build test`

## Priority

**Medium** — Current code works on macOS and Linux. This becomes high priority if Windows support is needed.

## Dependencies

- Zig 0.15 stdlib `std.tar` and `std.compress.gzip` APIs (verify compatibility)
- No external library dependencies

## Estimated Effort

| Task | Effort | Impact |
|------|--------|--------|
| Task 1: `open` → `platform.openUrl()` | Small (1-2 hours) | Cross-platform browser launch |
| Task 2: `curl` → Zig HTTP in pricing | Small (1-2 hours) | Remove `curl` dep for pricing |
| Task 3: `tar` → Zig-native in pricing | Medium (2-4 hours) | Remove `tar` dep entirely |
| Task 4: `curl.zig` evaluation | N/A (keep) | Documented decision |
| **Total** | **4-8 hours** | **2 of 3 external deps removed** |
