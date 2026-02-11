# Configuration Guide

This document describes the configuration file format and available options for zig-zag.

## Configuration File Location

The configuration file is loaded from:
```
~/.config/zig-zag/config.json
```

## Configuration Structure

```json
{
  "providers": {
    "anthropic": { ... },
    "openai": { ... }
  },
  "server": {
    "port": 8080,
    "host": "0.0.0.0"
  }
}
```

## Server Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `host` | string | `"0.0.0.0"` | Host address to bind the server to |
| `port` | number | `8080` | Port number to listen on |

### Example

```json
{
  "server": {
    "host": "127.0.0.1",
    "port": 3000
  }
}
```

## Provider Configuration

Each provider section configures a specific LLM API provider.

### Common Options

| Option | Type | Required | Default | Description |
|--------|------|----------|---------|-------------|
| `api_key` | string | **Yes** | - | API key for authentication |
| `api_url` | string | No | Provider-specific | Base URL for API endpoints |
| `api_version` | string | No | Provider-specific | API version header |
| `timeout_ms` | number | No | `30000` | ⚠️ **Reserved for future implementation** - Request timeout in milliseconds |
| `max_response_size_mb` | number | No | `10` | Maximum response body size in megabytes |
| `retry_count` | number | No | `0` | Number of retry attempts on retryable errors |
| `retry_delay_ms` | number | No | `1000` | Delay between retry attempts in milliseconds |

### Anthropic Provider

```json
{
  "providers": {
    "anthropic": {
      "api_key": "sk-ant-api03-your-key-here",
      "api_url": "https://api.anthropic.com",
      "api_version": "2023-06-01",
      "timeout_ms": 30000,
      "max_response_size_mb": 10,
      "retry_count": 2,
      "retry_delay_ms": 1000
    }
  }
}
```

**Defaults:**
- `api_url`: `https://api.anthropic.com`
- `api_version`: `2023-06-01`

### OpenAI Provider

```json
{
  "providers": {
    "openai": {
      "api_key": "sk-your-openai-key-here",
      "organization": "org-your-org-id",
      "api_url": "https://api.openai.com",
      "timeout_ms": 30000,
      "max_response_size_mb": 10,
      "retry_count": 0,
      "retry_delay_ms": 1000
    }
  }
}
```

**Note:** OpenAI provider is not yet fully implemented.

## Retry Logic

When `retry_count` is greater than 0, the client will automatically retry failed requests.

### Retryable Errors

The following errors will trigger a retry:
- Network errors (connection failures, timeouts)
- Server errors (5xx status codes)
- Rate limit errors (429 status code)

### Non-Retryable Errors

The following errors will NOT be retried:
- Authentication errors (401 status code)
- Invalid request errors (4xx status codes except 429)
- Response parsing errors

### Retry Example

```json
{
  "retry_count": 3,
  "retry_delay_ms": 2000
}
```

This configuration will:
1. Make the initial request
2. If it fails with a retryable error, wait 2 seconds
3. Retry up to 3 times
4. Total attempts: 4 (1 initial + 3 retries)

## Timeout Configuration

**⚠️ Important:** The `timeout_ms` option is currently **reserved for future implementation**.

While you can set this value in the configuration, it is not yet enforced. The current implementation relies on:
- Operating system TCP/socket timeouts (typically ~60 seconds)
- HTTP client default behavior

Timeout functionality will be implemented in a future release when Zig's async/await system stabilizes.

## Complete Example

```json
{
  "providers": {
    "anthropic": {
      "api_key": "sk-ant-api03-your-anthropic-key",
      "api_url": "https://api.anthropic.com",
      "api_version": "2023-06-01",
      "timeout_ms": 30000,
      "max_response_size_mb": 20,
      "retry_count": 2,
      "retry_delay_ms": 1500
    },
    "openai": {
      "api_key": "sk-your-openai-key",
      "organization": "org-your-org-id",
      "api_url": "https://api.openai.com",
      "timeout_ms": 30000,
      "max_response_size_mb": 10,
      "retry_count": 0,
      "retry_delay_ms": 1000
    }
  },
  "server": {
    "host": "0.0.0.0",
    "port": 8080
  }
}
```

## Environment-Specific Configurations

### Development

```json
{
  "providers": {
    "anthropic": {
      "api_key": "sk-ant-test-key",
      "retry_count": 0,
      "max_response_size_mb": 5
    }
  },
  "server": {
    "host": "127.0.0.1",
    "port": 3000
  }
}
```

### Production

```json
{
  "providers": {
    "anthropic": {
      "api_key": "sk-ant-prod-key",
      "retry_count": 3,
      "retry_delay_ms": 2000,
      "max_response_size_mb": 20
    }
  },
  "server": {
    "host": "0.0.0.0",
    "port": 8080
  }
}
```

## Testing with Custom Endpoints

You can point to custom API endpoints for testing:

```json
{
  "providers": {
    "anthropic": {
      "api_key": "test-key",
      "api_url": "http://localhost:9000",
      "api_version": "2023-06-01"
    }
  }
}
```

This is useful for:
- Local development with mock servers
- Testing against staging environments
- Integration testing

## Notes

- All config values are optional except `api_key`
- Missing values will use documented defaults
- Invalid provider names in config will cause startup errors
- JSON comments are not supported (use this documentation for notes)