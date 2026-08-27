# SAP AI Core Orchestration API — Schema Gap Analysis

**Method:** Field-by-field comparison of the latest SAP AI Core Orchestration API spec
vs current zig-zag `src/core/providers/sap_ai_core/types.zig` + `transformer.zig`.
No assumptions — every gap listed for review before implementation.

---

## REQUEST BODY

### Top-level request fields

| Field | Spec | zig-zag | Notes |
|---|---|---|---|
| `config` | ✅ required | ✅ | |
| `placeholder_values` | `Record<string,string>` optional | ❌ missing | Template variable substitution — silently dropped |
| `messages_history` | `ChatMessage[]` optional | ❌ missing | Conversation context pre-pended to template — silently dropped |
| `config_ref` | `{ id: string }` (reference variant) | ❌ missing | Registry reference variant not modeled |

### `config.modules` — supported modules

| Module | Spec | zig-zag |
|---|---|---|
| `prompt_templating` | ✅ required | ✅ |
| `filtering` | optional | ❌ missing — not modeled |
| `masking` | optional | ❌ missing — not modeled |
| `grounding` | optional | ❌ missing — not modeled |
| `translation` | optional | ❌ missing — not modeled |

### `ModuleConfigs` as a list (fallback chain)

| Feature | Spec | zig-zag |
|---|---|---|
| `modules` as array (`ModuleConfigsList`) | ✅ | ❌ — only single `ModuleConfigs` object |

### `prompt_templating.model` — `LLMModelDetails`

| Field | Spec | zig-zag |
|---|---|---|
| `name` | ✅ required | ✅ |
| `version` | optional, default `"latest"` | ✅ |
| `params` | `Record<string,any>` — temperature, max_tokens, top_p, etc. | ❌ missing — model params never forwarded to upstream |
| `timeout` | number (seconds), default 600 | ❌ missing |
| `max_retries` | number, max 5, default 2 | ❌ missing |

### `prompt_templating.prompt` — `Template`

| Field | Spec | zig-zag |
|---|---|---|
| `template` | `ChatMessage[]` | ✅ (as `template` inside `PromptConfig`) |
| `tools` | `ChatCompletionTool[]` | ✅ |
| `tool_choice` | optional | ❌ missing from `transform()` — present in `PromptConfig` struct but never set by transformer |
| `defaults` | `Record<string,string>` — default placeholder values | ❌ missing |
| `response_format` | `ResponseFormatText \| ResponseFormatJsonObject \| ResponseFormatJsonSchema` | ❌ missing |

### `config.stream` — `GlobalStreamOptions`

| Field | Spec | zig-zag |
|---|---|---|
| `enabled` | ✅ | ✅ |
| `chunk_size` | optional, default 100, range 1–10000 | ✅ (field exists, always null) |
| `delimiters` | `string[]`, required when translation module used | ❌ missing |

---

## RESPONSE BODY

### Top-level `CompletionPostResponse`

| Field | Spec | zig-zag |
|---|---|---|
| `request_id` | ✅ required | ✅ |
| `intermediate_results` | ✅ required (`ModuleResults`) | ⚠️ partial — typed as `IntermediateResults` with only `templating` and `llm` fields |
| `final_result` | ✅ required (`LlmModuleResult`) | ✅ |
| `intermediate_failures` | `Error[]` optional | ❌ missing — silently dropped |

### `intermediate_results` — `ModuleResults`

| Field | Spec | zig-zag `IntermediateResults` |
|---|---|---|
| `templating` | `ChatMessage[]` | ✅ (as `?[]const OpenAI.Message`) |
| `llm` | `LlmModuleResult` | ✅ (as `?std.json.Value`) |
| `grounding` | `GenericModuleResult` | ❌ missing |
| `input_translation` | `InputTranslationModuleResult` | ❌ missing |
| `input_masking` | `GenericModuleResult` | ❌ missing |
| `input_filtering` | `GenericModuleResult` | ❌ missing |
| `output_filtering` | `GenericModuleResult` | ❌ missing |
| `output_translation` | `GenericModuleResult` | ❌ missing |
| `output_unmasking` | `LlmChoice[]` | ❌ missing |

