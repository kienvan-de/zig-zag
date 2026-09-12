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

//! Model-name-based transformer routing.
//!
//! Providers that support multiple wire formats (HAI, Copilot) use this module
//! to select the correct transformer from the requested model name.

const std = @import("std");

/// Which transformer family a model name requires.
pub const TransformerTag = enum {
    /// Anthropic Messages wire — use anthropic.transformer + messages_path
    messages,
    /// OpenAI Responses wire — use openai.responses_transformer + responses_path
    responses,
    /// Google Gemini wire — use google_ai_studio.transformer + gemini_path
    gemini,
    /// OpenAI Chat wire — use openai.chat_transformer + chat_completions_path
    chat,
};

/// Return the transformer tag for a model name.
///
/// Routing rules (checked in order):
///   - contains `claude` or `anthropic` → `.messages`
///   - contains `gpt-5`                 → `.responses`
///   - contains `gemini`                → `.gemini`
///   - anything else                    → `.chat`
pub fn transformerForModel(model: []const u8) TransformerTag {
    if (std.mem.indexOf(u8, model, "claude") != null or
        std.mem.indexOf(u8, model, "anthropic") != null)
    {
        return .messages;
    }
    if (std.mem.indexOf(u8, model, "gpt-5") != null) return .responses;
    if (std.mem.indexOf(u8, model, "gemini") != null) return .gemini;
    return .chat;
}
