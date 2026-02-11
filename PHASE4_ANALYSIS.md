# Phase 4: Upstream Communication - Requirements Analysis

## Overview
Send transformed requests to Anthropic API and handle non-streaming responses.

## Requirements (from PLAN.md)

### Task 4.1: HTTP Client Implementation
- File: `src/upstream/anthropic_client.zig`
- POST to `https://api.anthropic.com/v1/messages`
- Headers: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`

### Task 4.2: Non-Streaming Response Handler
- Read full response body from Anthropic
- Transform: Anthropic.Response → OpenAI.Response (✅ done in Phase 3)
- Send JSON back to client

## What Phase 3 Already Completed ✅

- Provider routing (provider.zig)
- Request transformation (transformers/anthropic.zig)
- Response transformation (transformers/anthropic.zig)

**70% of Phase 4 logic already exists!**

## Remaining Work

1. HTTP client (`src/upstream/anthropic_client.zig`)
2. Server integration (`src/server.zig`)
3. Error handling (map Anthropic errors to OpenAI format)

## Scope

✅ Non-streaming requests only
❌ Streaming (Phase 5)

See full analysis in project documentation.
