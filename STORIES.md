# STORIES.md - HAI Provider Implementation

## Overview

This document contains the user stories for implementing the HAI (Hyperspace AI) provider in zig-zag. HAI uses **OIDC Authorization Code Flow with PKCE** for authentication (browser-based login).

## Story Dependencies

```
Story 0 (Config) ───────────────────────────────────────────────────────────┐
                                                                            │
Story 1 (PKCE) ────────────────────┐                                        │
                                   │                                        │
Story 2 (OIDC Discovery) ──────────┼──▶ Story 2.5 (Auth URL) ──▶ Story 3 ───┼──▶ Story 5 (HAI Client) ──┬──▶ Story 6
                                   │                                        │                           │
Story 4 (Auth Server) ─────────────┘────────────────────────────────────────┘                           └──▶ Story 7
```

## Story Summary

| # | Story | Description | Status |
|---|-------|-------------|--------|
| 0 | Config Design | HAI config structure, app_cache, ServerStatus enum | ✅ Done |
| 0.5 | Swift App Update | Update macOS app for ServerStatus enum | ✅ Done |
| 1 | PKCE Module | Reusable PKCE in `src/pkce.zig` | ✅ Done |
| 2 | OIDC Discovery | Reusable OIDC in `src/oidc.zig` | ✅ Done |
| 2.5 | Auth URL Builder | Build authorization URL with PKCE | ✅ Done |
| 3 | Token Exchange | Token exchange & refresh via OAuth | ✅ Done |
| 4 | Auth Callback Server | Reusable callback server in `src/auth/callback_server.zig` | ✅ Done |
| 5 | HAI Client | `src/providers/hai/client.zig`, types, transformer | ✅ Done |
| 6 | Server Init & Integration | Init flow, provider enum, handlers integration | ✅ Done |
| 7 | HAI Models Listing | Fetch models from HAI upstream | ✅ Done |

---

## Story 0: Configuration Design & Implementation

**As a** developer  
**I want** HAI provider configuration structure defined  
**So that** all components know how to read/store configuration

### Acceptance Criteria

- [x] Define HAI config structure (ALL fields required, NO hardcoded values):
  - HAI config works via existing `ProviderConfig` system (dynamic JSON parsing)
  - Sample config added to `config.json.example`
  ```json
  {
    "providers": {
      "hai": {
        "api_url": "https://api.hyperspace.tools.sap",
        "client_id": "your-oidc-client-id",
        "auth_domain": "https://your-tenant.accounts400.ondemand.com",
        "oidc_config_path": "/.well-known/openid-configuration",
        "workspace_id": "your-workspace-id",
        "redirect_port": 8335,
        "redirect_path": "/auth-code",
        "models_path": "/models",
        "chat_completions_path": "/v1/chat/completions"
      }
    }
  }
  ```
- [x] Create `src/cache/app_cache.zig` for caching OIDC discovery configs
- [x] Add server lifecycle status to `CServerStats` struct for UI
  - **Enhanced**: Replaced `bool initializing` with `ServerStatus` enum (Stopped/Starting/Running/Error)
  - **Added**: `ServerErrorCode` enum for detailed error reporting to UI

### Config Fields (ALL REQUIRED)

| Field | Description |
|-------|-------------|
| `api_url` | HAI API base URL |
| `client_id` | OIDC client ID |
| `auth_domain` | OIDC authentication domain |
| `oidc_config_path` | Path to OIDC discovery endpoint |
| `workspace_id` | HAI workspace ID |
| `redirect_port` | Local port for OAuth callback |
| `redirect_path` | Path for OAuth callback |
| `models_path` | Path to list models endpoint |
| `chat_completions_path` | Path to chat completions endpoint |

### Files

- `src/cache/app_cache.zig` - NEW: Generic key-value cache
- `include/zig-zag.h` - ServerStatus enum, ServerErrorCode enum, updated CServerStats
- `src/lib.zig` - Matching enums, atomic status tracking
- `config.json.example` - Added HAI provider sample
- `build.zig` - Fixed task names (exec:dbg, lib:dbg)

