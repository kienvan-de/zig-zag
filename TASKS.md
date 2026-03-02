# TASKS.md - Story 1: Copilot Token Management

## Overview

Implement the two-layer token management for the Copilot provider:
1. Read GitHub OAuth token from `~/.config/github-copilot/apps.json`
2. If not found, run GitHub Device Flow (terminal-based login)
3. Exchange OAuth token for a short-lived Copilot API token
4. Cache the API token with expiry, auto-refresh when expired

---

## Task 1.1: Create `src/providers/copilot/client.zig` — Struct and Init

Create the CopilotClient struct with config parsing and initialization.

### What to implement

```zig
pub const CopilotClient = struct {
    allocator: Allocator,
    config: *const ProviderConfig,
    client: HttpClient,

    // Config values with defaults
    client_id: []const u8,             // default: "Iv1.b507a08c87ecfe98"
    editor_version: []const u8,        // default: "vscode/1.95.0"
    editor_plugin_version: []const u8, // default: "copilot-chat/0.26.7"
    user_agent: []const u8,            // default: "GitHubCopilotChat/0.26.7"
    api_version: []const u8,           // default: "2025-04-01"

    // Dynamic state
    api_base: ?[]const u8,        // from token response endpoints.api
    api_token: ?[]const u8,       // the short-lived copilot API token
    token_expires_at: i64,        // unix timestamp (seconds)
    token_mutex: std.Thread.Mutex, // protects token refresh

    pub fn init(allocator, provider_config) !CopilotClient
    pub fn deinit(self) void
};
```

### Details

- Extract config fields with defaults via `provider_config.getString("field") orelse DEFAULT`
- Initialize `HttpClient` with default timeout/response size (same pattern as HAI)
- `api_base`, `api_token` start as `null` / 0
- Define defaults as module-level constants

### Files touched
- `src/providers/copilot/client.zig` (NEW)

---

## Task 1.2: Read GitHub OAuth Token from `apps.json`

Implement reading the OAuth access token from the shared Copilot token file.

### What to implement

```zig
/// Read GitHub OAuth token from ~/.config/github-copilot/apps.json
/// Looks for key "github.com:<client_id>" -> oauth_token
/// Returns duplicated token string (caller must free)
fn readGitHubToken(self: *CopilotClient) ![]const u8
```

### Details

- Build path: `$HOME/.config/github-copilot/apps.json`
- Read and parse JSON
- Look up key `"github.com:<client_id>"` (using the configured client_id)
- Extract `oauth_token` field
- Return duplicated string
- Clear error messages when not found

### Files touched
- `src/providers/copilot/client.zig`

---

## Task 1.3: Exchange OAuth Token for Copilot API Token

Implement the token exchange with `api.github.com/copilot_internal/v2/token`.

### What to implement

```zig
/// GET https://api.github.com/copilot_internal/v2/token
/// Headers: Authorization: token <oauth_token>
/// Response: { token, expires_at, endpoints: { api: "..." } }
/// Updates self.api_token, self.api_base, self.token_expires_at
fn fetchCopilotToken(self: *CopilotClient, oauth_token: []const u8) !void
```

### Details

- Use `self.client.get()` (Zig stdlib HttpClient)
- Auth header uses `token` prefix (NOT `Bearer`)
- Parse response, update self fields (free old values before replacing)
- Error handling: 401 -> invalid token, 403 -> no subscription

### Files touched
- `src/providers/copilot/client.zig`

---

## Task 1.4: Add Device Flow to `src/auth/oauth.zig`

Add GitHub Device Flow as a reusable function in the oauth module,
following the same pattern as `exchangeCode()`, `refreshToken()`,
and `fetchClientCredentials()`.

### What to implement in `oauth.zig`

```zig
/// Parameters for device authorization flow
pub const DeviceFlowParams = struct {
    device_code_url: []const u8,
    token_url: []const u8,
    client_id: []const u8,
    scope: []const u8,
};

/// Result of device code request (step 1)
pub const DeviceCodeResponse = struct {
    allocator: Allocator,
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    expires_in: i64,
    interval: i64,

    pub fn deinit(self: *DeviceCodeResponse) void
};

/// Request a device code from the OAuth provider
/// POST <device_code_url> with client_id and scope
/// Returns DeviceCodeResponse (caller must deinit)
pub fn requestDeviceCode(
    allocator: Allocator,
    client: anytype,
    params: DeviceFlowParams,
) !DeviceCodeResponse

/// Poll for access token after user authorizes
/// POST <token_url> with device_code, polls until success or timeout
/// Handles: authorization_pending, slow_down, expired_token
/// Returns TokenResponse (caller must deinit)
pub fn pollDeviceToken(
    allocator: Allocator,
    client: anytype,
    params: DeviceFlowParams,
    device_code: []const u8,
    interval: i64,
    expires_in: i64,
) !TokenResponse
```

### Details

