# AGENTS.md - AI Agent Context for zig-zag

## Overview

**zig-zag** is a blazing-fast LLM (Large Language Model) proxy written in **Zig**. It provides a unified OpenAI-compatible API that routes requests to multiple LLM providers (OpenAI, Anthropic, SAP AI Core, and any compatible provider).

| Aspect | Details |
|--------|---------|
| **Language** | Zig |
| **Total LOC** | ~12,300 lines |
| **Purpose** | LLM API Gateway/Proxy |
| **API Style** | OpenAI-compatible REST API |
| **Platforms** | macOS (native app), Linux, Windows |

---

## Project Structure

```
zig-zag/
├── build.zig                    # Zig build configuration
├── src/                         # Main source code (~10,300 LOC)
│   ├── main.zig                 # CLI entry point (38 LOC)
│   ├── lib.zig                  # C FFI library for macOS app (222 LOC)
│   ├── server.zig               # HTTP server implementation (297 LOC)
│   ├── router.zig               # Request routing (74 LOC)
│   ├── config.zig               # Configuration loader (321 LOC)
│   ├── client.zig               # HTTP client for upstream providers (394 LOC)
│   ├── http.zig                 # HTTP utilities (59 LOC)
│   ├── metrics.zig              # CPU, memory, token, cost tracking (247 LOC)
│   ├── errors.zig               # Error types (100 LOC)
│   ├── log.zig                  # Logging system (446 LOC)
│   ├── utils.zig                # Utilities (56 LOC)
│   ├── worker_pool.zig          # Thread pool for concurrent requests (249 LOC)
│   ├── provider.zig             # Provider abstraction (42 LOC)
│   ├── handlers/                # HTTP request handlers
│   │   ├── chat.zig             # /v1/chat/completions handler (611 LOC)
│   │   └── models.zig           # /v1/models handler (413 LOC)
│   ├── providers/               # LLM provider implementations
│   │   ├── openai/              # OpenAI provider (~1,378 LOC)
│   │   │   ├── client.zig       # API client
│   │   │   ├── transformer.zig  # Request/response transformation
│   │   │   └── types.zig        # Type definitions
│   │   ├── anthropic/           # Anthropic/Claude provider (~1,685 LOC)
│   │   │   ├── client.zig       # API client
│   │   │   ├── transformer.zig  # Protocol translation (Messages API → OpenAI format)
│   │   │   └── types.zig        # Type definitions
│   │   └── sap_ai_core/         # SAP AI Core provider (~936 LOC)
│   │       ├── client.zig       # Client with OAuth
│   │       ├── transformer.zig  # Transformation
│   │       └── types.zig        # Types
│   └── cache/
│       └── token_cache.zig      # OAuth token caching (188 LOC)
├── include/
│   └── zig-zag.h                # C header for FFI (52 LOC)
├── ui/
│   └── macos/
│       └── zig-zag/             # Native macOS menu bar app (Swift)
├── test/
│   └── integration/             # Integration test framework
├── README.md                    # Main documentation
└── PLAN-HAI-PROVIDER.md         # Planning document
```

---

## Core Components

| Component | File(s) | Purpose |
|-----------|---------|---------|
| **HTTP Server** | `server.zig`, `router.zig` | Accept incoming requests, route to handlers |
| **Request Handlers** | `handlers/chat.zig`, `handlers/models.zig` | Process `/v1/chat/completions` and `/v1/models` endpoints |
| **Provider System** | `provider.zig`, `providers/*/` | Abstract interface for multiple LLM backends |
| **HTTP Client** | `client.zig` | Make upstream requests to LLM providers |
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
| **Anthropic** | API Key | Protocol translation (Messages API → OpenAI format) |
| **SAP AI Core** | OAuth 2.0 | Token caching, automatic refresh |
| **Compatible** | API Key | Any OpenAI/Anthropic-compatible API |

---

## macOS App

A native Swift menu bar application located in `ui/macos/zig-zag/`:
- Starts/stops the Zig server via C FFI
- Displays real-time metrics (memory, CPU, network I/O, tokens, costs)
- Communicates with Zig code via `include/zig-zag.h` header

---

## Build Commands

