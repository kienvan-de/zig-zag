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

//! Messages (Anthropic) request validator
//!
//! Validates inbound `/v1/messages` requests against the documented Anthropic
//! constraints (see docs/anthropic-constraints.md).
//!
//! Returns `null` when valid, or a static error message describing the first
//! violation. Anthropic imposes NO tool-name length/charset limit, so tool
//! names are not validated (nor normalized on the Anthropic-native path).
//!
//! Note: `max_tokens == 0` is allowed (prompt-cache pre-warm).

const std = @import("std");
const messages_types = @import("types.zig");

/// Max messages per request (doc-only cap).
const MAX_MESSAGES: usize = 100_000;

/// Validate a Messages request. Returns a static message on the first
/// violation, or `null` when valid.
pub fn validate(request: messages_types.Request) ?[]const u8 {
    if (request.messages.len > MAX_MESSAGES)
        return "messages must contain at most 100000 items";

    if (request.temperature) |v| {
        if (v < 0 or v > 1) return "temperature must be between 0 and 1";
    }
    if (request.top_p) |v| {
        if (v < 0 or v > 1) return "top_p must be between 0 and 1";
    }
    if (request.top_k) |v| {
        if (v == 0) return "top_k must be greater than 0";
    }
    if (request.service_tier) |s| {
        if (!std.mem.eql(u8, s, "auto") and !std.mem.eql(u8, s, "standard_only"))
            return "service_tier must be one of: auto, standard_only";
    }
    if (request.thinking) |t| {
        if (!std.mem.eql(u8, t.type, "enabled") and
            !std.mem.eql(u8, t.type, "disabled") and
            !std.mem.eql(u8, t.type, "adaptive"))
            return "thinking.type must be one of: enabled, disabled, adaptive";
        if (t.budget_tokens) |bt| {
            if (bt < 1024) return "thinking.budget_tokens must be at least 1024";
            if (request.max_tokens != 0 and bt >= request.max_tokens)
                return "thinking.budget_tokens must be less than max_tokens";
        }
    }

    return null;
}
