# Release Notes

## v0.2.1 (2026-03-02)

### ✨ New Features

#### Models Response Caching
- **Models list is now cached** in memory for each provider
- Subsequent `/v1/models` requests return instantly from cache
- Cache persists until server restart
- Significantly reduces API calls to upstream providers

#### Sorted Models Response
- **Models are now sorted alphabetically by ID** in `/v1/models` response
- Natural grouping by provider prefix (e.g., `anthropic/...`, `openai/...`, `sap_ai_core/...`)
- Consistent, predictable ordering across requests

### 📝 Documentation Updates

#### README.md Improvements
- **Fixed build commands**: Updated to use correct step names (`lib:rls`, `exec:dbg`, `exec:rls`)
- **Added server configuration table**: Complete reference for all `server` and `logging` options
- **Updated SAP HAI config**: Corrected fields and example configuration
- **Updated project structure**: Reflects current codebase with all source files

### 🔧 Internal Changes

- Added `name` field to `ProviderConfig` struct for cache key generation
- Cache key format: `models:{provider_name}`
- Fixed `models_path` for HAI provider to `/v1/models`

---

## Upgrade Notes

No breaking changes. This is a drop-in upgrade.

### Cache Behavior

The models cache has no TTL - it persists until the server is restarted. This is intentional since model lists rarely change. To refresh the models list:

1. Restart the zig-zag server, or
2. Restart the macOS app

---

## Previous Releases

### v0.2.0

- HAI provider integration with OIDC browser authentication
- Unified OAuth token handling across providers
- TLS compatibility fixes for HAI provider
- Apache 2.0 license

### v0.1.0

- Initial release
- OpenAI, Anthropic, SAP AI Core provider support
- OpenAI-compatible API (`/v1/chat/completions`, `/v1/models`)
- Full SSE streaming with protocol translation
- Native macOS menu bar app
- Real-time metrics (CPU, memory, network I/O, tokens, costs)
