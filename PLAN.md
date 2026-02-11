# Project Master Plan: `zig-zag`

## **Context & Objective**
Build a high-performance, memory-safe HTTP proxy in **Zig** that accepts **OpenAI-compatible** requests (specifically `/v1/chat/completions`) and forwards them to the **Anthropic Messages API** (`/v1/messages`). The proxy must handle schema transformation, system prompt extraction, and real-time Server-Sent Events (SSE) streaming translation.

## **Technical Stack**
* **Language:** Zig (Latest Stable or 0.13.0+)
* **HTTP Server:** `std.http` (or `zap` wrapper if preferred for ease)
* **JSON:** `std.json` (Strict typing)
* **Allocator Strategy:** `GeneralPurposeAllocator` for long-lived, `ArenaAllocator` for per-request scope.

---

## **Phase 1: Project Skeleton & Networking Foundation** ✅ **COMPLETED**
**Goal:** Establish the directory structure and a basic echo server to verify the build pipeline.

* **Task 1.1: Initialize Project** ✅
    * **Action:** Run `zig init` and configure `build.zig`.
    * **File:** `build.zig`, `src/main.zig`
    * **Requirement:** Ensure `zig build run` compiles and starts a process.
    * **Output:** A clean Zig project structure.
    * **Status:** Complete - Project initialized with Zig 0.15.2

* **Task 1.2: HTTP Server Boilerplate** ✅
    * **Action:** Implement a basic HTTP listener on port `8080`.
    * **File:** `src/server.zig`
    * **Logic:** Listen for POST requests on `/v1/chat/completions`. Return a static 200 OK JSON `{"status": "alive"}` for now.
    * **Acceptance:** `curl -X POST http://localhost:8080/v1/chat/completions` returns the JSON.
    * **Status:** Complete - Server listening on :8080, returns {"status": "alive"}

* **Task 1.3: Environment Configuration** ✅
    * **Action:** Create a loader for `.env` variables (specifically `ANTHROPIC_API_KEY`).
    * **File:** `src/config.zig`
    * **Logic:** Read env vars; if missing, panic or log error on startup.
    * **Status:** Complete - Loads ANTHROPIC_API_KEY with validation

* **Task 1.4: JSON Samples & Documentation** ✅
    * **Action:** Create comprehensive JSON samples for both APIs.
    * **Files:** `samples/openai/*.json`, `samples/anthropic/*.json`
    * **Logic:** Document schema differences and transformation examples.
    * **Status:** Complete - 12 sample files + 3 documentation files created
        * OpenAI: request_full, request_minimal, request_stream, response, stream_chunks
        * Anthropic: request_full, request_minimal, request_stream, response, stream_events
        * Docs: README.md, SCHEMA_DIFFERENCES.md, transformation_example.md

**Commits:**
- `a95fd0a` - feat: Phase 1 - Project skeleton and HTTP server foundation
- `366a8b8` - refactor: Complete Phase 1 - Extract server logic to server.zig

---

## **Phase 2: Data Modeling (The Schemas)** ✅ **COMPLETED**
**Goal:** Define strict Zig structs that mirror the exact JSON expected by both providers.

* **Task 2.1: Define OpenAI Structs** ✅
    * **File:** `src/providers/openai.zig`
    * **Structs Needed:**
        * `Message`: `{ role: []const u8, content: []const u8 }`
        * `Request`: `{ model: []const u8, messages: []Message, stream: ?bool, temperature: ?f32, max_tokens: ?u32 }`
        * `StreamChunk`: The response format for SSE (id, object, created, choices).
    * **Status:** Complete - Enhanced with type-safe Role enum (system, user, assistant, function, tool)
    * **Enhancements:**
        * Type-safe `Role` enum instead of strings
        * Full response structures (Response, ResponseChoice, ResponseMessage, Usage)
        * Complete streaming support (StreamChunk, StreamChoice, Delta)
        * Additional optional fields (top_p, n, presence_penalty, frequency_penalty)
    * **Tests:** 26 comprehensive tests

* **Task 2.2: Define Anthropic Structs** ✅
    * **File:** `src/providers/anthropic.zig`
    * **Structs Needed:**
        * `Message`: `{ role: []const u8, content: []const u8 }` (Note: No system role here).
        * `Request`: `{ model: []const u8, messages: []Message, system: ?[]const u8, max_tokens: u32, stream: bool }`
        * `StreamEvent`: Structs for `message_start`, `content_block_delta`, etc.
    * **Status:** Complete - Type-safe Role enum with only user/assistant
    * **Implementations:**
        * Type-safe `Role` enum (user, assistant only)
        * Complete request/response structures
        * Full streaming event support (7 event types)
        * ContentBlock array structure
        * Proper usage tracking
    * **Tests:** 23 comprehensive tests

**Commits:**
- `ce5a1b3` - Add comprehensive unit tests for config.zig and server.zig

---

## **Phase 3: Request Transformation Logic (The Core)** ✅ **COMPLETED**
**Goal:** Implement bidirectional transformation logic (OpenAI ↔ Anthropic).

