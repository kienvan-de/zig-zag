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

//! Template package — all embedded HTML templates in one place.
//!
//! Templates are baked into the binary at compile time via @embedFile.
//! Add a new template: drop the .html file here and add a pub const below.
//!
//! Usage:
//!   const templates = @import("templates/mod.zig");
//!   // templates.device_flow  → []const u8
//!   // templates.config_ui    → []const u8

/// GitHub Copilot device flow auth page.
/// Placeholders: {{USER_CODE}}, {{VERIFICATION_URI}}
pub const device_flow = @embedFile("device_flow.html");

/// Web-based config UI page served at GET /v1/html/config
pub const config_ui = @embedFile("config.html");