### Dependencies

None

---

## Story 0.5: Update macOS Swift App for ServerStatus

**As a** user  
**I want** the macOS menu bar app to show accurate server status  
**So that** I can see if the server is starting, running, stopped, or in error state

### Acceptance Criteria

- [x] Update Swift code to use `ServerStatus` enum instead of `bool running`
- [x] Handle `ServerErrorCode` and display appropriate error messages to user
- [x] Update UI to show different states:
  - **Stopped**: Gray indicator, "Start" button enabled
  - **Starting**: Yellow indicator, "Starting..." label, buttons disabled
  - **Running**: Green indicator, "Stop" button enabled
  - **Error**: Red indicator, error message displayed, "Start" button enabled

### Error Messages for UI

| Error Code | User-Friendly Message |
|------------|----------------------|
| `ConfigLoadFailed` | "Config load failed" |
| `PortInUse` | "Port in use" |
| `WorkerPoolInitFailed` | "Worker pool init failed" |
| `LogInitFailed` | "Log init failed" |
| `ThreadSpawnFailed` | "Thread spawn failed" |
| `AuthFailed` | "Auth failed" |

### Files Modified

- `ui/macos/zig-zag/zig-zag/ContentView.swift` - ServerStats struct, UI state handling
- `ui/macos/zig-zag/zig-zag/ServerState.swift` - stop/refresh logic
- `ui/macos/zig-zag/zig-zag/zig_zagApp.swift` - menu bar icon

### Dependencies

- Story 0 (Config Design) ✅ Complete

---

## Story 1: PKCE Module

**As a** developer  
**I want** a reusable PKCE module in root src  
**So that** any provider can use PKCE for secure OAuth2 flows

### Acceptance Criteria

- [x] Generate cryptographically random 32-byte code verifier
- [x] Base64URL encode (no padding) the verifier
- [x] Generate SHA256 code challenge from verifier
- [x] Place in `src/pkce.zig` for reuse

### Algorithm

```
1. Generate 32 random bytes
2. Base64URL encode (no padding) -> code_verifier (43 chars)
3. SHA256(code_verifier) -> hash
4. Base64URL encode hash (no padding) -> code_challenge (43 chars)
```

### Interface

```zig
pub const PKCE = struct {
    code_verifier: []const u8,   // Random 32 bytes, base64url encoded
    code_challenge: []const u8,  // SHA256(code_verifier), base64url encoded
};

pub fn generate(allocator: Allocator) !PKCE
pub fn deinit(self: *PKCE, allocator: Allocator) void
```

### Files

- `src/auth/pkce.zig` ✅ (moved from `src/pkce.zig`)

### Tests

- `zig test src/pkce.zig` - 2 tests pass
  - `generate produces valid PKCE pair` - verifies lengths and hash
  - `generate produces unique values` - verifies randomness

### Dependencies

None

---

## Story 2: OIDC Discovery Module

**As a** developer  
**I want** a reusable OIDC module in root src  
**So that** any provider can use OIDC discovery and token operations

### Acceptance Criteria

- [x] Fetch `{auth_domain}{oidc_config_path}` from configured endpoint
- [x] Parse JSON response into `OIDCConfig` struct
- [x] Extract: `authorization_endpoint`, `token_endpoint`, `jwks_uri`, `end_session_endpoint`
- [x] Cache OIDC configs in `app_cache.zig`
- [x] Design as member/component for provider client integration
- [x] Each provider client inits OIDC helper with its own config
- [x] Place in `src/oidc.zig` for reuse

### Interface

