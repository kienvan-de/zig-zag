# OpenAI vs Anthropic API Schema Differences

This document outlines the critical differences between OpenAI Chat Completions API and Anthropic Messages API that the proxy must handle.

---

## 1. System Prompt Handling

### OpenAI
```json
{
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Hello!"}
  ]
}
```

### Anthropic
```json
{
  "messages": [
    {"role": "user", "content": "Hello!"}
  ],
  "system": "You are a helpful assistant."
}
```

**Key Difference:**
- OpenAI: System prompt is a message with `role: "system"` in the messages array
- Anthropic: System prompt is a separate top-level `system` field (string)
- **Transformation:** Extract all system messages and concatenate into `system` field

---

## 2. Message Roles

### OpenAI
Supports: `"system"`, `"user"`, `"assistant"`, `"function"`, `"tool"`

### Anthropic
Supports: `"user"`, `"assistant"` ONLY

**Key Difference:**
- Anthropic does NOT support `"system"` role in messages array
- Anthropic does NOT support `"function"` or `"tool"` roles
- **Transformation:** Filter out system messages, handle only user/assistant

---

## 3. max_tokens Field

### OpenAI
```json
{
  "max_tokens": 1000  // OPTIONAL
}
```

### Anthropic
```json
{
  "max_tokens": 1024  // REQUIRED
}
```

**Key Difference:**
- OpenAI: `max_tokens` is optional
- Anthropic: `max_tokens` is REQUIRED (must be present)
- **Transformation:** Default to 4096 if not provided by client

---

## 4. Streaming Format

### OpenAI SSE Format
```
data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

data: [DONE]
```

### Anthropic SSE Format
```
event: message_start
data: {"type":"message_start","message":{...}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: message_stop
data: {"type":"message_stop"}
```

**Key Differences:**
- OpenAI: Uses `data:` prefix only, final message is `data: [DONE]`
- Anthropic: Uses `event:` + `data:` pairs, multiple event types
- OpenAI: Content in `delta.content`
- Anthropic: Content in `delta.text`
- **Transformation:** Map Anthropic events to OpenAI chunk format

---

## 5. Response Structure

### OpenAI Response
```json
{
  "id": "chatcmpl-123",
  "object": "chat.completion",
  "created": 1677652288,
  "model": "gpt-4",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "Hello!"
    },
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 10,
    "completion_tokens": 5,
    "total_tokens": 15
  }
}
```

### Anthropic Response
```json
{
  "id": "msg_01XFDUDYJgAACzvnptvVbrkw",
  "type": "message",
  "role": "assistant",
  "content": [
    {
      "type": "text",
      "text": "Hello!"
    }
  ],
  "model": "claude-3-5-sonnet-20241022",
  "stop_reason": "end_turn",
  "usage": {
    "input_tokens": 10,
    "output_tokens": 5
  }
}
```

**Key Differences:**
- OpenAI: `choices` array with `message.content` (string)
- Anthropic: `content` array with `type` and `text` (structured blocks)
- OpenAI: `finish_reason` in choice
- Anthropic: `stop_reason` at top level
- OpenAI: `total_tokens` included
- Anthropic: Only `input_tokens` and `output_tokens`
- **Transformation:** Map Anthropic response to OpenAI format

---

## 6. Authentication Headers

### OpenAI
```
Authorization: Bearer sk-proj-...
```

### Anthropic
```
x-api-key: sk-ant-...
anthropic-version: 2023-06-01
```

**Key Difference:**
- OpenAI: Uses Authorization header with Bearer token
- Anthropic: Uses custom `x-api-key` header + version header
- **Transformation:** Proxy uses Anthropic headers when forwarding

---

## 7. Stream Event Types

### Anthropic Stream Events
- `message_start`: Initial message metadata
- `content_block_start`: Start of content block
- `content_block_delta`: Incremental text chunks (the main content)
- `content_block_stop`: End of content block
- `message_delta`: Message metadata updates (stop_reason, etc.)
- `message_stop`: End of stream
- `ping`: Keep-alive (ignore)

### OpenAI Stream Chunks
- Initial chunk with `role`
- Content chunks with `delta.content`
- Final chunk with `finish_reason`
- `data: [DONE]` terminator

**Transformation Mapping:**
- `message_start` → initial chunk with `delta.role`
- `content_block_delta` → chunk with `delta.content`
- `message_stop` → final chunk with `finish_reason` + `data: [DONE]`
- `ping` → ignore (don't forward)

---

## 8. Message Alternation Requirement

### OpenAI
No strict alternation required. Consecutive messages of same role are allowed.

### Anthropic
**Requires alternating user/assistant messages.**

```json
// ❌ NOT ALLOWED by Anthropic
{
  "messages": [
    {"role": "user", "content": "First question"},
    {"role": "user", "content": "Second question"}
  ]
}

// ✅ ALLOWED
{
  "messages": [
    {"role": "user", "content": "First question\n\nSecond question"}
  ]
}
```

**Transformation:**
- Merge consecutive user messages with `\n\n` separator
- Merge consecutive assistant messages with `\n\n` separator

---

## 9. Field Support Comparison

| Field | OpenAI | Anthropic | Action |
|-------|--------|-----------|--------|
| model | ✅ Required | ✅ Required | Map model names |
| messages | ✅ Required | ✅ Required | Transform structure |
| max_tokens | ⚠️ Optional | ✅ Required | Default to 4096 |
| temperature | ✅ Optional | ✅ Optional | Pass through |
| top_p | ✅ Optional | ✅ Optional | Pass through |
| stream | ⚠️ Optional (default false) | ✅ Optional | Pass through |
| presence_penalty | ✅ Optional | ❌ Not supported | Ignore |
| frequency_penalty | ✅ Optional | ❌ Not supported | Ignore |
| n | ✅ Optional | ❌ Not supported | Ignore |
| stop | ✅ Optional | ✅ Optional (stop_sequences) | Map field name |
| user | ✅ Optional | ❌ Not supported | Ignore |
| system | ❌ In messages | ✅ Optional (top-level) | Extract from messages |

---

## 10. Error Response Format

### OpenAI Error
```json
{
  "error": {
    "message": "Invalid request",
    "type": "invalid_request_error",
    "code": "invalid_value"
  }
}
```

### Anthropic Error
```json
{
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "message": "Invalid request"
  }
}
```

**Transformation:**
- Map Anthropic error format to OpenAI error format
- Preserve error messages and types

---

## Summary of Critical Transformations

1. **Extract system messages** from messages array → `system` field
2. **Merge consecutive same-role messages** to satisfy Anthropic alternation
3. **Set default max_tokens** (4096) if not provided
4. **Map model names** (gpt-4 → claude-3-5-sonnet, etc.)
5. **Transform streaming events** (Anthropic SSE → OpenAI chunks)
6. **Restructure responses** (Anthropic content blocks → OpenAI message.content)
7. **Ensure first message is user** after system extraction
8. **Map stop_sequences** field name (stop → stop_sequences)