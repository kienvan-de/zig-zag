# OpenAI /v1/chat/completions — Schema Gap Analysis

**Method:** Field-by-field comparison of OpenAI spec (openai-openapi master, 2026-08-27)
vs current zig-zag `src/core/providers/openai/types.zig`.
No assumptions — every gap is listed for review before implementation.

---

## REQUEST BODY

### Fields in spec but MISSING from zig-zag `Request` struct

| Field | Spec type | Crash risk | Notes |
|---|---|---|---|
| `reasoning_effort` | `?[]const u8` (enum: none/minimal/low/medium/high/xhigh/max) | No — silently dropped | Critical for o1/o3/o4-mini |
| `modalities` | `?[]const []const u8` (text/audio) | No | Audio output prereq |
| `audio` | `?std.json.Value` (voice + format) | No | Required for audio modality |
| `store` | `?bool` | No | Opt-in completion storage |
| `moderation` | `?std.json.Value` | No | Inline content moderation |
| `web_search_options` | `?std.json.Value` | No | Built-in web search config |
| `prediction` | `?std.json.Value` | No | Predicted outputs |
| `metadata` | `?std.json.Value` | No | Request-level metadata |
| `safety_identifier` | `?[]const u8` | No | Replaces deprecated `user` |
| `prompt_cache_key` | `?[]const u8` | No | Cache bucketing |
| `prompt_cache_retention` | `?[]const u8` | No | Deprecated; cache TTL |
| `prompt_cache_options` | `?std.json.Value` | No | `ttl` + `mode` |
| `service_tier` | `?[]const u8` | No | auto/default/flex/scale/priority/fast |
| `verbosity` | `?[]const u8` | No | low/medium/high |

### Fields in spec that have PARTIAL or WRONG handling

| Field | Issue |
|---|---|
| `stop` | Spec is `oneOf string \| string[] \| null`. zig-zag only parses array — `"stop": "\n"` (single string) hits `else => null` silently, not a crash but wrong: stop string is lost |
| `response_format` | Struct is `{ type: []const u8 }` only. Spec has `ResponseFormatJsonSchema` variant with `json_schema.name/schema/strict` sub-object — these fields are silently dropped |
| `stream_options` | Struct only has `include_usage`. Spec adds `include_obfuscation: ?bool` |
| `tool_choice` | Parsed as raw `std.json.Value` — no crash, but two new structured variants not documented: `allowed_tools` object and `custom` tool choice |

### Fields present in zig-zag that are DEPRECATED in spec (no action needed, still works)

| Field | Status |
|---|---|
| `max_tokens` | Deprecated; use `max_completion_tokens` |
| `seed` | Deprecated |
| `user` | Deprecated; use `safety_identifier`/`prompt_cache_key` |
| `functions` | Deprecated |
| `function_call` | Deprecated |

---

## REQUEST MESSAGES

### `Role` enum

| Role | In spec | In zig-zag |
|---|---|---|
| `system` | ✅ | ✅ |
| `user` | ✅ | ✅ |
| `assistant` | ✅ | ✅ |
| `tool` | ✅ | ✅ |
| `function` | ✅ (deprecated) | ✅ |
| `developer` | ✅ (new) | ❌ **CRASH** — `error.UnknownField` |

### `ContentPart` union (user/system/developer message content array items)

| Type | In spec | In zig-zag | Notes |
|---|---|---|---|
| `text` | ✅ | ✅ | |
| `image_url` | ✅ | ✅ | |
| `input_audio` | ✅ | ❌ **CRASH** — `error.UnexpectedToken` | |
| `file` | ✅ | ❌ **CRASH** — `error.UnexpectedToken` | |
| `refusal` | ✅ (assistant only) | ❌ **CRASH** — `error.UnexpectedToken` | Only in assistant content arrays |

### `ContentPart.text` — missing field

