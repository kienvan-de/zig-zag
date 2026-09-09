# Refactoring Plan — `anthropic/transformer.zig` → Canonical Flow-Organized Shape

Status: **PLAN v3 — awaiting review.** No wiring, no tests. Broken intermediates accepted.

---

## Principle (read before every change — any edit that violates one of these is wrong)

**P1 — One transformer per upstream wire format.**
`anthropic/transformer.zig` converts between the inbound API schemas and the
Anthropic wire. It contains nothing else.

**P2 — Four flows, uniform per-flow shape.**
Flows are named after the *inbound API schema*: `Models`, `Chat`, `Messages`, `Responses`.

- **Request/response/stream flows** (`Chat`, `Messages`, `Responses`) expose exactly:

  ```
  transform{Flow}Request      (request, model, allocator)                    → upstream request
  cleanup{Flow}Request        (upstream_request, allocator)
  transform{Flow}Response     (upstream_response, allocator, original_model) → inbound-schema response
  cleanup{Flow}Response       (inbound_response, allocator)
  transform{Flow}StreamLine   (line, *state, allocator)                      → StreamLineResult
  ```

  plus `flushResponseStream` for the **Responses flow only** (it synthesizes
  terminal events after the upstream stream ends; Chat/Messages flows emit
  terminals inline and have **no** flush — a flush there is a design smell).

- **Models flow** is response-only (GET, no request body, no streaming):
  `transformModelsResponse` — one function, one section.

**P3 — Three owned stream states.**
`ChatStreamState`, `MessageStreamState`, `ResponsesStreamState` — defined in
this file, inside their flow's section. Never aliased from another module,
never nesting a foreign state. Each carries the uniform 6-field core:

```
allocator, original_model, response_id, finish_reason, input_tokens, output_tokens
```

plus flow-specific fields. Usage is read from these fields (end of stream) —
never scraped from individual chunks by pipelines.

**P4 — One streaming result type.**
`StreamLineResult = union(enum) { output: []const u8, skip: void }`.
Every `transform{Flow}StreamLine` returns it. `output` is formatted SSE bytes,
ready to write, caller frees. Errors are *rendered inside the transformer* into
the flow's own wire format (no error variant in the union).

**P5 — No re-exports, no aliases.**
Every `pub` symbol in `transformer.zig` is defined there. Types are imported
from `types.zig` / `chat_types.zig`, but `pub const X = other.X` is forbidden.

**P6 — Main surface only.**
`transformer.zig` holds only the flow shapes (sections per P10) + the shared
contract decls. All mapping/streaming support code moves to `content.zig`.