```bash
zig build              # Build everything
zig build run          # Build and run CLI
zig build exec:dbg     # Build debug executable
zig build exec:rls     # Build release executable
zig build lib:dbg      # Build debug library (for macOS app)
zig build lib:rls      # Build release library
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
| `config.json` | **Test configuration** - Provider settings pointing to mock upstream |
| `agent_req.json` | **Input** - Request from client to zig-zag proxy |
| `upstream_res.json` | **Mock response** - What the mock upstream server returns |
| `expected_upstream_req.json` | **Expected** - What proxy should send to upstream (for validation) |
| `expected_agent_res.json` | **Expected** - What proxy should return to client (for validation) |
| `upstream_req.json` | **Actual output** - Recorded request sent to upstream (generated) |
| `agent_res.json` | **Actual output** - Recorded response to client (generated) |

### Test Flow

```
┌─────────────┐    agent_req.json     ┌─────────────┐    upstream_req.json    ┌─────────────────┐
│ Mock Client │ ──────────────────────▶│  zig-zag    │ ───────────────────────▶│  Mock Upstream  │
│             │                        │   Proxy     │                         │                 │
│             │◀────────────────────── │             │◀─────────────────────── │                 │
└─────────────┘    agent_res.json      └─────────────┘    upstream_res.json    └─────────────────┘

Validation:
  - upstream_req.json == expected_upstream_req.json
  - agent_res.json == expected_agent_res.json
```

### Adding a New Test Case

1. **Create folder**: `test/cases/case-N/` (N = next number)

2. **Create required files**:
   ```bash
   test/cases/case-N/
   ├── config.json               # Provider config for this test
   ├── agent_req.json            # Input request
   ├── upstream_res.json         # Mock response from upstream
   ├── expected_upstream_req.json  # Expected transformed request
   └── expected_agent_res.json   # Expected response to client
   ```

3. **Example `config.json`**:
   ```json
   {
     "providers": {
       "openai": {
         "api_key": "test-openai-key",
         "api_url": "http://localhost:8001"
       }
     },
     "server": {
       "host": "127.0.0.1",
       "port": 8080
     }
   }
   ```

4. **Example `agent_req.json`** (client input):
   ```json
   {
     "model": "openai/gpt-4o",
     "messages": [
       {"role": "user", "content": "Hello!"}
     ]
   }
   ```

5. **Example `upstream_res.json`** (mock upstream response):
   ```json
   {
     "id": "chatcmpl-xxx",
     "object": "chat.completion",
     "model": "gpt-4o",
     "choices": [
       {
         "index": 0,
         "message": {"role": "assistant", "content": "Hi there!"},
         "finish_reason": "stop"
       }
     ],
     "usage": {"prompt_tokens": 5, "completion_tokens": 3, "total_tokens": 8}
   }
   ```

### Running Tests

```bash
zig build test
```

This will:
1. Start mock upstream servers
2. Start zig-zag proxy with test config
3. Send requests from `agent_req.json`
4. Compare actual outputs with expected files
5. Report pass/fail for each case

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
- Create test case in `test/cases/case-N/` (e.g., `test/cases/case-1/`)
- Define expected inputs and outputs
- Follow TDD (Test-Driven Development) approach

### 2. Discuss Test Case with Human
- Present the test case to human co-worker
- Adjust and finalize based on feedback
- Ensure test covers edge cases and requirements

### 3. Implement Code
**Important considerations:**
- ⚠️ **Zig 0.15**: This project uses Zig 0.15 which has **significantly different interfaces** from 0.14 and older versions. Always verify API compatibility.
- 🔄 **Avoid duplicate code**: Check existing utilities and patterns before creating new ones
- 🤝 **Ask before organizing**: Do NOT make self-decisions on code organization. Ask human co-worker for guidance on file placement, module structure, etc.
- 💬 **Debate if necessary**: If you disagree with a decision, present your reasoning and discuss

### 4. Code Review
- Request code review from human co-worker
- Address all feedback
- Finalize code only after approval

### 5. Run Integration Tests
```bash
zig build test
```
- Confirm all tests pass
- Verify no regressions

### 6. Fix Issues
- If tests fail, debug and fix
- Request re-review if changes are significant
- Iterate until all tests pass

### 7. Commit Code
- **Always get consent** from human co-worker before committing
- Write clear, descriptive commit messages
- Follow conventional commit format if applicable

### Workflow Summary

```
┌─────────────────┐
│ 1. Write Test   │
└────────┬────────┘
         ▼
┌─────────────────┐
│ 2. Discuss Test │◄──── Human Feedback
└────────┬────────┘
         ▼
┌─────────────────┐
│ 3. Implement    │──── Ask about code organization
└────────┬────────┘     Use Zig 0.15 APIs
         ▼
┌─────────────────┐
│ 4. Code Review  │◄──── Human Approval Required
└────────┬────────┘
         ▼
┌─────────────────┐
│ 5. Run Tests    │
└────────┬────────┘
         ▼
    ┌────┴────┐
    │ Pass?   │
    └────┬────┘
    No   │   Yes
    ▼    │    ▼
┌───────┐│┌─────────────────┐
│6. Fix │││ 7. Commit       │◄──── Human Consent Required
└───┬───┘│└─────────────────┘
    └────┘
```