```zig
pub const OIDC = struct {
    allocator: Allocator,
    auth_domain: []const u8,
    config_path: []const u8,
    config: ?OIDCConfig,

    pub fn init(allocator: Allocator, auth_domain: []const u8, config_path: []const u8) OIDC;
    pub fn deinit(self: *OIDC) void;
    pub fn discover(self: *OIDC, http_client: *HttpClient) !*const OIDCConfig;
};

pub const OIDCConfig = struct {
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    jwks_uri: []const u8,
    end_session_endpoint: ?[]const u8,
};
```

### Caching Strategy

Two-level caching:
1. **Instance cache** (`self.config`) - fastest, no allocation
2. **App cache** (`app_cache`) - shared across instances, key: `oidc:{auth_domain}`
3. **HTTP fetch** - only on cache miss

### Files

- `src/auth/oidc.zig` ✅ (moved from `src/oidc.zig`)
- `src/cache/app_cache.zig` (existing, used for caching)

### Dependencies

- Story 0 (Config Design) ✅ Complete

---

## Story 2.5: Authorization URL Builder

**As a** developer  
**I want** to build OIDC authorization URLs with PKCE  
**So that** users can be redirected to authenticate via browser

### Acceptance Criteria

- [x] Build authorization URL with all required parameters
- [x] Generate random `state` parameter for CSRF protection
- [x] Include PKCE `code_challenge` and `code_challenge_method=S256`
- [x] URL-encode all parameters properly

### Authorization URL Parameters

| Parameter | Value |
|-----------|-------|
| `response_type` | `code` |
| `client_id` | from config |
| `redirect_uri` | `http://localhost:{redirect_port}{redirect_path}` |
| `scope` | `openid` |
| `state` | random 32-byte base64url string |
| `code_challenge` | from PKCE |
| `code_challenge_method` | `S256` |

### Interface

```zig
pub const AuthorizationParams = struct {
    client_id: []const u8,
    redirect_uri: []const u8,
    scope: []const u8,
    state: []const u8,
    code_challenge: []const u8,
};

pub const AuthorizationUrl = struct {
    url: []const u8,
    state: []const u8,  // caller needs this to verify callback
    
    pub fn deinit(self: *AuthorizationUrl, allocator: Allocator) void;
};

// In OIDC struct
pub fn buildAuthorizationUrl(self: *OIDC, allocator: Allocator, params: AuthorizationParams) !AuthorizationUrl;
```

### Files

- `src/auth/oidc.zig` (extend from Story 2)

### Dependencies

- Story 1 (PKCE Module)
- Story 2 (OIDC Discovery)

---

## Story 3: Token Exchange & Refresh

**As a** developer  
**I want** token exchange and refresh functionality in OIDC module  
**So that** authorization codes can be exchanged for access tokens

### Acceptance Criteria

- [x] Exchange authorization code for tokens (access_token, refresh_token, id_token)
- [x] Support PKCE code_verifier in exchange request
- [x] Refresh access token using refresh_token
- [x] Parse token response (expires_in, token_type)
- [ ] Store tokens in existing `token_cache.zig` (in-memory, no persistence) → Deferred to Story 6
- [x] Handle token exchange errors

### Token Exchange Request

```
POST {token_endpoint}
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code={authorization_code}
&redirect_uri=http://localhost:{redirect_port}{redirect_path}
&client_id={client_id}
&code_verifier={code_verifier}
```

### Token Refresh Request

```
POST {token_endpoint}
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token
&refresh_token={refresh_token}
&client_id={client_id}
```

### Interface

```zig
pub const TokenResponse = struct {
    access_token: []const u8,
    id_token: ?[]const u8,
    refresh_token: ?[]const u8,
    token_type: []const u8,
    expires_in: i64,
};

pub fn exchangeCode(allocator: Allocator, config: *OIDCConfig, params: ExchangeParams) !TokenResponse
pub fn refreshToken(allocator: Allocator, config: *OIDCConfig, refresh_token: []const u8, client_id: []const u8) !TokenResponse
```

### Files