| Field | Spec | zig-zag |
|---|---|---|
| `prompt_cache_breakpoint` | optional `{ mode: "explicit" }` | ❌ missing — silently dropped |

### `ContentPart.image_url` — missing field

| Field | Spec | zig-zag |
|---|---|---|
| `prompt_cache_breakpoint` | optional | ❌ missing — silently dropped |

### `Message` (assistant role) — missing fields

| Field | Spec | zig-zag |
|---|---|---|
| `refusal` | `?[]const u8` | ❌ missing on inbound `Message` (present on outbound `ResponseMessage`) |
| `audio` | `?{ id: string }` (reference to prior audio) | ❌ missing |

---

## TOOL DEFINITIONS

### `Tool` variants in spec vs zig-zag

| Variant | Spec | zig-zag |
|---|---|---|
| `function` tool (`type: "function"`) | ✅ | ✅ |
| `custom` tool (`type: "custom"`, `custom.name`, `custom.description`, `custom.format`) | ✅ | ❌ — `type` field must be `"function"` or parse via `parseFromValueLeaky` which would accept it structurally but the `function` field would be required and missing |

### `tool_choice` variants in spec vs zig-zag

| Variant | Spec | zig-zag |
|---|---|---|
| `"none"` string | ✅ | ✅ (stored as raw Value) |
| `"auto"` string | ✅ | ✅ |
| `"required"` string | ✅ | ✅ |
| `{ type: "function", function: { name } }` | ✅ | ✅ (stored as raw Value) |
| `{ type: "allowed_tools", ... }` | ✅ (new) | ✅ (stored as raw Value — passes through) |
| `{ type: "custom", custom: { name } }` | ✅ (new) | ✅ (stored as raw Value — passes through) |

> `tool_choice` is already `?std.json.Value` — all variants pass through fine.

### `ToolCall` in assistant messages — missing variant

| Variant | Spec | zig-zag |
|---|---|---|
| `{ type: "function", ... }` | ✅ | ✅ |
| `{ type: "custom", custom: { name, input } }` | ✅ (new) | ❌ — `parseFromValueLeaky(ToolCall,...)` requires `type: "function"` shape; `custom` field missing — parse would silently lose `custom` field but not crash (struct has no strict discriminator) |

---

## RESPONSE

### `Response` struct — missing fields

| Field | Spec | zig-zag |
|---|---|---|
| `metadata` | `?std.json.Value` | ❌ missing — silently dropped |
| `moderation` | `?std.json.Value` | ❌ missing — silently dropped |

### `ResponseMessage` — matches spec well

| Field | Spec | zig-zag |
|---|---|---|
| `role` | ✅ | ✅ |
| `content` | ✅ | ✅ |
| `refusal` | ✅ | ✅ |
| `tool_calls` | ✅ | ✅ |
| `function_call` | ✅ (deprecated) | ✅ |
| `annotations` | ✅ | ✅ (opaque `std.json.Value`) |
| `audio` | ✅ | ✅ (opaque `std.json.Value`) |

### `ResponseChoice.logprobs` shape

| Field | Spec | zig-zag |
|---|---|---|
| `content` | required field inside logprobs object | ✅ passes through as opaque `std.json.Value` |
| `refusal` | required field inside logprobs object | ✅ passes through as opaque `std.json.Value` |

---

## STREAMING CHUNK

### `StreamChunk` — missing fields

| Field | Spec | zig-zag |
|---|---|---|
| `obfuscation` | `?[]const u8` | ❌ missing — silently dropped (no crash; `ignore_unknown_fields`) |
| `moderation` | `?std.json.Value` | ❌ missing — silently dropped |

### `StreamOptions` — missing field

| Field | Spec | zig-zag |
|---|---|---|
| `include_obfuscation` | `?bool` | ❌ missing — silently dropped |

### `Delta` (streaming) — `role` field coverage