* **Task 3.1: System Prompt Extraction** ✅
    * **File:** `src/transformers/anthropic.zig`
    * **Logic:** Iterate through OpenAI `messages`.
        * If `role == "system"`, extract content to a `system_prompt` variable.
        * If `role != "system"`, append to a new list of `Anthropic.Message`.
    * **Constraint:** Anthropic `system` is a top-level string, not a message in the array.
    * **Status:** Complete - `extractSystemPrompt()` function with concatenation support
    * **Tests:** 5 comprehensive tests

* **Task 3.2: Message Normalization** ✅
    * **Logic:** Anthropic requires alternating `user` / `assistant` messages.
        * *Edge Case:* If two `user` messages are consecutive, merge their content with a newline separator.
    * **Refinement:** Ensure the first message is always `user` (if the first was system and removed, check next).
    * **Status:** Complete - `normalizeMessages()` with automatic merging and synthetic user insertion
    * **Tests:** 6 comprehensive tests

* **Task 3.3: Field Mapping & Defaults** ✅
    * **Logic:**
        * Dynamic provider routing with `provider/model-name` format (e.g., `anthropic/claude-3-5-sonnet-latest`)
        * **Crucial:** If OpenAI `max_tokens` is null, set Anthropic `max_tokens` to `4096` (it is a required field for Anthropic).
    * **Status:** Complete - `transform()` main function with all field mappings
    * **Enhancements:**
        * Provider detection system (`src/providers/provider.zig`)
        * Dynamic model routing (no hardcoded mappings)
        * Bidirectional transformation (request + response)
    * **Tests:** 5 comprehensive tests

* **Bonus: Response Transformation** ✅
    * **File:** `src/transformers/anthropic.zig`
    * **Logic:** Transform `Anthropic.Response` -> `OpenAI.Response`
        * Map stop reasons (end_turn→stop, max_tokens→length)
        * Extract text from ContentBlock arrays
        * Map usage tokens (input_tokens→prompt_tokens, etc.)
    * **Status:** Complete - `transformResponse()`, `transformStopReason()`, `extractTextFromBlocks()`
    * **Tests:** 14 comprehensive tests

* **Bonus: Provider Detection** ✅
    * **File:** `src/providers/provider.zig`
    * **Logic:** Parse model strings in format `provider/model-name`
    * **Status:** Complete - `parseModelString()`, provider enum, validation
    * **Tests:** 22 comprehensive tests

**Architecture:**
- Single file per provider with bidirectional transformation
- `src/transformers/anthropic.zig` handles both request and response
- Future providers: `google.zig`, `cohere.zig`, etc.

**Commits:**
- `517a343` - feat: Phase 3 - Bidirectional transformation and provider routing

---

## **Phase 4: Upstream Communication (The Client)**
**Goal:** Send the transformed payload to Anthropic.

* **Task 4.1: HTTP Client Implementation**
    * **File:** `src/upstream/anthropic_client.zig`
    * **Action:** Use `std.http.Client` to POST to `https://api.anthropic.com/v1/messages`.
    * **Headers:**
        * `x-api-key`: [From Config]
        * `anthropic-version`: `2023-06-01`
        * `content-type`: `application/json`

* **Task 4.2: Non-Streaming Response Handler**
    * **Logic:** If `stream: false`, read the full body from Anthropic.
    * **Transformation:** Map `Anthropic.Response` -> `OpenAI.Response`.
    * **Action:** Send JSON back to original client.

---

## **Phase 5: Streaming & SSE (The Hard Part)**
**Goal:** Handle real-time token streaming. This is where the proxy adds the most value.

* **Task 5.1: SSE Parser**
    * **File:** `src/protocol/sse.zig`
    * **Logic:** Create a buffered reader that reads the Anthropic response line-by-line.
        * Look for lines starting with `event:` and `data:`.
        * Ignore keep-alive pings.

* **Task 5.2: Stream Event Transformer**
    * **Logic:** Map Anthropic events to OpenAI chunks:
        * `message_start` -> (Save ID, send initial role chunk).
        * `content_block_delta` -> Extract `.delta.text` -> Send as `chat.completion.chunk` with `content`.
        * `message_stop` -> Send `[DONE]`.

* **Task 5.3: Flush to Client**
    * **Logic:** As soon as a chunk is transformed, write it to the client's socket immediately. Do not buffer the whole stream.

---

## **Phase 6: Error Handling & Polish**
* **Task 6.1: Global Error Handler**
    * **Logic:** If Anthropic returns 4xx/5xx, capture the error body.
    * **Action:** Wrap it in an OpenAI error object: `{ "error": { "message": "...", "type": "server_error" } }`.
    * **Reason:** Clients like LangChain/AutoGPT expect OpenAI-format errors to retry correctly.

* **Task 6.2: Memory Leak Check**
    * **Action:** Use `defer arena.deinit()` at the end of every request handler. Run with `zig build -Doptimize=Debug` to catch leaks.

---