### `LlmModuleResult` (= `final_result`)

| Field | Spec | zig-zag |
|---|---|---|
| `id`, `object`, `created`, `model` | ✅ | ✅ via `OpenAI.Response` |
| `choices` | ✅ | ✅ |
| `usage` | ✅ | ✅ |
| `system_fingerprint` | optional | ✅ (on `OpenAI.Response`) |
| `citations` | `Citation[]` optional — grounding results | ❌ missing — silently dropped |

### `ResponseChatMessage` (assistant message in response)

| Field | Spec | zig-zag |
|---|---|---|
| `role`, `content`, `refusal`, `tool_calls` | ✅ | ✅ via `OpenAI.ResponseMessage` |
| `reasoning_content` | `ReasoningBlock[]` optional | ❌ missing — silently dropped |

### `TokenUsage`

| Field | Spec | zig-zag |
|---|---|---|
| `prompt_tokens`, `completion_tokens`, `total_tokens` | ✅ | ✅ |
| `prompt_tokens_details` | optional (audio, cached, cache_creation, etc.) | ✅ opaque `std.json.Value` |
| `completion_tokens_details` | optional | ✅ opaque `std.json.Value` |

---

## TRANSFORMER GAPS

### `transform()` — OpenAI → SAP AI Core

| Gap | Impact |
|---|---|
| `tool_choice` never forwarded | Tool choice silently dropped even though `PromptConfig` has the field |
| Model params (`temperature`, `max_tokens`, `top_p`, `frequency_penalty`, `presence_penalty`, `stop`, `seed`, `n`, `response_format`, `logit_bias`, `logprobs`, `top_logprobs`) never forwarded to `LLMModelDetails.params` | All model parameters lost; model always uses its defaults |
| `response_format` never forwarded | Structured output / json_object mode unavailable |
| `stream_options.include_usage` not forwarded | Usage in final streaming chunk unavailable |
| `messages_history` / `placeholder_values` never populated | These are pass-through features; no mapping from OpenAI to SAP |

### `transformFromAnthropic()` — Anthropic → SAP AI Core

| Gap | Impact |
|---|---|
| Same as `transform()` — model params, tool_choice, response_format not forwarded | |
| `thinking` config (extended thinking) not forwarded | |

---

## SUMMARY TABLE

| # | Severity | Gap | Crash? |
|---|---|---|---|
| S1 | 🔴 Critical | Model params (`temperature`, `max_tokens`, `top_p`, etc.) never forwarded to `LLMModelDetails.params` | No — silent, model uses defaults |
| S2 | 🔴 Critical | `tool_choice` not forwarded in `transform()` despite `PromptConfig` having the field | No |
| S3 | 🟠 High | `response_format` not forwarded | No |
| S4 | 🟠 High | `filtering` module not modeled (content safety) | No |
| S5 | 🟠 High | `masking` module not modeled (data privacy) | No |
| S6 | 🟠 High | `grounding` module not modeled (RAG) | No |
| S7 | 🟡 Medium | `placeholder_values` not in request | No |
| S8 | 🟡 Medium | `messages_history` not in request | No |
| S9 | 🟡 Medium | `intermediate_failures` not in response | No |
| S10 | 🟡 Medium | `intermediate_results` missing grounding, masking, filtering, translation, unmasking fields | No |
| S11 | 🟡 Medium | `citations` missing from `LlmModuleResult` / `final_result` | No |
| S12 | 🟡 Medium | `reasoning_content` missing from response message | No |
| S13 | 🟡 Medium | `LLMModelDetails.timeout` + `max_retries` not forwarded | No |
| S14 | 🟡 Medium | `stream.delimiters` not in `StreamConfig` | No |
| S15 | 🟡 Medium | `template.defaults` not in `PromptConfig` | No |
| S16 | 🟡 Medium | `ModuleConfigsList` (fallback chain) not supported | No |
| S17 | 🟡 Medium | `config_ref` request variant (registry reference) not modeled | No |
| S18 | 🟡 Medium | `translation` module not modeled | No |
| S19 | 🟡 Medium | `stream_options.include_usage` not forwarded in streaming | No |
