# Anthropic API Gap Checklist

Gaps between the current zig-zag implementation and the latest Anthropic Messages API.
Ordered by priority. Check off each item as it is fixed and tested.

---

## P0 — Correctness bugs (cause parse failures today)

- [x] **GAP-11** `types.zig` — Add `thinking` and `redacted_thinking` variants to response-side `ContentBlock` union
- [x] **GAP-2** `types.zig` — Add `none` variant to `ToolChoice` union

---

## P1 — High impact silent drops

- [x] **GAP-1** `types.zig` — Add `thinking` top-level request field (`ThinkingConfig` struct)
- [x] **GAP-15** `transformer.zig` — Handle `thinking_delta` in streaming (skip in OpenAI path); add `thinking`/`signature` to `DeltaContent` and `ContentBlockInfo`
- [x] **GAP-10** `types.zig` — Add `CacheControl` struct; add `cache_control` to `Tool` struct
- [x] **GAP-3** `types.zig` — Add `disable_parallel_tool_use` to all `ToolChoice` variants

---

## P2 — Medium impact (missing fields, not crashes)

- [x] **GAP-4** `types.zig` — Add `type` field to `Tool` (default `"custom"`); omit from serialization when default; add `defer_loading`, `strict`, `cache_control` fields
- [x] **GAP-5** `client.zig` — Forward `betas` as `anthropic-beta` header via `buildRequestHeaders`
- [x] **GAP-12** `types.zig` — Add `cache_creation_input_tokens` / `cache_read_input_tokens` to `Usage`; custom `jsonStringify` omits when null

---

## P3 — Low impact / niche fields

- [x] **GAP-6** `types.zig` — Add `service_tier: ?[]const u8` to `Request`
- [x] **GAP-7** `types.zig` — Add `output_config: ?OutputConfig` to `Request` (`OutputConfig` struct with `effort`, `format`)
- [x] **GAP-8** `types.zig` — Add `container: ?std.json.Value` to `Request`
- [x] **GAP-9** `types.zig` — Add `inference_geo: ?[]const u8` to `Request`
- [x] **GAP-13** `types.zig` — Add `container: ?std.json.Value` to `Response`; custom `jsonStringify` omits when null
- [x] **GAP-14** `types.zig` — Add `citations: ?std.json.Value` to `ContentBlock.text`; custom `jsonStringify` omits when null

---

## Files to modify

| File | Gaps |
|------|------|
| `src/core/providers/anthropic/types.zig` | GAP-1,2,3,4,5(betas field),6,7,8,9,10,11,12,13,14,15(DeltaContent) |
| `src/core/providers/anthropic/client.zig` | GAP-5 (header forwarding) |
| `src/core/providers/anthropic/transformer.zig` | GAP-15 (thinking_delta handling) |

`src/handlers/messages.zig` — no changes needed (handler is already schema-agnostic).

---

## Verification

After all fixes:
```
/opt/homebrew/opt/zig@0.16/bin/zig build
/opt/homebrew/opt/zig@0.16/bin/zig build test  # 21/21 green
```

Manual tests:
- POST `/v1/messages` with `tool_choice: {"type": "none"}` → no parse error
- POST `/v1/messages` with `thinking: {"type": "enabled", "budget_tokens": 1024}` → forwarded to Anthropic
- Response containing `thinking` content block → parsed without error
- Streaming response with `thinking_delta` → no crash, content forwarded or skipped cleanly
- POST with `cache_control` on system/content blocks → field preserved in outbound request
