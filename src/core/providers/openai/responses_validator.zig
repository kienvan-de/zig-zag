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

//! Responses request validator
//!
//! Validates inbound `/v1/responses` (OpenAI Responses) requests against the
//! documented schema constraints (see docs/openai-constraints.md).
//!
//! Returns `null` when valid, or a static error message describing the first
//! violation. Tool-name length/charset is normalized in the transformer, not
//! validated here.

const std = @import("std");
const responses_types = @import("responses_types.zig");

/// Validate a Responses request. Returns a static message on the first
/// violation, or `null` when valid.
pub fn validate(request: responses_types.Request) ?[]const u8 {
    if (request.max_output_tokens) |v| {
        if (v < 16) return "max_output_tokens must be at least 16";
    }
    if (request.temperature) |v| {
        if (v < 0 or v > 2) return "temperature must be between 0 and 2";
    }
    if (request.top_p) |v| {
        if (v < 0 or v > 1) return "top_p must be between 0 and 1";
    }
    if (request.top_logprobs) |v| {
        if (v > 20) return "top_logprobs must be between 0 and 20";
    }
    if (request.truncation) |t| {
        if (!std.mem.eql(u8, t, "auto") and !std.mem.eql(u8, t, "disabled"))
            return "truncation must be one of: auto, disabled";
    }
    if (request.safety_identifier) |s| {
        if (s.len > 64) return "safety_identifier must be at most 64 characters";
    }
    if (request.prompt_cache_key) |s| {
        if (s.len > 64) return "prompt_cache_key must be at most 64 characters";
    }

    return null;
}
