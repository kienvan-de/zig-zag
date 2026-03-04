# AGENTS.md - AI Agent Context for zig-zag

## Overview

**zig-zag** is a blazing-fast LLM (Large Language Model) proxy written in **Zig**. It provides a unified OpenAI-compatible API that routes requests to multiple LLM providers (OpenAI, Anthropic, SAP AI Core, SAP HAI, GitHub Copilot, and any compatible provider).

| Aspect | Details |
|--------|---------|
| **Language** | Zig 0.15 |
| **Total LOC** | ~10,200 lines |
| **Purpose** | LLM API Gateway/Proxy |
| **API Style** | OpenAI-compatible REST API |
| **Platforms** | macOS (native app), Linux, Windows |

---

## Project Structure

```
zig-zag/
├── version.txt                  # Single source of truth for version (semver)
├── build.zig                    # Zig build configuration (reads version.txt)
├── src/
│   ├── main.zig                 # CLI entry point (56 LOC)
│   ├── lib.zig                  # C FFI library for macOS app (312 LOC)
│   ├── server.zig               # HTTP server implementation (297 LOC)
│   ├── router.zig               # Request routing (74 LOC)
│   ├── config.zig               # Configuration loader (321 LOC)
│   ├── client.zig               # HTTP client for upstream providers (432 LOC)
│   ├── curl.zig                 # Curl-based HTTP client for TLS-constrained servers (221 LOC)
│   ├── http.zig                 # HTTP utilities (59 LOC)
│   ├── metrics.zig              # CPU, memory, token, cost tracking (247 LOC)
│   ├── errors.zig               # Error types (100 LOC)
│   ├── log.zig                  # Logging system (446 LOC)
│   ├── utils.zig                # Utilities (56 LOC)
│   ├── worker_pool.zig          # Thread pool for concurrent requests (249 LOC)
│   ├── provider.zig             # Provider abstraction (137 LOC)
│   ├── auth/                    # Authentication modules
│   │   ├── mod.zig              # Auth module exports (45 LOC)
│   │   ├── oidc.zig             # OIDC discovery (415 LOC)
│   │   ├── oauth.zig            # OAuth token exchange & refresh (556 LOC)
│   │   ├── pkce.zig             # PKCE challenge generation (104 LOC)
│   │   └── callback_server.zig  # Local callback server for browser auth (345 LOC)
│   ├── cache/
│   │   ├── token_cache.zig      # OAuth token caching (238 LOC)
│   │   └── app_cache.zig        # Application-level cache (123 LOC)
│   ├── handlers/                # HTTP request handlers
│   │   ├── chat.zig             # /v1/chat/completions handler (641 LOC)
│   │   └── models.zig           # /v1/models handler (426 LOC)
│   ├── providers/               # LLM provider implementations
│   │   ├── openai/              # OpenAI provider
│   │   │   ├── client.zig       # API client (213 LOC)
│   │   │   ├── transformer.zig  # Request/response transformation (228 LOC)
│   │   │   └── types.zig        # Type definitions (954 LOC)
│   │   ├── anthropic/           # Anthropic/Claude provider
│   │   │   ├── client.zig       # API client (203 LOC)
│   │   │   ├── transformer.zig  # Protocol translation Messages API to OpenAI (870 LOC)
│   │   │   └── types.zig        # Type definitions (612 LOC)
│   │   ├── sap_ai_core/         # SAP AI Core provider
│   │   │   ├── client.zig       # Client with OAuth (334 LOC)
│   │   │   ├── transformer.zig  # Transformation (347 LOC)
│   │   │   └── types.zig        # Types (203 LOC)
│   │   ├── hai/                 # SAP HAI provider
│   │   │   └── client.zig       # Client with OIDC + browser auth (378 LOC)
│   │   └── copilot/             # GitHub Copilot provider
│   │       ├── client.zig       # Client with GitHub OAuth + token exchange + device flow
│   │       └── device_flow.html # Browser auth page (embedded at compile time)
├── include/
│   └── zig-zag.h                # C header for FFI
├── ui/
│   └── macos/
│       └── zig-zag/             # Native macOS menu bar app (Swift)
├── test/
│   ├── integration/             # Integration test framework
│   └── cases/                   # Integration test cases
├── README.md                    # Main documentation
├── AGENTS.md                    # This file
└── justfile                     # Development tasks (build, test, release)
```

---

## Core Components

