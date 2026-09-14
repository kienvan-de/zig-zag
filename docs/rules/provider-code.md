# Provider Code Rules

Rules for writing and modifying code in `src/core/providers/`.

---

## Rule 1 — All JSON schema types in `*_types.zig`

Every struct that represents a JSON schema shape — request body, response body, SSE event payload, usage object, delta struct, content block, or any upstream/downstream parse target — **must** be defined in a `*_types.zig` file.

**Canonical type files:**

| Provider | Wire-format types file |
|---|---|
| Anthropic Messages API | `anthropic/types.zig` |
| OpenAI Chat Completions API | `openai/chat_types.zig` |
| OpenAI Responses API | `openai/responses_types.zig` |
| OpenAI shared primitives | `openai/types.zig` |
| Google AI Studio (Gemini) | `google_ai_studio/types.zig` |
| SAP AI Core | `sap_ai_core/types.zig` |

**What belongs in `*_types.zig`:**
- Request and response structs
- SSE event payload structs (including pass-through parse targets like `NativeChatStreamEvent`, `NativeResponsesStreamEvent`)
- Usage, delta, content block, and output item structs
- Helper structs that are passed to `std.json.fmt` / `std.json.parseFromSlice` (e.g. `SapParams`, `ChatChunkContext`, `BuiltContents`)
- Stream state result types (`StreamLineResult`)

**What does NOT belong in `*_types.zig`:**
- Functions (transformers, content helpers, stream state methods)
- Stream state structs (e.g. `ChatStreamState`) — these live in the transformer
- Non-JSON implementation helpers with no wire schema relationship

**If a type is missing, add it to the corresponding `*_types.zig` before using it.**

---

## Rule 2 — No inline JSON string building

Never construct JSON output by formatting raw string literals with `{s}` / `{d}` / `{f}` placeholders.

**Wrong:**
```zig
out.print(allocator,
    "data: {{\"type\":\"message_start\",\"model\":\"{s}\"}}\n\n",
    .{model},
) catch return null;
```

**Right:**
```zig
const ev = Messages.MessageStart{ .type = "message_start", .message = .{ .model = model, ... } };
out.print(allocator, "event: message_start\ndata: {f}\n\n", .{std.json.fmt(ev, .{})}) catch return null;
```

**Apply to all SSE event output:** `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`, `ping`, `response.*`, error events, etc. Every SSE frame must be produced by serialising a typed struct.

**Reference implementation:** `openai/responses_content.zig` — `messagesOpen` and `messagesClose` show the correct pattern for synthesising multi-frame Messages-protocol SSE output using typed structs.

---

## Rule 3 — Deserialise → mutate → serialise (no raw JSON patching)

To modify a value inside an existing JSON string, never use string search-and-replace or substring manipulation. Always:

1. Parse the JSON into the corresponding typed struct
2. Mutate the field on the struct
3. Re-serialise via `std.json.fmt` or the type's `writeSSE`/`jsonStringify`

**Wrong:**
```zig
const needle = std.fmt.allocPrint(allocator, "\"model\":\"{s}\"", .{old_model}) catch ...;
const patched = std.mem.replaceOwned(u8, allocator, json_str, needle, replacement) catch ...;
```

**Right:**
```zig
const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
defer parsed.deinit();
const event = try Responses.StreamEvent.jsonParseFromValue(parsed.value, json_str, allocator);
defer event.deinitParsed(allocator);
// build patched copy with new model, re-emit via writeSSE
```

**Types must have `jsonParseFromValue` if they need to be mutated.** Add it alongside `jsonStringify` when the type will be received from an upstream and potentially modified.

---

## Rule 4 — Scope: current providers only

These rules apply to the Request / Response / Stream Event schemas of the currently-supported providers:

- `anthropic` — Anthropic Messages API
- `openai` — OpenAI Chat Completions API and Responses API
- `google_ai_studio` — Gemini (Google AI Studio)
- `sap_ai_core` — SAP AI Core orchestration envelope
- `copilot` — GitHub Copilot (reuses OpenAI wire format)
- `hai` — HAI (reuses Anthropic or OpenAI wire format depending on model)

Do not apply these rules to unrelated internal types (e.g. config structs, HTTP client internals, auth tokens).

---

## Rule 5 — Missing types: add first, ask if unsure

If a struct needed for Rule 1 or Rule 2 does not exist yet in the relevant `*_types.zig`, **add it before writing the code that uses it**. Follow the existing field and `jsonStringify` / `jsonParseFromValue` patterns already in that file.

If you are unsure whether a type belongs in an existing file or needs a new one, **ask before adding** rather than guessing.

---

## Rule 6 — Chat types and Responses types are isolated

`openai/chat_types.zig` and `openai/responses_types.zig` must not import each other.

- Types that are identical or shared between the two APIs belong in `openai/types.zig` (e.g. `Role`, `ToolFunction`, `ResponseFormat`, `StreamOptions`, `ErrorDetails`, `ErrorResponse`).
- Types that differ in field names or semantics between the two APIs stay in their respective file even if structurally similar (e.g. `Usage` in chat uses `prompt_tokens`/`completion_tokens`; `Usage` in responses uses `input_tokens`/`output_tokens` — these are not the same type).
- Transformer files (`*_transformer.zig`) may import both — cross-imports at the transformer level are expected and correct. Cross-imports between the two type files are not.

---

## Practical guidance

### Adding a new SSE event type

1. Add the struct to the relevant `*_types.zig`.
2. Add `jsonStringify` that emits only non-null/non-zero fields.
3. Add `jsonParseFromValue` if the event may be received from upstream and mutated.
4. Use the new type everywhere the event is emitted — never inline the JSON.

### Adding a new provider

1. Create `<provider>/types.zig` with all wire-format structs.
2. Create `<provider>/content.zig` for stateless mapping helpers (no types that belong in Rule 1).
3. Create `<provider>/transformer.zig` for flow functions and stream states.
4. Re-export shared stream result types rather than re-declaring them:
   ```zig
   pub const StreamLineResult = Messages.StreamLineResult;
   ```

### Checking compliance

Run `zig build` — the compiler will catch type mismatches. For structural review, check:
- No `out.print(allocator, "...\"{s}\"...", .{value})` where the format string contains JSON structure
- No `std.mem.replaceOwned` operating on JSON strings
- No `pub const SomeType = struct { ... }` in transformer or content files where the struct is a JSON parse/emit target
