# Integration Tests

This directory contains integration tests for the zig-zag proxy server.

## Overview

The integration tests validate end-to-end functionality by:

1. **Mock Client** - Simulates an agent/tool sending OpenAI Chat Completion requests
2. **Proxy Server** - The actual zig-zag proxy (built from source)
3. **Mock Upstream Servers** - Simulate provider APIs (Anthropic, OpenAI, Groq, etc.)
4. **Request/Response Recording** - All HTTP traffic is recorded to JSON files for inspection

## Directory Structure

```
test/
├── integration/
│   ├── main.zig           # Test orchestrator & test scenarios
│   ├── mock_client.zig    # Mock client implementation
│   ├── mock_upstream.zig  # Mock upstream server implementation
│   └── recorder.zig       # JSON recording utility
└── cases/
    ├── test_config.json   # Test configuration for proxy
    └── case-1/
        ├── agent_req.json
        ├── upstream_res.json
        ├── upstream_req.json
        ├── agent_res.json
        ├── expected_agent_res.json
        └── expected_upstream_req.json
```

## Running Tests

### Unit Tests Only (for test components)

```bash
zig build test:integration
```

This runs unit tests for the mock client, mock upstream, and recorder components.

### Full Integration Test Suite

```bash
# Build the proxy first
zig build

# Run full integration tests
zig build run:integration
```

This will:
1. Start mock upstream servers on ports 8001 (Anthropic), 8002 (OpenAI), 8003 (Groq)
2. Start the zig-zag proxy on port 8080
3. Execute test scenarios
4. Record all requests/responses to `test/cases/<case-name>/`

## Test Scenarios

### 1. OpenAI to Anthropic Transformation

- Client sends OpenAI format request with model `anthropic/claude-3-opus-20240229`
- Proxy transforms to Anthropic API format
- Mock upstream receives Anthropic format request
- Response is transformed back to OpenAI format

**Files recorded:**
- `client_request_000.json` - Original OpenAI request from client
- `client_response_000.json` - Transformed response to client
- `anthropic_request_000.json` - Transformed request to Anthropic API
- `anthropic_response_000.json` - Mock Anthropic response

### 2. OpenAI Passthrough

- Client sends OpenAI format request with model `openai/gpt-4`
- Proxy passes through to OpenAI-compatible upstream
- No transformation needed

### 3. Compatible Provider (Groq)

- Client sends request with model `groq/llama-3-70b-8192`
- Proxy uses OpenAI-compatible transformation (based on `compatible: "openai"` in config)
- Mock Groq upstream receives OpenAI-format request

### 4. Error Handling

- Tests invalid model names, malformed requests, upstream failures, etc.

## Inspecting Recorded Traffic

After running tests, check the case folder for JSON files:

```bash
ls -la test/cases/case-1/

# Example files:
# agent_req.json
# upstream_req.json
# upstream_res.json
# agent_res.json
# expected_agent_res.json
# expected_upstream_req.json
```

Each file contains:
- HTTP method and path
- Headers
- Body (pretty-printed JSON)

## Test Configuration

The test uses `test/cases/test_config.json` which points all providers to localhost mock servers:

```json
{
  "providers": {
    "anthropic": {
      "api_key": "test-anthropic-key",
      "api_url": "http://localhost:8001"
    },
    "openai": {
      "api_key": "test-openai-key",
      "api_url": "http://localhost:8002"
    },
    "groq": {
      "api_key": "test-groq-key",
      "api_url": "http://localhost:8003",
      "compatible": "openai"
    }
  },
  "server": {
    "host": "127.0.0.1",
    "port": 8080
  }
}
```

## Adding New Test Scenarios

1. Add test function in `test/integration/main.zig`
2. Use `ctx.client.sendChatCompletion()` to send requests
3. Add expected fixtures to the case folder (`expected_agent_res.json`, `expected_upstream_req.json`)
4. Validate recorded output against expected fixtures in the same case folder

Example:

```zig
test "New test scenario" {
    const allocator = std.testing.allocator;
    
    var ctx = try TestContext.init(allocator);
    defer ctx.deinit();
    
    try ctx.cleanRecordings();
    try ctx.startUpstreams();
    defer ctx.stopUpstreams();
    try ctx.startProxy();
    defer ctx.stopProxy() catch {};
    
    const messages =
        \\[
        \\  {"role": "user", "content": "Test message"}
        \\]
    ;
    
    const response = try ctx.client.sendChatCompletion(
        "provider/model-name",
        messages,
    );
    defer allocator.free(response);
    
    // Add assertions here
}
```

## Notes

- Tests run on localhost only
- Mock servers use fixed ports (ensure they're available)
- Recorded files are gitignored to keep repo clean
- Integration tests require the proxy to be built first (`zig build`)
- Tests are non-streaming (streaming support TBD)

## Troubleshooting

**Port already in use:**
```bash
# Check for processes using test ports
lsof -i :8080
lsof -i :8001
lsof -i :8002
lsof -i :8003
```

**Proxy not starting:**
- Ensure `zig build` completed successfully
- Check `zig-out/bin/zig-zag` exists
- Verify test config is valid JSON

**Tests hanging:**
- Check if mock servers started successfully
- Increase sleep timeouts in `main.zig` if needed
- Check for port conflicts

## Future Enhancements

- [ ] Add streaming tests when streaming support is implemented
- [ ] Add timeout/retry validation tests
- [ ] Add concurrent request tests
- [ ] Add response validation against expected fixtures
- [ ] Add performance/load testing scenarios