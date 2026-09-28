# OpenAI Schema Constraints — Chat Completions & Responses

> Source: official `openai/openai-openapi` `openapi.yaml` (master). "Enforced" = machine-checkable
> keyword in the schema (`maxLength`, `pattern`, `minimum`, …). "Doc-only" = stated in the
> `description` text but **not** present as a validation keyword (server may or may not reject).

---

## ⭐ Tool / Function name — the important one

| API | Schema | Constraint | Enforcement |
|-----|--------|-----------|-------------|
| **Chat Completions** | `FunctionObject` (`tools[].function.name`, legacy `functions[].name`) | max **64** chars, `[a-zA-Z0-9_-]` | **Doc-only** (description text) — no `maxLength`/`pattern` keyword |
| **Responses** | `FunctionToolParam` (`tools[].name`) | **maxLength 128**, minLength 1, `pattern ^[a-zA-Z0-9_-]+$` | **Enforced** (schema keywords) |

Key takeaways:
- Chat Completions **documents** a 64-char limit but does not machine-enforce it in the schema.
  Real endpoints (and OpenAI-compatible backends like **SAP AI Core**) commonly enforce 64.
- Responses API allows up to **128** chars and enforces it structurally.
- The failing name in the log was **68 chars** → over 64 (Chat path), under 128 (Responses path).

Related:
- `ChatCompletionNamedToolChoice.function.name` — no length/pattern constraint.
- Responses `LiveFunctionToolChoiceParam.name` — minLength 1, **maxLength 64**, `^[a-zA-Z0-9_-]+$`.
- Beta `BetaFunctionToolParam.name` — maxLength **128**, minLength 1, `^[a-zA-Z0-9_-]+$`.

---

## Chat Completions — `CreateChatCompletionRequest`

| Field | Constraint |
|-------|-----------|
| `messages` | minItems 1 |
| `frequency_penalty` | minimum -2, maximum 2, default 0 |
| `presence_penalty` | minimum -2, maximum 2, default 0 |
| `top_logprobs` | minimum 0, maximum 20 |
| `logprobs` | default false |
| `n` | minimum 1, maximum 128, default 1 |
| `seed` | int64 range (-9.2e18 … 9.2e18) |
| `functions` (legacy) | minItems 1, maxItems 128 |
| `function_call` (legacy) | enum: `none`, `auto`, or `ChatCompletionFunctionCallOption` |
| `store` | default false |
| `stream` | default false |
| `logit_bias` | default null |
| `audio.format` | enum: wav, aac, mp3, flac, opus, pcm16 |
| `web_search_options.user_location` | enum: approximate |
| message content parts (each role) | minItems 1 |

Note: there is **no documented cap on `tools[]` count** in Chat Completions (only the legacy
`functions[]` has maxItems 128).

---

## Responses — `CreateResponse` / `CreateModelResponseProperties` / `ModelResponseProperties`

| Field | Constraint |
|-------|-----------|
| `max_output_tokens` | minimum 16 |
| `context_management` | minItems 1 |
| `truncation` | enum: auto, disabled (default disabled) |
| `parallel_tool_calls` | default true |
| `store` | default true |
| `stream` | default false |
| `top_logprobs` | minimum 0, maximum 20 |
| `temperature` | minimum 0, maximum 2 |
| `top_p` | minimum 0, maximum 1 |
| `safety_identifier` | maxLength 64 |
| `prompt_cache_key` (`CompactResponseMethodPublicBody`) | maxLength 64 |

### Responses tools

| Tool schema | Field | Constraint |
|-------------|-------|-----------|
| `FunctionToolParam` | `name` | minLength 1, **maxLength 128**, `^[a-zA-Z0-9_-]+$` |
| `MCPTool` | `tunnel_id` | `^tunnel_[a-z0-9]{32}$` |
| `MCPTool` / most tools | `allowed_callers` | minItems 1 |
| `ImageGenTool` | `output_compression` | 0–100 |
| `ImageGenTool` | `partial_images` | 0–3 |
| `AutoCodeInterpreterToolParam` | `file_ids` | maxItems 50 |
| `NamespaceToolParam` | `name` minLength 1; `tools` minItems 1 |
| `ApplyPatchToolCallItemParam` | `call_id` | minLength 1, maxLength 64 |
| `ToolSearchCallItemParam` | `call_id` | minLength 1, maxLength 64 |
| `ProgramToolCallCallerParam` | `caller_id` | minLength 1, maxLength 64 |

### Responses reasoning / output

