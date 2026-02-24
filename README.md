# zig-zag

A high-performance LLM proxy written in Zig that provides a unified OpenAI-compatible API for multiple LLM providers.

## Features

- **OpenAI-Compatible API**: Drop-in replacement for OpenAI API clients
- **Multi-Provider Support**: Route requests to OpenAI, Anthropic, SAP AI Core, and compatible providers
- **Unified Model Namespace**: Access all models via `{provider}/{model}` format
- **Streaming Support**: Full SSE streaming for real-time responses
- **Protocol Translation**: Automatic request/response transformation between providers
- **Compatible Provider Mode**: Add OpenAI/Anthropic-compatible providers without code changes

## Supported Providers

| Provider | Type | Description |
|----------|------|-------------|
| `openai` | Native | OpenAI API |
| `anthropic` | Native | Anthropic Messages API |
| `sap_ai_core` | Native | SAP AI Core with OAuth authentication |
| Any | Compatible | OpenAI or Anthropic compatible APIs (Groq, Azure, etc.) |

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
  },
  "server": {
    "host": "127.0.0.1",
    "port": 8080
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

# List models
curl http://localhost:8080/v1/models
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat completion (streaming and non-streaming) |
| `/v1/models` | GET | List available models from all providers |

## Configuration

### Server Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `host` | string | `"0.0.0.0"` | Host address to bind |
| `port` | number | `8080` | Port number |

### Provider Options

#### Common Options

| Option | Type | Required | Default | Description |
|--------|------|----------|---------|-------------|
| `api_key` | string | Yes* | - | API key for authentication |
| `api_url` | string | No | Provider default | Base URL for API |
| `compatible` | string | No | - | `"openai"` or `"anthropic"` for compatible providers |
| `max_response_size_mb` | number | No | `10` | Maximum response size in MB |
| `retry_count` | number | No | `0` | Retry attempts on failure |
| `retry_delay_ms` | number | No | `1000` | Delay between retries |

#### Anthropic

```json
{
  "anthropic": {
    "api_key": "sk-ant-your-key",
    "api_url": "https://api.anthropic.com",
    "api_version": "2023-06-01"
  }
}
```

#### OpenAI

```json
{
  "openai": {
    "api_key": "sk-your-key",
    "api_url": "https://api.openai.com",
    "organization": "org-id"
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

#### Compatible Providers (e.g., Groq)

```json
{
  "groq": {
    "api_key": "gsk-your-key",
    "api_url": "https://api.groq.com/openai",
    "compatible": "openai"
  }
}
```

## Model Naming

All models are accessed using `{provider}/{model}` format:

```
anthropic/claude-sonnet-4-20250514
openai/gpt-4
sap_ai_core/gpt-4o
groq/llama-3.1-70b-versatile
```

## Development

### Run Tests

```bash
# Unit tests
zig build test

# Integration tests
zig build run:integration
```

### Project Structure

```
src/
├── main.zig              # Entry point
├── server.zig            # HTTP server
├── config.zig            # Configuration loader
├── router.zig            # Request routing
├── handlers/             # Request handlers
│   ├── chat.zig          # Chat completions
│   └── models.zig        # Models listing
└── providers/            # Provider implementations
    ├── openai/
    ├── anthropic/
    └── sap_ai_core/

test/
├── cases/                # Integration test cases
└── integration/          # Integration test framework
```

## License

See [LICENSE](LICENSE) for details.