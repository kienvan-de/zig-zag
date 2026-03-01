# STORIES.md - HAI Provider Implementation

## Overview

This document contains the user stories for implementing the HAI (Hyperspace AI) provider in zig-zag. HAI uses **OIDC Authorization Code Flow with PKCE** for authentication (browser-based login).

## Story Dependencies

```
Story 0 (Config) ──────────────────────────────────────────────┐
                                                               │
Story 1 (PKCE) ────────────────────┐                           │
                                   │                           │
Story 2 (OIDC Discovery) ──────────┼──▶ Story 3 (Token) ───────┼──▶ Story 5 (HAI Client) ──┬──▶ Story 6 (Integration)
                                   │                           │                           │
Story 4 (Auth Server) ─────────────┘───────────────────────────┘                           └──▶ Story 7 (Models)
```

## Story Summary

| # | Story | Description | Status |
|---|-------|-------------|--------|
| 0 | Config Design | HAI config structure, app_cache, ServerStatus enum | ✅ Done |
| 0.5 | Swift App Update | Update macOS app for ServerStatus enum | 🔲 TODO |
| 1 | PKCE Module | Reusable PKCE in `src/pkce.zig` | 🔲 TODO |
| 2 | OIDC Discovery | Reusable OIDC in `src/oidc.zig` | 🔲 TODO |
| 3 | Token Exchange | Token exchange & refresh via OIDC | 🔲 TODO |
| 4 | Auth Callback Server | Reusable auth server in `src/auth_server.zig` | 🔲 TODO |
| 5 | HAI Client | `src/providers/hai/client.zig`, types, transformer | 🔲 TODO |
| 6 | Server Init & Integration | Init flow, provider enum, handlers integration | 🔲 TODO |
| 7 | HAI Models Listing | Fetch models from HAI upstream | 🔲 TODO |

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

- [ ] Update Swift code to use `ServerStatus` enum instead of `bool running`
- [ ] Handle `ServerErrorCode` and display appropriate error messages to user
- [ ] Update UI to show different states:
  - **Stopped**: Gray indicator, "Start" button enabled
  - **Starting**: Yellow/orange indicator, "Starting..." label, buttons disabled
  - **Running**: Green indicator, "Stop" button enabled
  - **Error**: Red indicator, error message displayed, "Retry" or "Start" button

### Error Messages for UI

| Error Code | User-Friendly Message |
|------------|----------------------|
| `ConfigLoadFailed` | "Failed to load configuration. Check config.json" |
| `PortInUse` | "Port {port} is already in use" |
| `WorkerPoolInitFailed` | "Failed to initialize server threads" |
| `LogInitFailed` | "Failed to initialize logging" |
| `ThreadSpawnFailed` | "Failed to start server thread" |
| `AuthFailed` | "Authentication failed. Please try again" |

### Files

- `ui/macos/zig-zag/` (Swift source files)

### Dependencies

- Story 0 (Config Design) - must complete first

---

## Story 1: PKCE Module

**As a** developer  
**I want** a reusable PKCE module in root src  
**So that** any provider can use PKCE for secure OAuth2 flows

### Acceptance Criteria

- [ ] Generate cryptographically random 32-byte code verifier
- [ ] Base64URL encode (no padding) the verifier
- [ ] Generate SHA256 code challenge from verifier
- [ ] Place in `src/pkce.zig` for reuse

### Algorithm

```
1. Generate 32 random bytes
2. Base64URL encode (no padding) -> code_verifier
3. SHA256(code_verifier) -> hash
4. Base64URL encode hash (no padding) -> code_challenge
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

- `src/pkce.zig`

### Dependencies

None

---

## Story 2: OIDC Discovery Module

**As a** developer  
**I want** a reusable OIDC module in root src  
**So that** any provider can use OIDC discovery and token operations

### Acceptance Criteria

- [ ] Fetch `{auth_domain}{oidc_config_path}` from configured endpoint
- [ ] Parse JSON response into `OIDCConfig` struct
- [ ] Extract: `authorization_endpoint`, `token_endpoint`, `jwks_uri`, `end_session_endpoint`
- [ ] Cache OIDC configs in `app_cache.zig`
- [ ] Design with comptime for provider client integration
- [ ] Each provider client inits OIDC helper with its own config
- [ ] Place in `src/oidc.zig` for reuse

### Interface

```zig
pub const OIDCConfig = struct {
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    jwks_uri: []const u8,
    end_session_endpoint: ?[]const u8,
};

