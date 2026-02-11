# OpenAI to Anthropic Transformation Example

This document shows how the proxy transforms OpenAI requests to Anthropic format.

## Example 1: Simple Request with System Prompt

### Input (OpenAI Format)
```json
{
  "model": "gpt-4",
  "messages": [
    {
      "role": "system",
      "content": "You are a helpful assistant."
    },
    {
      "role": "user",
      "content": "Hello!"
    }
  ],
  "temperature": 0.7,
  "max_tokens": 1000
}
```

### Output (Anthropic Format)
```json
{
  "model": "claude-3-5-sonnet-20241022",
  "messages": [
    {
      "role": "user",
      "content": "Hello!"
    }
  ],
  "system": "You are a helpful assistant.",
  "max_tokens": 1000,
  "temperature": 0.7
}
```

**Key Transformations:**
- ✅ System message extracted from messages array → separate `system` field
- ✅ Model mapped: `gpt-4` → `claude-3-5-sonnet-20241022`
- ✅ max_tokens passed through (required by Anthropic)
- ✅ temperature passed through

---

## Example 2: Multiple System Messages (Edge Case)

### Input (OpenAI Format)
```json
{
  "model": "gpt-4",
  "messages": [
    {
      "role": "system",
      "content": "You are a helpful assistant."
    },
    {
      "role": "system",
      "content": "Always respond in a friendly tone."
    },
    {
      "role": "user",
      "content": "Hi there!"
    }
  ],
  "max_tokens": 500
}
```

### Output (Anthropic Format)
```json
{
  "model": "claude-3-5-sonnet-20241022",
  "messages": [
    {
      "role": "user",
      "content": "Hi there!"
    }
  ],
  "system": "You are a helpful assistant.\n\nAlways respond in a friendly tone.",
  "max_tokens": 500
}
```

**Key Transformations:**
- ✅ Multiple system messages merged with newlines
- ✅ All system messages removed from messages array

---

## Example 3: Consecutive User Messages (Normalization)

### Input (OpenAI Format)
```json
{
  "model": "gpt-4",
  "messages": [
    {
      "role": "user",
      "content": "What is 2+2?"
    },
    {
      "role": "user",
      "content": "And what is 3+3?"
    }
  ],
  "max_tokens": 100
}
```

### Output (Anthropic Format)
```json
{
  "model": "claude-3-5-sonnet-20241022",
  "messages": [
    {
      "role": "user",
      "content": "What is 2+2?\n\nAnd what is 3+3?"
    }
  ],
  "max_tokens": 100
}
```

**Key Transformations:**
- ✅ Consecutive user messages merged with double newlines
- ✅ Anthropic requires alternating user/assistant messages

---

## Example 4: Missing max_tokens (Default Handling)

### Input (OpenAI Format)
```json
{
  "model": "gpt-4",
  "messages": [
    {
      "role": "user",
      "content": "Hello!"
    }
  ]
}
```

### Output (Anthropic Format)
```json
{
  "model": "claude-3-5-sonnet-20241022",
  "messages": [
    {
      "role": "user",
      "content": "Hello!"
    }
  ],
  "max_tokens": 4096
}
```

**Key Transformations:**
- ✅ Missing `max_tokens` defaulted to 4096 (Anthropic requires this field)

---

## Example 5: Streaming Request

### Input (OpenAI Format)
```json
{
  "model": "gpt-4",
  "messages": [
    {
      "role": "user",
      "content": "Count to 5"
    }
  ],
  "stream": true,
  "max_tokens": 100
}
```

### Output (Anthropic Format)
```json
{
  "model": "claude-3-5-sonnet-20241022",
  "messages": [
    {
      "role": "user",
      "content": "Count to 5"
    }
  ],
  "stream": true,
  "max_tokens": 100
}
```

**Key Transformations:**
- ✅ `stream: true` passed through

---

## Streaming Response Transformation

### Anthropic SSE Event
```
event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
```

### Transformed to OpenAI Chunk
```json
{
  "id": "chatcmpl-123",
  "object": "chat.completion.chunk",
  "created": 1694268190,
  "model": "gpt-4-0613",
  "choices": [
    {
      "index": 0,
      "delta": {
        "content": "Hello"
      },
      "finish_reason": null
    }
  ]
}
```

**Key Transformations:**
- ✅ `content_block_delta` event → OpenAI chunk format
- ✅ `delta.text` → `delta.content`
- ✅ `message_stop` event → final chunk with `finish_reason: "stop"`

---

## Model Mapping Table

| OpenAI Model | Anthropic Model |
|--------------|-----------------|
| gpt-4 | claude-3-5-sonnet-20241022 |
| gpt-4-turbo | claude-3-5-sonnet-20241022 |
| gpt-3.5-turbo | claude-3-5-haiku-20241022 |
| claude-* (already Anthropic) | Pass through as-is |

---

## Field Mapping Reference

| OpenAI Field | Anthropic Field | Notes |
|--------------|-----------------|-------|
| `messages[].role` | `messages[].role` | "system" extracted to `system` field |
| `messages[].content` | `messages[].content` | Direct mapping |
| N/A (in messages) | `system` | Extracted from system role messages |
| `max_tokens` (optional) | `max_tokens` (required) | Default to 4096 if missing |
| `temperature` | `temperature` | Direct mapping |
| `top_p` | `top_p` | Direct mapping |
| `stream` | `stream` | Direct mapping |
| `frequency_penalty` | N/A | Ignored by Anthropic |
| `presence_penalty` | N/A | Ignored by Anthropic |
| `n` | N/A | Ignored (Anthropic doesn't support) |

---

## Headers Mapping

### OpenAI Headers
```
Authorization: Bearer sk-...
Content-Type: application/json
```

### Anthropic Headers
```
x-api-key: sk-ant-...
anthropic-version: 2023-06-01
content-type: application/json
```
