// Copyright 2025 kienvan.de
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Chat Completions request validator
//!
//! Validates inbound `/v1/chat/completions` (OpenAI Chat) requests against the
//! documented schema constraints (see docs/openai-constraints.md).
//!
//! Returns `null` when valid, or a static error message describing the first
//! violation. Tool-name length/charset is intentionally NOT validated here — it
//! is normalized in the transformer instead.

const std = @import("std");
const chat_types = @import("chat_types.zig");

/// Validate a Chat Completions request. Returns a static message on the first
/// violation, or `null` when the request is valid.
pub fn validate(request: chat_types.Request) ?[]const u8 {
    if (request.messages.len < 1)
        return "messages must contain at least 1 item";

    if (request.temperature) |v| {
        if (v < 0 or v > 2) return "temperature must be between 0 and 2";
    }
    if (request.top_p) |v| {
        if (v < 0 or v > 1) return "top_p must be between 0 and 1";
    }
    if (request.frequency_penalty) |v| {
        if (v < -2 or v > 2) return "frequency_penalty must be between -2 and 2";
    }
    if (request.presence_penalty) |v| {
        if (v < -2 or v > 2) return "presence_penalty must be between -2 and 2";
    }
    if (request.n) |v| {
        if (v < 1 or v > 128) return "n must be between 1 and 128";
    }
    if (request.top_logprobs) |v| {
        if (v > 20) return "top_logprobs must be between 0 and 20";
    }

    return null;
}