- `src/auth/oauth.zig` (NEW)
- `src/auth/mod.zig` (update exports)

### Dependencies

- Story 1 (PKCE Module)
- Story 2 (OIDC Discovery)
- Story 2.5 (Authorization URL Builder)

---

## Story 4: Auth Callback Server

**As a** developer  
**I want** a reusable auth callback server in root src  
**So that** browser-based OAuth can complete for any provider

### Acceptance Criteria

- [ ] Start HTTP server on configurable port (`redirect_port`)
- [ ] Listen for GET request on configurable path (`redirect_path`)
- [ ] Extract `code` and `state` query parameters
- [ ] Validate `state` matches expected value (CSRF protection)
- [ ] Return success HTML page to browser
- [ ] Auto-open browser for authorization URL
- [ ] Timeout after configurable duration
- [ ] Shutdown server after receiving callback or timeout
- [ ] Place in `src/auth_server.zig` for reuse

### Interface

```zig
pub const AuthResult = struct {
    code: []const u8,
    state: []const u8,
};

pub const AuthServerConfig = struct {
    port: u16,
    path: []const u8,
    expected_state: []const u8,
    timeout_ms: u64,
};

pub fn waitForCallback(allocator: Allocator, config: AuthServerConfig) !AuthResult
pub fn openBrowser(url: []const u8) !void
```

### Success Response HTML

```html
<html>
<body>
<h1>Authentication successful!</h1>
<p>You can close this window.</p>
</body>
</html>
```

### Files

- `src/auth/callback_server.zig` ✅

### Acceptance Criteria

- [x] Start HTTP server on configurable port (`redirect_port`)
- [x] Listen for GET request on configurable path (`redirect_path`)
- [x] Extract `code` and `state` query parameters
- [x] Validate `state` matches expected value (CSRF protection)
- [x] Return success HTML page to browser
- [x] Auto-open browser for authorization URL (`openBrowser()`)
- [x] Timeout after configurable duration
- [x] Shutdown server after receiving callback or timeout

### Dependencies

None

---

## Story 5: HAI Client Implementation

**As a** developer  
**I want** the HAI provider client  
**So that** it can make authenticated API calls to Hyperspace AI

### Acceptance Criteria

- [x] Initialize client with config (api_url, client_id, auth_domain, workspace_id, etc.)
- [x] Add required headers: `Authorization`, `X-Hyperspace-Workspace`, `X-Include-Usage`
- [x] Route requests to configured `chat_completions_path`
- [x] Support both streaming and non-streaming requests
- [x] HAI is OpenAI-compatible (no transformation needed)
- [x] OIDC and OAuth as member components using global caches
- [x] Thread-safe token management with thundering herd protection

### API Request Headers

```
Authorization: Bearer {access_token}
Content-Type: application/json
X-Hyperspace-Workspace: {workspace_id}
X-Include-Usage: true
```

### Files

- `src/providers/hai/client.zig` ✅
- ~~`src/providers/hai/types.zig`~~ (reuses `openai/types.zig`)
- ~~`src/providers/hai/transformer.zig`~~ (HAI is OpenAI-compatible, no transformation)

### Dependencies

- Story 0 (Config Design) ✅
- Story 1 (PKCE Module) ✅
- Story 2 (OIDC Discovery) ✅
- Story 2.5 (Auth URL Builder) ✅
- Story 3 (Token Exchange) ✅
- Story 4 (Auth Callback Server) ✅

---

## Story 6: Server Init Flow & Integration

**As a** user  
**I want** to use `hai/model-name` in API requests  
**So that** I can access Hyperspace AI models through zig-zag

### Acceptance Criteria

