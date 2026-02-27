<p align="center">
  <img src="docs/logo.png" alt="zig-zag logo" width="120">
</p>

<h1 align="center">zig-zag</h1>

<p align="center">
  <strong>⚡ Blazing-fast LLM proxy written in Zig</strong>
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#macos-app">macOS App</a> •
  <a href="#configuration">Configuration</a> •
  <a href="#api">API</a>
</p>

---

## Why zig-zag?

- **🚀 Ultra-fast**: Written in Zig for maximum performance with minimal memory footprint (~21MB)
- **🔌 Universal**: One OpenAI-compatible API for all your LLM providers
- **🔄 Real-time**: Full SSE streaming support with protocol translation
- **🎯 Zero config**: Works out of the box, just add your API keys
- **🖥️ Native macOS app**: Beautiful menu bar app with real-time stats

## Features

| Feature | Description |
|---------|-------------|
| **OpenAI-Compatible API** | Drop-in replacement for any OpenAI client |
| **Multi-Provider** | OpenAI, Anthropic, SAP AI Core, and any compatible provider |
| **Unified Namespace** | Access all models via `{provider}/{model}` format |
| **Streaming** | Full SSE streaming with automatic protocol translation |
| **Real-time Metrics** | CPU, memory, network I/O, token usage, and cost tracking |
| **Cross-platform** | macOS (native app), Linux, Windows |

## Supported Providers

| Provider | Type | Description |
|----------|------|-------------|
| `openai` | Native | OpenAI API (GPT-4, GPT-4o, etc.) |
| `anthropic` | Native | Anthropic Messages API (Claude 3.5, Claude 4) |
| `sap_ai_core` | Native | SAP AI Core with OAuth authentication |
| Any | Compatible | OpenAI/Anthropic-compatible APIs (Groq, Azure, Together, etc.) |

## Quick Start

### 1. Build

```bash
zig build
```

### 2. Configure

Create `~/.config/zig-zag/config.json`:

```json
{
  "providers": {
    "anthropic": {
      "api_key": "sk-ant-your-key"
    },
    "openai": {
      "api_key": "sk-your-key"
    }
  }
}
```

### 3. Run

```bash
zig build run
```

### 4. Use

```bash
# Chat completion
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "anthropic/claude-sonnet-4-20250514",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# With streaming
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai/gpt-4o",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'

# List all models
curl http://localhost:8080/v1/models
```

## macOS App

zig-zag comes with a native macOS menu bar app for easy server management.

<p align="center">
  <img src="docs/menubar.png" alt="macOS Menu Bar App" width="280">
</p>

**Features:**
- One-click start/stop server
- Real-time statistics:
  - 💾 Memory usage (actual footprint, like `top`)
  - ⚡ CPU usage (calculated per-second)
  - 📊 Network I/O (rx/tx bytes)
  - 🔢 Token usage (input/output separately)
  - 💰 Cost tracking (input/output separately)
- Keyboard shortcuts (⌘Q to quit)

### Build the macOS App

```bash
# Build the Zig library
zig build lib:release

# Open in Xcode and build
open ui/macos/zig-zag/zig-zag.xcodeproj
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat completion (streaming & non-streaming) |
| `/v1/models` | GET | List available models from all providers |

## Configuration

### Server Options

```json
{
  "server": {
    "host": "127.0.0.1",
    "port": 8080,
    "io_pool_size": 4
  }
}
```

### Provider Examples

#### Anthropic

```json
{
  "anthropic": {
    "api_key": "sk-ant-your-key"
  }
}
```

#### OpenAI

```json
{
  "openai": {
    "api_key": "sk-your-key"
  }
}
```

#### SAP AI Core

```json
{
  "sap_ai_core": {
    "api_domain": "https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com",
    "deployment_id": "your-deployment-id",
    "resource_group": "your-resource-group",
    "oauth_domain": "https://your-tenant.authentication.us10.hana.ondemand.com",
    "oauth_client_id": "your-client-id",
    "oauth_client_secret": "your-client-secret"
  }
}
```

#### Compatible Providers (Groq, Azure, etc.)

```json
{
  "groq": {
    "api_key": "gsk-your-key",
    "api_url": "https://api.groq.com/openai",
    "compatible": "openai"
  }
}
```

### Provider Options Reference

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `api_key` | string | - | API key for authentication |
| `api_url` | string | Provider default | Base URL for API |
| `compatible` | string | - | `"openai"` or `"anthropic"` for compatible providers |
| `max_response_size_mb` | number | `10` | Maximum response size in MB |
| `retry_count` | number | `0` | Retry attempts on failure |
| `retry_delay_ms` | number | `1000` | Delay between retries |

## Model Naming

All models use the `{provider}/{model}` format:

```
anthropic/claude-sonnet-4-20250514
anthropic/claude-3-5-sonnet-latest
openai/gpt-4o
openai/gpt-4-turbo
sap_ai_core/gpt-4o
groq/llama-3.1-70b-versatile
```

## Development

### Build

```bash
# Build debug executable
zig build exec

# Build release executable
zig build exec:release

# Build debug library (for macOS app development)
zig build lib

# Build release library (for macOS app distribution)
zig build lib:release
```

### Run Tests

```bash
# Integration tests
zig build test
```

### Project Structure

```
├── src/
│   ├── main.zig              # CLI entry point
│   ├── lib.zig               # Library entry point (C API)
│   ├── server.zig            # HTTP server
│   ├── config.zig            # Configuration loader
│   ├── metrics.zig           # Metrics tracking (CPU, memory, tokens, costs)
│   ├── handlers/
│   │   ├── chat.zig          # Chat completions handler
│   │   └── models.zig        # Models listing handler
│   └── providers/
│       ├── openai/           # OpenAI provider
│       ├── anthropic/        # Anthropic provider
│       └── sap_ai_core/      # SAP AI Core provider
├── include/
│   └── zig-zag.h             # C header for FFI
├── ui/
│   └── macos/                # Native macOS app
└── test/
    ├── cases/                # Integration test cases
    └── integration/          # Integration test framework
```

## Performance

zig-zag is designed for minimal resource usage:

| Metric | Value |
|--------|-------|
| Memory footprint | ~21 MB |
| Startup time | < 10ms |
| Request latency overhead | < 1ms |
| Binary size | ~2 MB |

## License

MIT License - See [LICENSE](LICENSE) for details.

---

<p align="center">
  Made with ⚡ and 🦎 Zig
</p>