| Component | File(s) | Purpose |
|-----------|---------|---------|
| **HTTP Server** | `server.zig`, `router.zig` | Accept incoming requests, route to handlers |
| **Request Handlers** | `handlers/chat.zig`, `handlers/models.zig` | Process `/v1/chat/completions` and `/v1/models` endpoints |
| **Provider System** | `provider.zig`, `providers/*/` | Abstract interface for multiple LLM backends |
| **HTTP Client** | `client.zig` | Zig stdlib HTTP client for upstream providers |
| **Curl Client** | `curl.zig` | System curl wrapper for servers requiring client cert TLS |
| **Auth System** | `auth/` | OIDC discovery, OAuth token exchange/refresh, PKCE, browser auth |
| **Configuration** | `config.zig` | Load `~/.config/zig-zag/config.json` |
| **Metrics** | `metrics.zig` | Track performance, tokens, and costs |
| **Worker Pool** | `worker_pool.zig` | Thread pool for concurrent request handling |
| **C FFI** | `lib.zig`, `zig-zag.h` | Expose functions for macOS Swift app |

---

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat completion (streaming & non-streaming) |
| `/v1/models` | GET | List available models from all configured providers |

---

## Supported Providers

| Provider | Auth Type | Special Features |
|----------|-----------|------------------|
| **OpenAI** | API Key | Native support |
| **Anthropic** | API Key | Protocol translation (Messages API to OpenAI format) |
| **SAP AI Core** | OAuth 2.0 Client Credentials | Token caching, automatic refresh |
| **HAI** | OIDC + Browser Auth | Browser login, token refresh, uses curl for auth (TLS compat) |
| **Copilot** | GitHub OAuth + Token Exchange | Reads `~/.config/github-copilot/apps.json`, device flow fallback, dynamic `api_base` |
| **Compatible** | API Key | Any OpenAI/Anthropic-compatible API |

---

## HTTP Client Architecture

zig-zag has two HTTP clients with the same interface (`get`/`post` methods):

| Client | File | Used For | Why |
|--------|------|----------|-----|
| **HttpClient** | `client.zig` | API calls (chat, models) | Fast, Zig native stdlib |
| **CurlClient** | `curl.zig` | HAI auth flow (OIDC, OAuth) | SAP IAS servers send CertificateRequest during TLS handshake, unsupported by Zig stdlib |

Auth functions in `auth/oidc.zig` and `auth/oauth.zig` use `anytype` parameters to accept either client via comptime duck typing.

---

## macOS App

A native Swift menu bar application located in `ui/macos/zig-zag/`:
- Starts/stops the Zig server via C FFI
- Displays real-time metrics (memory, CPU, network I/O, tokens, costs)
- Communicates with Zig code via `include/zig-zag.h` header

---

## Versioning

Single source of truth: **`version.txt`** at the project root (semver format, e.g. `0.3.2`).

### How It Works

```
version.txt ──@embedFile──> build.zig ──build options──> main.zig (CLI: --version)
                                                          lib.zig  (C API: getVersion())
```

- `build.zig` reads `version.txt` via `@embedFile` and injects it as a compile-time build option into all executable and library targets.
- `src/main.zig` supports `--version` / `-v` flag and logs the version on startup.
- `src/lib.zig` exports `getVersion()` via C FFI so the macOS Swift app can display it.
- The macOS Xcode project has its own `MARKETING_VERSION` in `project.pbxproj` — kept in sync by the release recipe.

### Bumping Version

```bash
just release patch   # 0.3.1 → 0.3.2
just release minor   # 0.3.2 → 0.4.0
just release major   # 0.4.0 → 1.0.0
```

This single command:
1. Reads current version from `version.txt`
2. Bumps it according to semver
3. Updates `version.txt`
4. Updates Xcode `MARKETING_VERSION` in `project.pbxproj`
5. Commits all changes
6. Creates a git tag `vX.Y.Z`

Then push with:

```bash
just push-release    # pushes main + tag → triggers GitHub Actions Release workflow
```

### Checking Version

```bash
just current-version          # reads from version.txt
./zig-out/bin/zig-zag --version  # prints "zig-zag X.Y.Z"
```

---

## Build Commands

```bash
zig build              # Build everything (default)
zig build run          # Build and run CLI
zig build exec:dbg     # Build debug executable
zig build exec:rls     # Build release executable (smallest size)
zig build lib:dbg      # Build debug shared library (for macOS app)
zig build lib:rls      # Build release shared library
zig build test         # Run integration tests
```

---

## Configuration

Location: `~/.config/zig-zag/config.json`