pub fn fetchConfig(allocator: Allocator, auth_domain: []const u8, oidc_config_path: []const u8) !OIDCConfig
```

### Files

- `src/oidc.zig`
- `src/cache/app_cache.zig` (extend from Story 0)

### Dependencies

- Story 0 (Config Design)

---

## Story 3: Token Exchange & Refresh

**As a** developer  
**I want** token exchange and refresh functionality in OIDC module  
**So that** authorization codes can be exchanged for access tokens

### Acceptance Criteria

- [ ] Exchange authorization code for tokens (access_token, refresh_token, id_token)
- [ ] Support PKCE code_verifier in exchange request
- [ ] Refresh access token using refresh_token
- [ ] Parse token response (expires_in, token_type)
- [ ] Store tokens in existing `token_cache.zig` (in-memory, no persistence)
- [ ] Handle token exchange errors

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

- `src/oidc.zig` (extend from Story 2)
- `src/cache/token_cache.zig` (existing, extend if needed)

### Dependencies

- Story 1 (PKCE Module)
- Story 2 (OIDC Discovery)

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

- `src/auth_server.zig`

### Dependencies

None (but discuss technical constraints before implementation)

### ⚠️ Technical Discussion Needed

- Port conflict handling
- Timeout behavior
- Threading model with worker-pool
- Error reporting to UI

---

## Story 5: HAI Client Implementation

**As a** developer  
**I want** the HAI provider client  
**So that** it can make authenticated API calls to Hyperspace AI

### Acceptance Criteria

- [ ] Initialize client with config (api_url, client_id, auth_domain, workspace_id, etc.)
- [ ] Add required headers: `Authorization`, `X-Hyperspace-Workspace`, `X-Include-Usage`
- [ ] Route requests to configured `chat_completions_path`
- [ ] Support both streaming and non-streaming requests
- [ ] Transform requests for Anthropic models (reuse existing anthropic transformer if model starts with `claude-*`)

### API Request Headers

```
Authorization: Bearer {access_token}
Content-Type: application/json
X-Hyperspace-Workspace: {workspace_id}
X-Include-Usage: true
```

### Files

- `src/providers/hai/client.zig`
- `src/providers/hai/types.zig`
- `src/providers/hai/transformer.zig`

### Dependencies

- Story 0 (Config Design)
- Story 1 (PKCE Module)
- Story 2 (OIDC Discovery)
- Story 3 (Token Exchange)
- Story 4 (Auth Callback Server)

---

## Story 6: Server Init Flow & Integration

**As a** user  
**I want** to use `hai/model-name` in API requests  
**So that** I can access Hyperspace AI models through zig-zag

### Acceptance Criteria

- [ ] Add server init flow using worker-pool threads
- [ ] Initialize all configured providers before starting proxy server
- [ ] Set `initializing` flag in `CServerStats` during init
- [ ] Clear `initializing` flag when all providers ready
- [ ] Add `hai` to `Provider` enum in `provider.zig`
- [ ] Update `handlers/chat.zig` to handle hai provider
- [ ] Update `handlers/models.zig` to list hai models
- [ ] Integration test cases (TBD per human decision)

### Auth Flow (on server init)

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

- `src/server.zig` (add init flow)
- `src/lib.zig` (update stats)
- `src/provider.zig`
- `src/handlers/chat.zig`
- `src/handlers/models.zig`

### Dependencies

- Story 5 (HAI Client)

---

## Story 7: HAI Models Listing

**As a** user  
**I want** to list available models from HAI  
**So that** I can see which models are accessible via the HAI provider

### Acceptance Criteria

- [ ] Implement `listModels()` in HAI client
- [ ] Fetch models from upstream: `{api_url}{models_path}`
- [ ] Add required headers: `Authorization`, `X-Hyperspace-Workspace`
- [ ] Parse response and transform to OpenAI models format
- [ ] Handle errors (auth failure, network error, etc.)

### Files

- `src/providers/hai/client.zig` (add `listModels`)
- `src/handlers/models.zig` (integrate HAI)

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
