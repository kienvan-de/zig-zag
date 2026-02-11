# API Schema Samples

This directory contains JSON samples and documentation for understanding the differences between OpenAI and Anthropic APIs.

## Directory Structure

```
samples/
├── README.md                      # This file
├── SCHEMA_DIFFERENCES.md          # Detailed comparison of API schemas
├── transformation_example.md      # Step-by-step transformation examples
├── openai/                        # OpenAI API samples
│   ├── request_full.json         # Full request with all optional fields
│   ├── request_minimal.json      # Minimal valid request
│   ├── request_stream.json       # Streaming request example
│   ├── response.json             # Non-streaming response
│   └── stream_chunks.jsonl       # Streaming response chunks (SSE format)
└── anthropic/                     # Anthropic API samples
    ├── request_full.json         # Full request with system prompt
    ├── request_minimal.json      # Minimal valid request
    ├── request_stream.json       # Streaming request example
    ├── response.json             # Non-streaming response
    └── stream_events.txt         # Streaming SSE events with event types
```

## Quick Reference

### Key Differences

1. **System Prompt**
   - OpenAI: In messages array with `role: "system"`
   - Anthropic: Separate top-level `system` field

2. **max_tokens**
   - OpenAI: Optional
   - Anthropic: **Required** (proxy defaults to 4096)

3. **Message Roles**
   - OpenAI: `system`, `user`, `assistant`, `function`, `tool`
   - Anthropic: `user`, `assistant` only

4. **Streaming Format**
   - OpenAI: `data:` prefix, ends with `data: [DONE]`
   - Anthropic: `event:` + `data:` pairs, multiple event types

## Usage

### Testing Request Transformation

Use these samples to verify the proxy correctly transforms OpenAI requests to Anthropic format:

```bash
# Test with minimal request
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d @samples/openai/request_minimal.json

# Test with full request
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d @samples/openai/request_full.json

# Test streaming
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d @samples/openai/request_stream.json
```

### Validating JSON

All JSON files in this directory are valid and can be validated with:

```bash
python3 -m json.tool samples/openai/request_full.json
python3 -m json.tool samples/anthropic/response.json
```

## Documentation Files

### SCHEMA_DIFFERENCES.md
Comprehensive comparison of OpenAI vs Anthropic API schemas covering:
- System prompt handling
- Message roles
- Required vs optional fields
- Streaming formats
- Response structures
- Authentication headers
- Error formats

### transformation_example.md
Real-world examples showing:
- Simple transformations
- Edge cases (multiple system messages, consecutive user messages)
- Default value handling
- Streaming response transformation
- Model mapping table
- Field mapping reference

## Model Mapping

| OpenAI Model       | Anthropic Model                |
|--------------------|--------------------------------|
| gpt-4              | claude-3-5-sonnet-20241022    |
| gpt-4-turbo        | claude-3-5-sonnet-20241022    |
| gpt-3.5-turbo      | claude-3-5-haiku-20241022     |
| claude-* (native)  | Pass through as-is            |

## Critical Transformation Rules

1. **Extract system messages** → `system` field
2. **Merge consecutive same-role messages** (Anthropic requires alternation)
3. **Default max_tokens to 4096** if not provided
4. **Filter roles** to user/assistant only
5. **Transform streaming events** from Anthropic SSE to OpenAI chunks
6. **Ensure first message is user** after system extraction

## Testing Checklist

- [ ] Minimal request (user message only)
- [ ] Request with system prompt
- [ ] Request with multiple system messages
- [ ] Request with consecutive user messages
- [ ] Request without max_tokens (should default to 4096)
- [ ] Streaming request
- [ ] Non-streaming request
- [ ] Request with all optional parameters
- [ ] Error handling (invalid JSON, missing fields)
- [ ] Model name mapping

## Notes

- All samples use valid JSON that can be directly tested
- Stream samples (`.jsonl` and `.txt`) show the raw SSE format
- The proxy must handle all transformation rules to maintain OpenAI compatibility
- These samples are used as reference for Phase 2 (Data Modeling) test cases