| Field | Constraint |
|-------|-----------|
| `ReasoningItemResource.summary` | minItems 0, maxItems 2000 |

---

## File search (shared)

| Field | Constraint |
|-------|-----------|
| `AssistantToolsFileSearch.file_search.max_num_results` | 1–50 |
| FileSearch ranking `score_threshold` | 0–1 |

---

## Agent tool config (Responses agents — large caps)

| Field | Constraint |
|-------|-----------|
| `AgentToolConfigParamFunction.name` | 0 … 1048576 |
| `...Function.parameters` propertyNames | 1–256 chars; minProperties 0, maxProperties 1024 |
| `AgentToolConfigParamMcp.server_label` / `credential_id` | 0 … 1048576 |
| `...Mcp.allowed_tools` | minItems 0, maxItems 16384 (persisted resource: 2000) |
| `...WebSearch.allowed_domains` | maxItems 16384 (persisted: 2000) |

---

## Realtime / Live (not proxied by zig-zag, listed for completeness)

- `event_id` fields — maxLength 512
- `LiveResponsesDelegationSettings*.max_output_tokens` — minimum 16
- Audio PCM/PCMA/PCMU `rate` — fixed ranges (8000 / 16000–24000 / 8000)
- `RealtimeSessionCreateResponseGA.audio.output.speed` — 0.25–1.5
- `LiveMCPToolChoiceParam` / `LiveFunctionToolChoiceParam` `name` — 1–64, `^[a-zA-Z0-9_-]+$`
- `ResponsesClientEventResponseCreate.stream_id` — 1–256, `^[A-Za-z0-9_.-]+$`

---

## Enum values (allowed sets)

### Common request params (shared `$ref` enums)

| Field | Schema | Allowed values | Default |
|-------|--------|---------------|---------|
| `service_tier` | `ServiceTier` | `auto`, `default`, `flex`, `scale`, `priority`, `fast` | auto |
| `reasoning_effort` | `ReasoningEffort` | `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max` | medium |
| `verbosity` | `Verbosity` | `low`, `medium`, `high` | medium |
| `modalities` (items) | — | `text`, `audio` | — |

### Chat Completions request enums

| Field | Allowed values | Default |
|-------|---------------|---------|
| `audio.format` | `wav`, `aac`, `mp3`, `flac`, `opus`, `pcm16` | — |
| `function_call` (legacy) | `none`, `auto` (or object) | — |
| `web_search_options.user_location.type` | `approximate` | — |
| image content `image_url.detail` | `auto`, `low`, `high` | — |
| message `role` (per message type) | `system` / `developer` / `user` / `assistant` / `tool` / `function` | — |

### Responses request enums

| Field | Allowed values | Default |
|-------|---------------|---------|
| `truncation` | `auto`, `disabled` | disabled |
| `prompt_cache_retention` | `in_memory`, `24h` | — |
| `reasoning.summary` | `auto`, `concise`, `detailed` | — |
| `reasoning.context` | `auto`, `current_turn`, `all_turns` | — |
| `reasoning.generate_summary` | `auto`, `concise`, `detailed` | — |
| `response_format` / text `format.type` | `text`, `json_object`, `json_schema` | — |
| input message `role` | `user`, `system`, `developer` (assistant on output) | — |

### Output / status enums (responses you may parse back)

| Field | Allowed values |
|-------|---------------|
| `Response.status` | `completed`, `failed`, `in_progress`, `cancelled`, `queued`, `incomplete` |
| tool call `status` (function/computer/local_shell) | `in_progress`, `completed`, `incomplete` |
| `FileSearchToolCall.status` | `in_progress`, `searching`, `completed`, `incomplete`, `failed` |
| `CodeInterpreterToolCall.status` | `in_progress`, `completed`, `incomplete`, `interpreting`, `failed` |
| `ImageGenToolCall.status` | `in_progress`, `completed`, `generating`, `failed` |
| `ReasoningItem.status` | `in_progress`, `completed`, `incomplete` |
| output message `role` | `assistant` |

---

## Practical implications for zig-zag

1. **Tool-name limit is path-dependent:**
   - Chat Completions backends (OpenAI direct, **SAP AI Core**, Copilot, compatible) → treat as **64**.
   - Responses API → **128**.
   - Anthropic → **no limit** (verified separately from Anthropic SDK type defs).

2. The SAP AI Core failure (68-char MCP tool name) is a **Chat-path 64-char** issue, not universal.

3. If normalizing tool names, only do it on the **OpenAI Chat-completions-family transformers**,
   and cap at 64 (safest for that path); Responses could allow 128.
