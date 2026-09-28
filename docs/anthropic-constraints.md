# Anthropic Messages API Constraints (`POST /v1/messages`)

> Source: official `anthropic-sdk-python` + `anthropic-sdk-typescript` (main) type stubs & docstrings,
> plus stable release docstrings (v0.39.0) for historical numeric ranges.
> Anthropic does **not** publish a machine-enforceable OpenAPI/JSON-schema publicly, so most
> constraints are **doc-only** (stated in field docs, enforced by the server at runtime).

---

## ⭐ Tool name — NO length/pattern limit

| Field | Constraint |
|-------|-----------|
| `tools[].name` | **None** — just "Name of the tool", type `string`. No `maxLength`, no `pattern`. |

This is the key contrast with OpenAI:

| Provider | tool name limit |
|----------|-----------------|
| Anthropic | **none** (any length, any chars) |
| OpenAI Chat Completions | 64 (doc-only) |
| OpenAI Responses | 128 (enforced) |

Confirmed empirically: Claude Code sent a 68-char MCP tool name to Anthropic successfully.

---

## Required fields

| Field | Type | Notes |
|-------|------|-------|
| `model` | string | required |
| `messages` | array | required |
| `max_tokens` | integer | required; **model-dependent max**. Set `0` to pre-warm prompt cache without generating |

---

## Documented numeric / size constraints

| Field | Constraint | Enforcement |
|-------|-----------|-------------|
| `messages` | **max 100,000 messages** per request | doc-only |
| `max_tokens` | ≥ 1; upper bound **varies by model** | runtime |
| `thinking.budget_tokens` | **≥ 1024** AND **< max_tokens** | runtime (counts toward max_tokens) |
| `temperature` | `0.0` … `1.0` (default 1.0) | **⚠ deprecated** — Opus 4.6+ rejects any value ≠ 1.0 with 400 |
| `top_p` | `0.0` … `1.0` | **⚠ deprecated** — Opus 4.6+ rejects (except ≥0.99 for back-compat) |
| `top_k` | integer > 0 | **⚠ deprecated** — Opus 4.6+ rejects any value with 400 |
| `stop_sequences` | array of strings (custom stop text) | — |
| `metadata.user_id` | opaque string (uuid/hash) — no PII | doc-only |

> Note: `temperature`, `top_p`, `top_k` are all now **deprecated** in the latest SDK. Older models
> still accept `temperature`/`top_p` in `[0,1]`. A proxy should forward them but be aware newer
> models return 400.

---

## Enum values (allowed sets)

| Field | Allowed values | Default |
|-------|---------------|---------|
| `messages[].role` | `user`, `assistant` (no `system` role — use top-level `system`) | — |
| `service_tier` | `auto`, `standard_only` | auto |
| `stream` | `true`, `false` | false |
| `system` | `string` OR array of `TextBlockParam` | — |
| `thinking.type` | `enabled`, `disabled`, `adaptive` | — |
| `thinking.display` (enabled/adaptive) | `summarized`, `omitted` | — |
| `tool_choice.type` | `auto`, `any`, `tool`, `none` | — |
| `tools[].type` | `custom` (or server-tool specific types) | custom |
| `tools[].allowed_callers` | `direct`, `code_execution_20250825`, `code_execution_20260120`, `code_execution_20260521` | — |
| content block `type` | `text`, `image`, `tool_use`, `tool_result`, `thinking`, `document`, … | — |
| image `source.type` | `base64`, `url`, `file` | — |

---

## Tool object (`tools[]`)

| Field | Constraint |
|-------|-----------|
| `name` | required, string, **no limit** |
| `input_schema` | required, JSON Schema; `type` must be `"object"` |
| `description` | optional (strongly recommended) |
| `strict` | bool — when true, guarantees schema validation on tool names & inputs |
| `cache_control` | optional ephemeral cache breakpoint |
| `defer_loading` | bool |
| `eager_input_streaming` | bool / null |

---

## Message content blocks

| Block | Key constraints |
|-------|-----------------|
| `text` | `text` string required |
| `image` | `source` (base64 / url / file); base64 needs `media_type` + `data` |
| `tool_use` | `id`, `name`, `input` |
| `tool_result` | `tool_use_id` required; `content` string or blocks; `is_error` bool |
| `thinking` | `thinking` text + `signature` |
| `document` | pdf/text/url sources |

---

## Fields WITHOUT documented constraints (forward as-is)

`model` (string), `system` (string/blocks), `container`, `inference_geo`,
`user_profile_id`, `workspace_id`, `output_config`, `cache_control`,
tool `input` shapes, `tool_result.content`.

These have **no** length/range keywords in the SDK; the server enforces model context
limits and semantic validation at runtime.

---

## Comparison summary vs OpenAI (for zig-zag transformers)

| Concern | Anthropic | OpenAI Chat | OpenAI Responses |
|---------|-----------|-------------|------------------|
| tool name length | none | 64 (doc) | 128 (enforced) |
| tool name pattern | none | `[a-zA-Z0-9_-]` | `^[a-zA-Z0-9_-]+$` |
| temperature | 0–1 (deprecated) | 0–2 | 0–2 |
| top_p | 0–1 (deprecated) | 0–1 | 0–1 |
| top_k | >0 (deprecated) | n/a | n/a |
| max tokens field | `max_tokens` (required) | `max_completion_tokens` | `max_output_tokens` (≥16) |
| system role | top-level `system` param | `system`/`developer` message | `instructions` / message |
| messages cap | 100,000 | none documented | none documented |

**Implication:** When translating Anthropic → OpenAI-family (SAP AI Core, OpenAI Chat, Copilot),
tool names that are legal for Anthropic (e.g. 68-char MCP names) may exceed the 64-char Chat limit
and must be normalized. The reverse (OpenAI → Anthropic) never needs tool-name shortening.