```json
{
  "server": {
    "host": "127.0.0.1",
    "port": 8080,
    "io_pool_size": 4
  },
  "providers": {
    "openai": { "api_key": "sk-..." },
    "anthropic": { "api_key": "sk-ant-..." },
    "sap_ai_core": {
      "api_domain": "...",
      "deployment_id": "...",
      "oauth_domain": "...",
      "oauth_client_id": "...",
      "oauth_client_secret": "..."
    },
    "hai": {
      "api_url": "...",
      "oidc_url": "...",
      "client_id": "...",
      "client_secret": "..."
    }
  }
}
```

---

## Key Patterns

### Provider Implementation
Each provider in `src/providers/` follows the same pattern:
- `client.zig` - HTTP client that talks to upstream API
- `transformer.zig` - Converts between OpenAI format and provider's native format
- `types.zig` - Zig structs for JSON serialization/deserialization

> **Note:** HAI and Copilot providers reuse OpenAI types and transformer since their APIs are OpenAI-compatible. They only have `client.zig` (plus `device_flow.html` for Copilot) for the auth flow.

### Request Flow
1. Request arrives at `server.zig`
2. `router.zig` routes to appropriate handler
3. Handler (`handlers/chat.zig` or `handlers/models.zig`) parses request
4. Provider's transformer converts request to native format
5. Provider's client sends request upstream
6. Response is transformed back to OpenAI format
7. Response sent to client (streaming or buffered)

### Streaming (SSE)
- Full Server-Sent Events support
- Protocol translation for Anthropic (different SSE format)
- Chunked transfer encoding for responses

### Auth Flow (HAI)
1. On first request, HAI client checks token cache
2. If no token, initiates OIDC browser auth (opens browser, local callback server)
3. Exchanges auth code for tokens via OAuth (with PKCE)
4. Caches tokens; auto-refreshes on expiry

---

## Testing

### Test Structure

```
test/
├── integration/              # Test framework
│   ├── main.zig              # Test orchestrator & runner
│   ├── mock_client.zig       # Simulates agent sending requests
│   ├── mock_upstream.zig     # Simulates LLM provider APIs
│   └── recorder.zig          # JSON recording utility
└── cases/                    # Test cases
    ├── case-1/
    ├── case-2/
    └── ...
```

### Test Case Files

Each test case folder (`test/cases/case-N/`) contains:

| File | Description |
|------|-------------|
| `config.json` | Test configuration - provider settings pointing to mock upstream |
| `agent_req.json` | Input - request from client to zig-zag proxy |
| `upstream_res.json` | Mock response - what the mock upstream server returns |
| `expected_upstream_req.json` | Expected - what proxy should send to upstream |
| `expected_agent_res.json` | Expected - what proxy should return to client |
| `upstream_req.json` | Actual output - recorded request sent to upstream (generated) |
| `agent_res.json` | Actual output - recorded response to client (generated) |

### Test Flow

```
Mock Client ---agent_req.json---> zig-zag Proxy ---upstream_req.json---> Mock Upstream
Mock Client <--agent_res.json--- zig-zag Proxy <--upstream_res.json--- Mock Upstream

Validation:
  - upstream_req.json == expected_upstream_req.json
  - agent_res.json == expected_agent_res.json
```

### Running Tests

```bash
zig build test
```

---

## Performance Targets

| Metric | Value |
|--------|-------|
| Memory footprint | ~21 MB |
| Startup time | < 10ms |
| Request latency overhead | < 1ms |
| Binary size | ~2 MB |

---

## Development Workflow

When working on new features or bug fixes, follow this collaborative workflow:

### 1. Write Integration Test First
- Create test case in `test/cases/case-N/`
- Define expected inputs and outputs
- Follow TDD approach

### 2. Discuss Test Case with Human
- Present the test case to human co-worker
- Adjust and finalize based on feedback

### 3. Implement Code
**Important considerations:**
- **Zig 0.15**: This project uses Zig 0.15 which has significantly different interfaces from 0.14 and older. Always verify API compatibility.
- **Avoid duplicate code**: Check existing utilities and patterns before creating new ones
- **Ask before organizing**: Do NOT make self-decisions on code organization. Ask human co-worker for guidance.
- **Debate if necessary**: If you disagree with a decision, present your reasoning and discuss

### 4. Code Review
- Request code review from human co-worker
- Address all feedback
- Finalize code only after approval

### 5. Run Integration Tests
```bash
zig build test
```

### 6. Fix Issues
- If tests fail, debug and fix
- Request re-review if changes are significant

### 7. Commit Code
- **Always get consent** from human co-worker before committing
- Write clear, descriptive commit messages