**P7 — Meaningful names, no word collisions.**
The words `Chat` / `Messages` / `Responses` / `Models` appear only as flow
names. The word `Anthropic` names the *wire format* — it appears in doc
comments and type references, never in flow function names. (This kills the
current `transformFromAnthropic` vs rt's `fromMessages` polarity clash.)

**P8 — Deterministic parameter order.**
Request transforms `(request, model, allocator)` · Response transforms
`(upstream_response, allocator, original_model)` · Stream `(line, *state, allocator)`
· Cleanup `(value, allocator)`. Same order for every flow, every transformer.
(Exception, models flow: `transformModelsResponse(allocator, response, provider_name)`
keeps its existing order — it predates the shape and is consumed generically.)

**P9 — Wiring is a later, separate pass.**
This refactor intentionally breaks `completion.zig` consumers. We do not fix
them here and we do not run tests. The **Re-wiring inventory** (bottom) is the
contract for the follow-up pass.

**P10 — File organized by flow sections.**
`transformer.zig` is physically arranged as one banner-delimited section per
flow, in fixed order: **Models → Chat → Messages → Responses**. A section owns
*everything belonging to its flow*: its stream state struct, its functions, its
section-local constants — a reader finds the whole flow in one block. The only
code outside the flow sections is the file-head contract block (shared
`StreamLineResult`, `appendsDoneMarker`) and the principle comment.

**P11 — Self-contained transformer (no cross-provider delegation).**
A transformer implements **all of its flow conversions locally**. It may depend on:
- shared **type definitions** (data shapes only): `types.zig`, `openai/chat_types.zig`,
  `openai/responses_types.zig`, `openai/models.zig`
- its **own support file** `content.zig` (same-provider mapping/streaming internals)

It must **not** import other providers' transformer/converter modules — not
`openai/responses_transformer.zig` (rt), not peer transformers. Conversion code
duplicated across transformers is **accepted**: isolation over DRY. Providers
depend on each other only through data shapes, never through logic.
*(Trajectory: once google/sap follow this template, rt's `toMessages*` /
`fromMessagesResponse*` / `fromMessagesStream*` and `toSap*` families become
dead and are deleted in those passes; rt shrinks to the responses
sub-provider's own flows. Not in scope here — google still consumes rt today.)*

---

## Target file layout — `src/core/providers/anthropic/`

| File | Contents |
|---|---|
| `transformer.zig` (~800 LOC) | principle header (P1–P11, abridged) · **contract block** (`StreamLineResult`, `appendsDoneMarker`) · 4 flow sections (Models, Chat, Messages, Responses) — each with its state struct(s) + functions, **all conversion logic local** (P11). **Nothing else.** |
| `content.zig` (new) | shared mapping/streaming internals for the Chat & Messages flows: `extractSystemPrompt`, `normalizeMessages`, `transformContent`, `transformToolCalls`, `transformToolResult`, `transformTools`, `transformToolChoice`, `extractTextFromBlocks`, `extractToolCalls`, `transformStopReason`, `transformErrorResponse`, `tryParseError`, `handleMessageStart`, `handleContentBlockStart`, `handleContentBlockDelta`, `handleMessageDelta`, `buildChatChunk` (ex `buildOpenAIChunk`). `pub` but documented "internal to the anthropic provider". The **Responses flow does not use content.zig** — its conversion is self-contained in its section (it shares no parsing with the other flows). |
| `types.zig`, `client.zig` | unchanged |

*(no `models.zig` — the models flow lives in `transformer.zig` as a section, so
`fetchModelsForProviderInner`'s generic `transformer.transformModelsResponse`
call keeps working unchanged. No rt import anywhere.)*

### `transformer.zig` skeleton

```zig
//! Principle block: P1–P11 (abridged comment form)

const std = @import("std");
const Anthropic = @import("types.zig");                                  // wire types
const OpenAIChat = @import("../openai/chat_types.zig");                  // schema types (shapes only)
const OpenAIResponses = @import("../openai/responses_types.zig");        // schema types (shapes only)
const content = @import("content.zig");                                  // own internals
const time = @import("../../time.zig");

// ============================================================================
// Contract (shared by all flows)
// ============================================================================
pub const StreamLineResult = union(enum) { output: []const u8, skip: void };
pub const appendsDoneMarker = true; // responses flow synthesizes events; pipeline appends [DONE]

// ============================================================================
// Flow: /v1/models
// ============================================================================
pub fn transformModelsResponse(allocator, response, provider_name) ![]Model { ... }

// ============================================================================
// Flow: /v1/chat/completions   (inbound chat schema → Anthropic wire)
// ============================================================================
pub const ChatStreamState = struct { ... };
pub fn transformChatRequest(...) { ... }
pub fn cleanupChatRequest(...) { ... }
pub fn transformChatResponse(...) { ... }
pub fn cleanupChatResponse(...) { ... }
pub fn transformChatStreamLine(...) StreamLineResult { ... }

// ============================================================================
// Flow: /v1/messages   (inbound messages schema → Anthropic wire, pass-through)
// ============================================================================
pub const MessageStreamState = struct { ... };
pub fn transformMessagesRequest(...) { ... }
pub fn cleanupMessagesRequest(...) { ... }
pub fn transformMessagesResponse(...) { ... }
pub fn cleanupMessagesResponse(...) { ... }
pub fn transformMessagesStreamLine(...) StreamLineResult { ... }

// ============================================================================
// Flow: /v1/responses   (inbound responses schema → Anthropic wire)
// Local conversion — no delegation (P11). Converts via OpenAIResponses types
// as data shapes only.
// ============================================================================
pub const ResponsesStreamState = struct { ... };
pub fn transformResponsesRequest(...) { ... }     // OpenAIResponses.Request → Anthropic.Request
pub fn cleanupResponsesRequest(...) { ... }
pub fn transformResponsesResponse(...) { ... }    // Anthropic.Response → OpenAIResponses.Response
pub fn cleanupResponsesResponse(...) { ... }
pub fn transformResponsesStreamLine(...) StreamLineResult { ... }  // Anthropic SSE → Responses events
pub fn flushResponseStream(...) ?[]const u8 { ... }                // terminal events + usage
```

---

## Symbol mapping (old → new)

### States
| Current | New | Change |
|---|---|---|
| `StreamState` | `ChatStreamState` (chat section) | + `output_tokens: u32`, `finish_reason: ?[]const u8`; `input_tokens: ?u32` → `u32`; keeps flow-specific `message_id`, `current_tool_*`, `sent_role` |
| `AnthropicStreamState` | `MessageStreamState` (messages section) | 6-field core + pass-through specifics; `getUsage()` deleted (P3: fields are the contract) |
| `ResponsesStreamState` | `ResponsesStreamState` (responses section) | already canonical — unchanged |
| `AnthropicStreamLineResult` (re-export alias) | **deleted** | replaced by contract-block `StreamLineResult` (P4/P5) |

### Models flow (inbound `/v1/models` → Anthropic wire)
| Current | New |
|---|---|
| `transformModelsResponse` | unchanged — becomes the Models flow section |

### Chat flow (inbound `/v1/chat/completions` → Anthropic wire)
| Current | New |
|---|---|
| `transform` | `transformChatRequest` |
| `cleanupRequest` | `cleanupChatRequest` |
| `transformResponse` | `transformChatResponse` |
| `cleanupResponse` | `cleanupChatResponse` |
| `transformStreamLine` | `transformChatStreamLine` — returns `StreamLineResult`; chunks serialized to `data: {f}\n\n` bytes; usage + stop_reason accumulated into state (`message_delta` → `output_tokens`/`finish_reason` via `transformStopReason`); `error` events rendered to chat-format error SSE bytes inline |

### Messages flow (inbound `/v1/messages` → Anthropic wire, pass-through)
| Current | New |
|---|---|
| `transformFromAnthropic` | `transformMessagesRequest` — pass-through + pin model (unchanged logic) |
| `cleanupFromAnthropicRequest` | `cleanupMessagesRequest` — no-op |
| `transformToAnthropicResponse` | `transformMessagesResponse` — pass-through |
| `cleanupAnthropicResponse` | `cleanupMessagesResponse` — no-op |
| `transformStreamLineToAnthropic` | `transformMessagesStreamLine` — forwards lines verbatim (re-terminated `line\n\n`), accumulates usage into state; returns `StreamLineResult` |

### Responses flow (inbound `/v1/responses` → Anthropic wire — **now local, was rt delegation**)
| Current | New |
|---|---|
| `transformFromResponses` (→ `rt.toMessages`) | `transformResponsesRequest` — **local**: maps `OpenAIResponses.Request` → `Anthropic.Request` (input items/messages → messages, instructions → system, tools, tool_choice, reasoning.effort → thinking, max_output_tokens → max_tokens) + pin model |
| `cleanupFromRequest` (→ `rt.cleanupToMessages`) | `cleanupResponsesRequest` — frees what the local mapping allocated |
| `transformToResponse` (→ `rt.fromMessagesResponse`) | `transformResponsesResponse` — **local**: maps `Anthropic.Response` → `OpenAIResponses.Response` (content blocks → output items, stop_reason → status, usage input/output passthrough); **param order fixed to P8**: `(Anthropic.Response, allocator, original_model)` |
| `cleanupResponsesResp` (→ `rt.cleanupFromMessagesResponse`) | `cleanupResponsesResponse` — frees the local mapping's allocations |
| `transformStreamLineToResponses` (→ `rt.fromMessagesStreamLine`) | `transformResponsesStreamLine` — **local**: Anthropic SSE line → Responses SSE events (`message_start` → `response.created`+`output_item.added`, `content_block_delta` → `response.output_text.delta`, `message_delta` → finish/usage accumulation, `message_stop` → `response.output_item.done`); returns `StreamLineResult` |
| `flushResponsesStream` (→ `rt.fromMessagesStreamFlush`) | `flushResponseStream` — **local**: emits terminal `response.output_item.done` + `response.completed` (or `response.incomplete` for `max_tokens`) with accumulated usage |
| `appendsDoneMarker = true` | unchanged (moved to contract block) |

---

## Implementation steps

1. **Create `content.zig`** — move the Chat/Messages-flow mapping/streaming
   helpers out of `transformer.zig` (see layout table). Adjust visibility
   docs: "internal to the anthropic provider". `buildOpenAIChunk` →
   `buildChatChunk` (name says what it builds, not what std lib it mimics).
2. **Rewrite `transformer.zig`** in the P10 skeleton:
   - principle header, imports (**no rt** — P11), contract block
   - **Models flow section**: `transformModelsResponse` verbatim
   - **Chat flow section**: `ChatStreamState` + 5 fns (chat stream fn
     accumulates `output_tokens` + `finish_reason` from `message_delta`,
     serializes output bytes, renders error events inline)
   - **Messages flow section**: `MessageStreamState` + 5 fns (pass-through
     stream fn renders bytes, accumulates usage)
   - **Responses flow section**: `ResponsesStreamState` + 5 fns + flush —
     **all conversion logic written locally** (request mapping, response
     mapping, SSE event synthesis, terminal flush; `StreamLineResult`
     contract; P8 param order)
   - delete `getUsage()` (fields are the contract); delete
     `AnthropicStreamLineResult` alias
3. **Self-audit against the principle** — every remaining `pub` symbol must
   satisfy P1–P8; `grep "pub const .* = "` must show no aliases; imports must
   contain no transformer/converter modules (P11); sections must appear in
   Models→Chat→Messages→Responses order.
4. **Do not touch consumers; do not run build/tests** (P9). Append the
   re-wiring inventory below to the tracking notes.

---

## Re-wiring inventory (follow-up pass — NOT this refactor)

`src/core/completion.zig`:
- `fetchModelsForProviderInner`: **no change** (generic
  `transformer.transformModelsResponse` call survives the models section).
- `chatSync` (chat non-streaming): pure renames — `transform`→`transformChatRequest`,
  `cleanupRequest`→`cleanupChatRequest`, `transformResponse`→`transformChatResponse`,
  `cleanupResponse`→`cleanupChatResponse`.
- `chatStreaming` (chat streaming): renames + **small structural edit** —
  `StreamState`→`ChatStreamState`, `transformStreamLine`→`transformChatStreamLine`;
  loop switch becomes `.output`/`.skip` over ready-made bytes; **delete the
  per-chunk usage-scraping block**, replace with one end-of-stream usage read
  from state fields (input_tokens/output_tokens, guarded `> 0`).
- `messagesSync` (messages non-streaming): pure renames —
  `transformFromAnthropic`→`transformMessagesRequest`,
  `cleanupFromAnthropicRequest`→`cleanupMessagesRequest`,
  `transformToAnthropicResponse`→`transformMessagesResponse`,
  `cleanupAnthropicResponse`→`cleanupMessagesResponse`.
- `messagesStreaming` (messages streaming): renames —
  `AnthropicStreamState`→`MessageStreamState`,
  `transformStreamLineToAnthropic`→`transformMessagesStreamLine` (loop switch
  already matches `StreamLineResult`); tail `stream_state.getUsage()` →
  `stream_state.input_tokens`/`stream_state.output_tokens`.
- `dispatchResponses` `.anthropic` arm: renames + **arg-order fix at 2 call
  sites** (retry + main): `transformFromResponses`→`transformResponsesRequest`,
  `cleanupFromRequest`→`cleanupResponsesRequest`,
  `transformToResponse(resp.value, request, allocator)`→
  `transformResponsesResponse(resp.value, allocator, request.model)`,
  `cleanupResponsesResp`→`cleanupResponsesResponse`,
  `transformStreamLineToResponses`→`transformResponsesStreamLine` (now union),
  `flushResponsesStream`→`flushResponseStream`.
  Note: `dispatchResponses` is generic over all transformers — it can only
  switch to the canonical shape when **every** transformer conforms (follow-up
  steps for openai/sap/google + hai/copilot bindings).

`rt` (`openai/responses_transformer.zig`): **no changes in this pass** —
google still consumes its Messages family. After google/sap follow the
template, delete rt's `toMessages*`, `fromMessagesResponse*`,
`fromMessagesStream*`, `toSap*` families (dead code removal, separate pass).

## Explicit non-goals
- `client.zig`, `types.zig` — untouched
- `completion.zig`, `rt` — untouched (broken on purpose until wiring pass)
- other transformers — untouched (anthropic is the template; they follow)
- tests — none run; unit tests per flow section get written after wiring
