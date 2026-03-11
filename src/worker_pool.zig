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

//! Worker Pool Implementation
//!
//! A generic thread pool for executing tasks concurrently.
//! At init the pool registers itself with the core facade so that core
//! modules can submit tasks without depending on this implementation.

const std = @import("std");
const core = @import("zag-core");

const TaskFn = core.worker_pool.TaskFn;

/// A task in the queue
const Task = struct {
    func: TaskFn,
    context: *anyopaque,
};

/// Global worker pool instance
var pool_ptr: std.atomic.Value(?*WorkerPool) = std.atomic.Value(?*WorkerPool).init(null);
var pool_allocator: ?std.mem.Allocator = null;
var pool_mutex: std.Thread.Mutex = .{};

/// Worker Pool implementation
pub const WorkerPool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    queue: std.ArrayList(Task),
    queue_head: usize,
    queue_mutex: std.Thread.Mutex,
    queue_not_empty: std.Thread.Condition,
    shutdown: bool,
    active_tasks: usize,

    const DEFAULT_POOL_SIZE = 1;
    const COMPACT_THRESHOLD = 64;

    /// Initialize the worker pool
    pub fn initPool(allocator: std.mem.Allocator, pool_size: usize) !*WorkerPool {
        const size = if (pool_size == 0) DEFAULT_POOL_SIZE else pool_size;

        const self = try allocator.create(WorkerPool);
        self.* = .{
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, size),
            .queue = std.ArrayList(Task){},
            .queue_head = 0,
            .queue_mutex = .{},
            .queue_not_empty = .{},
            .shutdown = false,
            .active_tasks = 0,
        };

        // Start worker threads
        for (self.threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, workerLoop, .{self});
        }

        return self;
    }

    /// Shutdown the worker pool
    pub fn deinitPool(self: *WorkerPool) void {
        // Signal shutdown
        {
            self.queue_mutex.lock();
            self.shutdown = true;
            self.queue_mutex.unlock();
        }

        // Wake up all waiting threads
        self.queue_not_empty.broadcast();

        // Wait for all threads to finish
        for (self.threads) |thread| {
            thread.join();
        }

        self.allocator.free(self.threads);
        self.queue.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Submit a task to the pool
    pub fn submit(self: *WorkerPool, func: TaskFn, context: *anyopaque) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        if (self.shutdown) {
            return error.PoolShutdown;
        }

        try self.queue.append(self.allocator, .{
            .func = func,
            .context = context,
        });

        // Signal one waiting worker
        self.queue_not_empty.signal();
    }

    /// Get number of pending tasks
    pub fn pendingTasks(self: *WorkerPool) usize {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        return self.queue.items.len - self.queue_head;
    }

    /// Compact the queue by removing consumed items (call with lock held)
    fn compactQueue(self: *WorkerPool) void {
        if (self.queue_head >= COMPACT_THRESHOLD) {
            const remaining = self.queue.items.len - self.queue_head;
            if (remaining > 0) {
                std.mem.copyForwards(Task, self.queue.items[0..remaining], self.queue.items[self.queue_head..]);
            }
            self.queue.shrinkRetainingCapacity(remaining);
            self.queue_head = 0;
        }
    }

    /// Worker thread main loop
    fn workerLoop(self: *WorkerPool) void {
        while (true) {
            var task: Task = undefined;

            // Get next task
            {
                self.queue_mutex.lock();
                defer self.queue_mutex.unlock();

                while (self.queue_head >= self.queue.items.len and !self.shutdown) {
                    self.queue_not_empty.wait(&self.queue_mutex);
                }

                if (self.shutdown and self.queue_head >= self.queue.items.len) {
                    return;
                }

                // O(1) dequeue using head index
                task = self.queue.items[self.queue_head];
                self.queue_head += 1;
                self.active_tasks += 1;

                // Compact queue periodically to reclaim memory
                self.compactQueue();
            }

            // Execute task outside of lock
            task.func(task.context);

            // Decrement active count
            {
                self.queue_mutex.lock();
                defer self.queue_mutex.unlock();
                self.active_tasks -= 1;
            }
        }
    }
};

// ============================================================================
// Global pool functions
// ============================================================================

/// Bridge function that matches core.worker_pool.SubmitFn signature.
fn poolSubmit(func: TaskFn, context: *anyopaque) anyerror!void {
    const p = pool_ptr.load(.acquire) orelse return error.PoolNotInitialized;
    return p.submit(func, context);
}

/// Initialize the global worker pool and register with core facade.
pub fn init(allocator: std.mem.Allocator, pool_size: usize) !void {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (pool_ptr.load(.acquire) != null) {
        return error.AlreadyInitialized;
    }
    const p = try WorkerPool.initPool(allocator, pool_size);
    pool_allocator = allocator;
    pool_ptr.store(p, .release);

    // Register with core facade
    core.worker_pool.setSubmitFn(&poolSubmit);
}

/// Shutdown the global worker pool and deregister from core facade.
pub fn deinit() void {
    pool_mutex.lock();

    const p = pool_ptr.swap(null, .acq_rel) orelse {
        pool_mutex.unlock();
        return;
    };
    pool_allocator = null;

    // Deregister from core facade
    core.worker_pool.clearSubmitFn();

    pool_mutex.unlock();

    // Deinit outside of lock to avoid deadlock if workers try to access pool
    p.deinitPool();
}
