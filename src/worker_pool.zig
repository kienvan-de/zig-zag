//! Worker Pool
//!
//! A generic thread pool for executing tasks concurrently.
//! Supports configurable pool size and task queue.

const std = @import("std");
const log = @import("log.zig");

/// Task function type - takes a context pointer and executes work
pub const TaskFn = *const fn (*anyopaque) void;

/// A task in the queue
const Task = struct {
    func: TaskFn,
    context: *anyopaque,
};

/// Global worker pool instance
/// pool_ptr uses atomic operations for lock-free read access via getPool()
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

    const DEFAULT_POOL_SIZE = 4;
    const COMPACT_THRESHOLD = 64;

    /// Initialize the worker pool
    pub fn init(allocator: std.mem.Allocator, pool_size: usize) !*WorkerPool {
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
        for (self.threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, workerLoop, .{self});
            _ = i;
        }

        log.info("IO worker pool initialized with {d} threads", .{size});
        return self;
    }

    /// Shutdown the worker pool
    pub fn deinit(self: *WorkerPool) void {
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

        log.info("IO worker pool shutdown complete", .{});

        self.allocator.destroy(self);
    }

    /// Submit a task to the pool
    pub fn submit(self: *WorkerPool, comptime func: fn (*anyopaque) void, context: *anyopaque) !void {
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

/// WaitGroup for synchronizing multiple tasks
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

    /// Add to the counter
    pub fn add(self: *WaitGroup, n: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.count += n;
    }

    /// Mark one task as done
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

    /// Wait for all tasks to complete
    pub fn wait(self: *WaitGroup) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count > 0) {
            self.done_cond.wait(&self.mutex);
        }
    }
};

// ============================================================================
// Global pool functions
// ============================================================================

/// Initialize the global worker pool
pub fn init(allocator: std.mem.Allocator, pool_size: usize) !void {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (pool_ptr.load(.acquire) != null) {
        return error.AlreadyInitialized;
    }
    const p = try WorkerPool.init(allocator, pool_size);
    pool_allocator = allocator;
    pool_ptr.store(p, .release);
}

/// Shutdown the global worker pool
pub fn deinit() void {
    pool_mutex.lock();

    const p = pool_ptr.swap(null, .acq_rel) orelse {
        pool_mutex.unlock();
        return;
    };
    pool_allocator = null;

    pool_mutex.unlock();

    // Deinit outside of lock to avoid deadlock if workers try to access pool
    p.deinit();
}

/// Submit a task to the global pool
pub fn submit(comptime func: fn (*anyopaque) void, context: *anyopaque) !void {
    const p = pool_ptr.load(.acquire) orelse return error.PoolNotInitialized;
    try p.submit(func, context);
}

/// Get the global pool instance (for advanced usage)
/// Lock-free read - safe to call from any context including logging
pub fn getPool() ?*WorkerPool {
    return pool_ptr.load(.acquire);
}