| Role value | Spec | zig-zag |
|---|---|---|
| `"developer"` | ✅ in delta role enum | ❌ would crash on parse of `Delta.role` if explicitly set |

---

## USAGE

### `Usage` struct — sub-field coverage

Both `prompt_tokens_details` and `completion_tokens_details` are `?std.json.Value` in zig-zag — opaque pass-through. All sub-fields in spec (audio_tokens, cached_tokens, reasoning_tokens, text_tokens, etc.) pass through transparently.

**No gaps here.**

---

## SUMMARY TABLE

| # | Severity | Gap | Crash? | Location |
|---|---|---|---|---|
| G1 | 🔴 Critical | `role: "developer"` not in `Role` enum | YES — `error.UnknownField` | `types.zig` `Role` enum | ✅ fixed |
| G2 | 🔴 Critical | `ContentPart` type `"input_audio"` not handled | YES — `error.UnexpectedToken` | `types.zig` `ContentPart` | ✅ fixed |
| G3 | 🔴 Critical | `ContentPart` type `"file"` not handled | YES — `error.UnexpectedToken` | `types.zig` `ContentPart` | ✅ fixed |
| G4 | 🔴 Critical | `ContentPart` type `"refusal"` not handled (assistant content) | YES — `error.UnexpectedToken` | `types.zig` `ContentPart` | ✅ fixed |
| G5 | 🟠 High | `stop` single string silently ignored (not crash, wrong behavior) | No | `types.zig` `Request.jsonParseFromValue` | ✅ fixed |
| G6 | 🟠 High | `response_format` `json_schema` variant fields dropped | No | `types.zig` `ResponseFormat` | ✅ fixed |
| G7 | 🟠 High | `reasoning_effort` missing from `Request` | No | `types.zig` `Request` | ✅ fixed |
| G8 | 🟠 High | `modalities` + `audio` missing from `Request` | No | `types.zig` `Request` | ✅ fixed |
| G9 | 🟡 Medium | `stream_options.include_obfuscation` missing | No | `types.zig` `StreamOptions` | ✅ fixed |
| G10 | 🟡 Medium | `obfuscation` field missing from `StreamChunk` | No | `types.zig` `StreamChunk` | ✅ fixed |
| G11 | 🟡 Medium | `store` missing from `Request` | No | `types.zig` `Request` | ✅ fixed |
| G12 | 🟡 Medium | `moderation` missing from `Request`, `Response`, `StreamChunk` | No | `types.zig` | ✅ fixed |
| G13 | 🟡 Medium | `web_search_options` missing from `Request` | No | `types.zig` `Request` | ✅ fixed |
| G14 | 🟡 Medium | `metadata` missing from `Request` and `Response` | No | `types.zig` | ✅ fixed |
| G15 | 🟡 Medium | `prediction` missing from `Request` | No | `types.zig` `Request` | ✅ fixed |
| G16 | 🟡 Medium | `prompt_cache_breakpoint` missing from content parts | No | `types.zig` `ContentPart` | ✅ fixed |
| G17 | 🟡 Medium | `safety_identifier` + `prompt_cache_key` + `prompt_cache_options` missing | No | `types.zig` `Request` | ✅ fixed |
| G18 | 🟡 Medium | `verbosity` + `service_tier` missing from `Request` | No | `types.zig` `Request` | ✅ fixed |
| G19 | 🟡 Medium | `custom` tool type in `tools[]` not modeled | No | `types.zig` `Tool` | ⏭ skipped — `Tool` parsed via `parseFromValueLeaky`; unknown fields silently ignored |
| G20 | 🟡 Medium | `custom` tool call type in assistant `tool_calls[]` not modeled | No | `types.zig` `ToolCall` | ⏭ skipped — stored as `ToolCall` struct; `custom` field silently dropped but no crash |
| G21 | 🟡 Medium | `refusal` + `audio` missing from inbound `Message` (assistant role) | No | `types.zig` `Message` | ✅ fixed |
