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

//! Worker Pool Facade
//!
//! Thin interface for submitting background tasks. The core module uses
//! `submit()` and `isAvailable()` without knowing the pool implementation.
//! The wrapper injects the real pool via `setSubmitFn()` at startup.

const std = @import("std");

/// Task function signature — takes an opaque context pointer.
pub const TaskFn = *const fn (*anyopaque) void;

/// Submit function signature — the bridge to the real pool.
pub const SubmitFn = *const fn (TaskFn, *anyopaque) anyerror!void;

/// Pluggable submit function — set by the wrapper during init.
var submit_fn: ?SubmitFn = null;

/// Register a submit function (called by the wrapper at startup).
pub fn setSubmitFn(f: SubmitFn) void {
    submit_fn = f;
}

/// Clear the submit function (called by the wrapper at shutdown).
pub fn clearSubmitFn() void {
    submit_fn = null;
}

/// Submit a task for background execution.
///
/// Returns `error.PoolNotInitialized` if no backend has been registered.
pub fn submit(func: TaskFn, context: *anyopaque) !void {
    const f = submit_fn orelse return error.PoolNotInitialized;
    return f(func, context);
}

/// Check whether a pool backend is available.
pub fn isAvailable() bool {
    return submit_fn != null;
}

/// A synchronisation primitive for waiting on multiple submitted tasks.
///
/// Pure data structure with no external dependencies — safe to keep in core.
pub const WaitGroup = struct {
    count: usize,
    mutex: std.Thread.Mutex,
    done_cond: std.Thread.Condition,

    pub fn init() WaitGroup {
        return .{
            .count = 0,
            .mutex = .{},
            .done_cond = .{},
        };
    }

    /// Add to the counter.
    pub fn add(self: *WaitGroup, n: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.count += n;
    }

    /// Mark one task as done.
    pub fn done(self: *WaitGroup) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count > 0) {
            self.count -= 1;
            if (self.count == 0) {
                self.done_cond.broadcast();
            }
        }
    }

    /// Wait for all tasks to complete.
    pub fn wait(self: *WaitGroup) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count > 0) {
            self.done_cond.wait(&self.mutex);
        }
    }
};
