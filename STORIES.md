# STORIES.md - GitHub Copilot Provider

## Overview

Add GitHub Copilot as a native provider in zig-zag, enabling users to route LLM requests
through their GitHub Copilot subscription. The Copilot API is OpenAI-compatible, so we
reuse OpenAI types and transformer (same pattern as HAI provider).

---

## Auth Flow Summary

```
┌─────────────────────────────────────────────────────────────────────┐
│  LAYER 1: GitHub OAuth Access Token (long-lived)                    │
│                                                                      │
│  Primary: Read from ~/.config/github-copilot/apps.json              │
│           (written by VS Code, Zed, Neovim copilot extensions)      │
│           Key: "github.com:<client_id>" → oauth_token               │
│                                                                      │
│  Fallback: GitHub Device Flow                                        │
│    1. POST https://github.com/login/device/code                     │
│       body: { client_id }                                            │
│       → { device_code, user_code, verification_uri }                │
│    2. User visits URL and enters code                                │
│    3. Poll POST https://github.com/login/oauth/access_token         │
│       → { access_token }                                             │
│    4. Save to ~/.config/github-copilot/apps.json                    │
├─────────────────────────────────────────────────────────────────────┤
│  LAYER 2: Copilot API Token (short-lived ~30min, cached)            │
│                                                                      │
│  GET https://api.github.com/copilot_internal/v2/token               │
│  Headers: Authorization: token <access_token>                        │
│  → { token, expires_at, endpoints: { api: "<dynamic_base_url>" } }  │
│                                                                      │
│  Cache token in memory, refresh when expires_at is reached           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Configuration

```json
{
  "providers": {
    "copilot": {
      "client_id": "Iv1.b507a08c87ecfe98",
      "editor_version": "vscode/1.95.0",
      "editor_plugin_version": "copilot-chat/0.26.7",
      "user_agent": "GitHubCopilotChat/0.26.7",
      "api_version": "2025-04-01"
    }
  }
}
```

All fields optional. Defaults shown above (matching LiteLLM/VS Code values).

---

## Story 1: Copilot Token Management

**As a** zig-zag user with GitHub Copilot subscription,
**I want** zig-zag to automatically obtain and cache a valid Copilot API token,
**So that** I can make API calls without manual token management.

### Acceptance Criteria

1. On first request, read GitHub OAuth token from `~/.config/github-copilot/apps.json`
   using the configured `client_id` (default: `Iv1.b507a08c87ecfe98`)
2. Exchange OAuth token for Copilot API token via
   `GET https://api.github.com/copilot_internal/v2/token`
3. Cache the API token in memory with its `expires_at` timestamp
4. On subsequent requests, reuse cached token if not expired
5. When token expires, automatically re-fetch from token endpoint
6. Extract dynamic `api_base` URL from token response `endpoints.api`
7. If no token found in `apps.json` (or token is expired/invalid), automatically
   trigger GitHub Device Flow: open a browser page with the one-time code and a
   direct link to `https://github.com/login/device`, poll until authorized, and
   save the resulting token to `apps.json`

### Notes

- Device flow included in this story (approved during implementation)
- Device flow auth page is a self-contained HTML file embedded in the binary via
  `@embedFile` — no runtime file dependency
- Use `HttpClient.getUncompressed()` for token endpoint (GitHub returns gzip by default;
  Zig's low-level HTTP path does not auto-decompress)
- Token file path is always `~/.config/github-copilot/apps.json` (not configurable,
  this is the standard path used by all Copilot editor plugins)

---

## Story 2: Copilot Chat Completions (Non-Streaming)

**As a** zig-zag user,
**I want** to send `POST /v1/chat/completions` with model `copilot/<model-name>`,
**So that** my request is routed to the Copilot API and I get a response in OpenAI format.

### Acceptance Criteria

1. Request `copilot/gpt-4o` routes to Copilot provider
2. Request body is forwarded as-is (OpenAI-compatible, no transformation needed)
3. Required Copilot headers are injected:
   - `Authorization: Bearer <copilot_api_token>`
   - `content-type: application/json`
   - `copilot-integration-id: vscode-chat`
   - `editor-version: <from config>`
   - `editor-plugin-version: <from config>`
   - `user-agent: <from config>`
   - `openai-intent: conversation-panel`
   - `x-github-api-version: <from config>`
   - `x-request-id: <generated uuid>`
4. Response is returned in OpenAI format (extra fields like
   `content_filter_results` are ignored)
5. Provider is registered in `provider.zig` enum, `config.zig`, `handlers/chat.zig`,
   and `handlers/models.zig`

### Notes

- Reuse OpenAI types (`providers/openai/types.zig`)
- Reuse OpenAI transformer (`providers/openai/transformer.zig`)
- Only `client.zig` needed in `providers/copilot/` (same pattern as HAI)
- API base URL is dynamic (from token response), not hardcoded

---

## Story 3: Copilot Chat Completions (Streaming)

**As a** zig-zag user,
**I want** to send streaming requests to `POST /v1/chat/completions` with `stream: true`,
**So that** I get real-time SSE responses from Copilot.

### Acceptance Criteria

1. Request with `"stream": true` and model `copilot/<model-name>` works
2. SSE chunks are forwarded in OpenAI format
3. `[DONE]` marker is sent at end of stream
4. Same Copilot-specific headers as non-streaming
5. Token refresh works correctly during streaming setup

### Notes

- OpenAI SSE format, no translation needed (unlike Anthropic)
- Same as HAI streaming implementation pattern

---

## Story 4: Copilot Models Listing

**As a** zig-zag user,
**I want** `GET /v1/models` to include models from my Copilot subscription,
**So that** I can discover which models are available through Copilot.

### Acceptance Criteria

1. `GET /v1/models` fetches from `<api_base>/models` using Copilot API token
2. Response models are prefixed with `copilot/` (e.g., `copilot/gpt-4o`)
3. Models are merged with other providers in the aggregated response
4. Models response is cached (same pattern as HAI `app_cache`)
5. If token fetch fails, Copilot models are skipped (don't block other providers)

### Notes

- The `/models` endpoint returns `{ data: [...] }` in OpenAI format
- Model objects contain extra fields (`vendor`, `capabilities`, `model_picker_enabled`)
  which are ignored via `ignore_unknown_fields`

---

## Story 5: Provider Initialization

**As a** zig-zag operator,
**I want** the Copilot provider to validate its configuration on startup,
**So that** I get early feedback if something is misconfigured.

### Acceptance Criteria

1. On startup, if `copilot` is in config, attempt to fetch a Copilot API token
2. Log success with the dynamic API base URL
3. Log clear error if `apps.json` not found or token exchange fails
4. Provider init failure doesn't prevent other providers from starting

### Notes

- Same pattern as HAI/SAP AI Core init in `provider.zig`
- This validates the full token chain: apps.json → token endpoint → api_base

---

## Story 6: Integration Tests

**As a** developer,
**I want** integration tests covering the Copilot provider,
**So that** we catch regressions in request transformation and routing.

### Acceptance Criteria

1. Test case for non-streaming chat completion through Copilot
2. Test case for streaming chat completion through Copilot
3. Test verifies correct Copilot headers are sent to upstream
4. Test verifies model name mapping (`copilot/gpt-4o` → `gpt-4o` upstream)
5. Tests use mock upstream server (same framework as existing tests)

### Notes

- Auth is not tested in integration tests (mock server doesn't need real token)
- Focus on request/response transformation and header injection

---

## Future Stories (Out of Scope)

- **Embeddings**: `POST /v1/embeddings` support for Copilot
- **Token File Watching**: Watch `apps.json` for changes and auto-reload
