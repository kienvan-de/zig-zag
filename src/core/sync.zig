// SPDX-License-Identifier: Apache-2.0
//! Synchronization primitives for zig-zag.
//!
//! Replaces the removed `std.Thread.Mutex`, `std.Thread.RwLock`, and
//! `std.Thread.Condition` from Zig 0.16 using libc pthread APIs.
//! These do NOT require an `io: std.Io` parameter (unlike `std.Io.Mutex`).

const std = @import("std");
const c = std.c;

/// A mutual exclusion lock wrapping pthread_mutex_t.
/// Drop-in replacement for the old std.Thread.Mutex.
pub const Mutex = struct {
    inner: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = c.pthread_mutex_unlock(&self.inner);
    }

    pub fn tryLock(self: *Mutex) bool {
        return c.pthread_mutex_trylock(&self.inner) == .SUCCESS;
    }
};

/// A readers-writer lock wrapping pthread_rwlock_t.
/// Drop-in replacement for the old std.Thread.RwLock.
pub const RwLock = struct {
    inner: c.pthread_rwlock_t = .{},

    pub fn lockShared(self: *RwLock) void {
        _ = c.pthread_rwlock_rdlock(&self.inner);
    }

    pub fn unlockShared(self: *RwLock) void {
        _ = c.pthread_rwlock_unlock(&self.inner);
    }

    pub fn lock(self: *RwLock) void {
        _ = c.pthread_rwlock_wrlock(&self.inner);
    }

    pub fn unlock(self: *RwLock) void {
        _ = c.pthread_rwlock_unlock(&self.inner);
    }
};

/// A condition variable wrapping pthread_cond_t.
/// Drop-in replacement for the old std.Thread.Condition.
pub const Condition = struct {
    inner: c.pthread_cond_t = c.PTHREAD_COND_INITIALIZER,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        _ = c.pthread_cond_wait(&self.inner, &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        _ = c.pthread_cond_signal(&self.inner);
    }

    pub fn broadcast(self: *Condition) void {
        _ = c.pthread_cond_broadcast(&self.inner);
    }
};