- Two separate functions: `requestDeviceCode` (step 1) and `pollDeviceToken` (step 2)
  - This lets the caller handle user interaction (printing, opening browser) between steps
- Both use `Content-Type: application/x-www-form-urlencoded` and `Accept: application/json`
- `pollDeviceToken` handles poll responses:
  - `{ "error": "authorization_pending" }` -> keep polling
  - `{ "error": "slow_down" }` -> increase interval by 5s
  - `{ "error": "expired_token" }` -> return error
  - `{ "access_token": "..." }` -> return TokenResponse
- Sleep between polls: `std.time.sleep(interval * std.time.ns_per_s)`
- Returns existing `TokenResponse` type (already defined in oauth.zig)

### What to implement in `auth/mod.zig`

- Re-export new types: `DeviceFlowParams`, `DeviceCodeResponse`

### Files touched
- `src/auth/oauth.zig`
- `src/auth/mod.zig`

---

## Task 1.5: Copilot Client Device Flow and Save Token

Wire up the oauth device flow helpers in CopilotClient with
user interaction (print instructions) and saving token to apps.json.

### What to implement

```zig
/// GitHub Device Flow - terminal-based authentication
/// 1. Request device code via auth.oauth.requestDeviceCode()
/// 2. Print instructions to stderr
/// 3. Poll for token via auth.oauth.pollDeviceToken()
/// 4. Save token to ~/.config/github-copilot/apps.json
/// Returns duplicated access_token (caller must free)
fn deviceFlow(self: *CopilotClient) ![]const u8

/// Save OAuth token to ~/.config/github-copilot/apps.json
/// Read-modify-write: preserves other entries in the file
fn saveTokenToAppsJson(self: *CopilotClient, access_token: []const u8) !void
```

### Details

- `deviceFlow()` orchestrates the two oauth.zig functions with user interaction:
  1. Call `auth.oauth.requestDeviceCode()`
  2. Print to stderr: "! First copy your one-time code: XXXX-XXXX"
     and "- Open https://github.com/login/device in your browser"
  3. Call `auth.oauth.pollDeviceToken()`
  4. Call `saveTokenToAppsJson()`
  5. Return duplicated access_token
- `saveTokenToAppsJson()`:
  - Read existing `apps.json` (or create `{}` if not found)
  - Parse JSON, add/update key `"github.com:<client_id>"`:
    ```json
    { "oauth_token": "<access_token>", "githubAppId": "<client_id>" }
    ```
  - Write back (preserving other entries)
  - Create directory `~/.config/github-copilot/` if not exists

### Files touched
- `src/providers/copilot/client.zig`

---

## Task 1.6: Implement `getAccessToken()` with Caching

Implement the main token accessor with caching and auto-refresh.

### What to implement

```zig
/// Get valid Copilot API token, refreshing if expired
/// Flow:
/// 1. Cached token valid? -> return it
/// 2. Lock mutex (double-check pattern)
/// 3. readGitHubToken() from apps.json
///    - not found -> deviceFlow() to get one
/// 4. fetchCopilotToken() to exchange for API token
/// 5. Return
pub fn getAccessToken(self: *CopilotClient) ![]const u8

fn isTokenValid(self: *CopilotClient) bool
```

### Details

- Validity check: `now < self.token_expires_at - 60` (60s buffer)
- Double-check locking with `self.token_mutex`
- Memory: free old `api_token` and `api_base` when refreshing

### Files touched
- `src/providers/copilot/client.zig`

---

## Task 1.7: Register Copilot in Provider System

Wire up the Copilot provider in the provider enum and initialization.

### What to implement

1. Add `copilot` to `Provider` enum in `provider.zig`
2. Add `fromString` mapping: `"copilot"` -> `.copilot`
3. Add `isSupported` case: `.copilot` -> `true`
4. Add init case in `initProvider` (same pattern as HAI)
5. Import CopilotClient at top of `provider.zig`

### Files touched
- `src/provider.zig`

---

## Task 1.8: Verify — Build and Manual Test

### Steps

1. `zig build` — must compile without errors
2. Add `"copilot": {}` to `~/.config/zig-zag/config.json`
3. `zig build run` — should show successful init with api_base
4. Test device flow: rename apps.json, run, complete auth in browser, verify token saved

### Files touched
- None (manual verification)

---

## Dependencies

```
Task 1.1 (struct and init)
  |-- Task 1.2 (read apps.json)
  |-- Task 1.3 (exchange token)
  |-- Task 1.4 (device flow in oauth.zig)  <-- reusable auth helper
        |-- Task 1.5 (copilot device flow + save to apps.json)
              |-- Task 1.6 (getAccessToken orchestrates all)
                    |-- Task 1.7 (register in provider system)
                          |-- Task 1.8 (verify)
```

---

## Out of Scope (Story 1)

- `sendRequest()`, `sendStreamingRequest()`, `listModels()` -> Story 2, 3, 4
- Registration in `handlers/chat.zig`, `handlers/models.zig` -> Story 2, 4
- Integration tests -> Story 6