- [x] Add `initProviders()` to `provider.zig` - loops through config, calls getAccessToken
- [x] Initialize all configured providers before starting proxy server
- [x] Status transitions: Starting → (init providers) → Running or Error
- [x] If at least 1 provider succeeds → start server; if all fail → exit with error
- [x] Add `hai` to `Provider` enum in `provider.zig`
- [x] Update `handlers/chat.zig` to handle hai provider
- [x] Update `handlers/models.zig` to list hai models
- [x] Update `main.zig` with app_cache init and provider init
- [x] Update `lib.zig` with app_cache init and provider init in serverThread
- [ ] Integration test cases (TBD per human decision)

### Auth Flow (on server startup)

```
1. Check if valid access_token exists (not expired)
   -> Yes: Use it
   -> No: Continue

2. Check if refresh_token exists (in token_cache)
   -> Yes: Try refresh
      -> Success: Use new access_token
      -> Fail: Continue to step 3
   -> No: Continue

3. Start browser auth flow:
   a. Generate PKCE
   b. Generate random state
   c. Build authorization URL
   d. Start callback server
   e. Open browser
   f. Wait for callback
   g. Exchange code for tokens
   h. Store tokens in token_cache
   i. Use access_token
```

### Files

- `src/provider.zig` ✅ (added `hai` to enum, added `initProviders()`)
- `src/handlers/chat.zig` ✅ (added HAI provider handling)
- `src/handlers/models.zig` ✅ (added HAI models listing)
- `src/main.zig` ✅ (added app_cache init, provider init)
- `src/lib.zig` ✅ (added app_cache init, provider init in serverThread)
- `src/providers/sap_ai_core/client.zig` ✅ (made `getAccessToken` public)
- `src/auth/callback_server.zig` ✅ (fixed Zig 0.15 API compatibility)

### Dependencies

- Story 5 (HAI Client)

---

## Story 7: HAI Models Listing

**As a** user  
**I want** to list available models from HAI  
**So that** I can see which models are accessible via the HAI provider

### Acceptance Criteria

- [x] Implement `listModels()` in HAI client
- [x] Fetch models from upstream: `{api_url}{models_path}`
- [x] Add required headers: `Authorization`, `X-Hyperspace-Workspace`
- [x] Parse response (OpenAI-compatible format)
- [x] Handle errors (auth failure, network error, etc.)
- [ ] Integrate with `handlers/models.zig` (Story 6)

### Files

- `src/providers/hai/client.zig` ✅ (`listModels` implemented)
- `src/handlers/models.zig` (integrate HAI - Story 6)

### Dependencies

- Story 5 (HAI Client)

---

## Key Decisions

| Decision | Choice |
|----------|--------|
| Provider name | `hai` |
| Directory | `src/providers/hai/` |
| Config values | **ALL REQUIRED** - NO hardcoded values (SAP compliance) |
| Token persistence | **No** - in-memory only via `token_cache.zig`, re-auth on restart |
| Unit tests | **No** - integration tests only (per human decision) |
| Server init | Worker-pool threads, block until all configured providers initialized |
| Ready flag | `initializing` field in `CServerStats` |
| Reusable modules | `src/pkce.zig`, `src/oidc.zig`, `src/auth_server.zig` |

---

## Example Usage

```bash
# Chat completion via HAI
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "hai/claude-3-5-sonnet-latest",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# First server start will trigger browser auth flow
# Subsequent requests use cached tokens (until restart)
```

---

## Error Handling

| Error | HTTP Status | Message |
|-------|-------------|---------|
| Auth timeout (browser) | 401 | "Authentication timed out. Please try again." |
| Invalid callback state | 401 | "Authentication failed: state mismatch" |
| Token refresh failed | 401 | "Session expired. Please re-authenticate." |
| Network error to HAI | 502 | "Failed to connect to Hyperspace AI" |
| Invalid workspace | 403 | "Workspace not found or access denied" |

---

## Security Considerations

1. **Never log tokens** - Access/refresh tokens must not appear in logs
2. **PKCE required** - Always use S256 code challenge method
3. **State validation** - Prevent CSRF attacks on callback
4. **Token expiry buffer** - Refresh tokens 5 minutes before expiry
