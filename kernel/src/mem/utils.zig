// Copyright (c) 2024-2026 YiraSan
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// --- dependencies --- //

const std = @import("std");

// --- imports --- //

const kernel = @import("root");

const arch = kernel.arch;

const cpu = arch.cpu;

const interrupts = arch.interrupts;
const InterruptState = interrupts.InterruptState;

// --- mem/utils.zig --- //

pub const LockMode = enum { read, write };

pub const LockState = packed struct(u32) {
    readers: u30 = 0,
    writer_gate: bool = false,
    writer_active: bool = false,
};

/// WARNING: This RwLock is non-recursive. Attempting to acquire it twice will deadlock.
pub const RwLock = struct {
    state: std.atomic.Value(u32) = .init(0),

    const MAX_READERS = std.math.maxInt(u30);
    const WRITER_BIT = @as(u32, 1) << 31;

    pub fn tryAcquire(self: *@This(), comptime mode: LockMode) ?InterruptState {
        const prev_int = interrupts.set(.disabled);
        const raw_current = self.state.load(.monotonic);
        const current: LockState = @bitCast(raw_current);

        if (mode == .read) {
            if (!current.writer_active and !current.writer_gate) {
                if (current.readers == MAX_READERS) {
                    @branchHint(.cold);
                    @panic("RwLock: limit of readers reached in tryAcquire!");
                }

                var next = current;
                next.readers += 1;

                if (self.state.cmpxchgStrong(raw_current, @bitCast(next), .acquire, .monotonic) == null) {
                    return prev_int;
                }
            }
        } else {
            if (current.readers == 0 and !current.writer_active) {
                var next = current;
                next.writer_active = true;
                next.writer_gate = current.writer_gate;

                if (self.state.cmpxchgStrong(raw_current, @bitCast(next), .acquire, .monotonic) == null) {
                    return prev_int;
                }
            }
        }

        _ = interrupts.set(prev_int);
        return null;
    }

    pub fn acquire(self: *@This(), comptime mode: LockMode, comptime polite_spins: u16) InterruptState {
        const prev_int = interrupts.set(.disabled);
        var spins: u16 = 0;

        const _polite_spins: u16 = if (polite_spins == 0) 128 else @min(@max(polite_spins, 64), 512);

        while (true) {
            const raw_current = self.state.load(.monotonic);
            const current: LockState = @bitCast(raw_current);

            if (mode == .read) {
                if (current.writer_active or current.writer_gate) {
                    @branchHint(.unlikely);

                    cpu.pause();
                    continue;
                }

                if (current.readers == MAX_READERS) {
                    @branchHint(.cold);
                    @panic("RwLock: DEADLOCK limit of readers reached!");
                }

                var next = current;
                next.readers += 1;

                if (self.state.cmpxchgWeak(raw_current, @bitCast(next), .acquire, .monotonic) == null) {
                    @branchHint(.likely);
                    return prev_int;
                }

                cpu.pause();
            } else {
                if (current.writer_active or current.readers > 0) {
                    @branchHint(.unlikely);

                    if (!current.writer_gate and spins >= _polite_spins) {
                        var next = current;
                        next.writer_gate = true;
                        _ = self.state.cmpxchgWeak(raw_current, @bitCast(next), .monotonic, .monotonic);
                    }

                    if (spins < _polite_spins) {
                        cpu.pause();
                    } else {
                        var i: u8 = 0;
                        const backoff_limit = @as(u8, 1) << @min(spins - _polite_spins, 6);
                        while (i < backoff_limit) : (i += 1) {
                            cpu.pause();
                        }
                    }

                    spins +|= 1;
                    continue;
                }

                var next = current;
                next.writer_active = true;
                next.writer_gate = false;

                if (self.state.cmpxchgWeak(raw_current, @bitCast(next), .acquire, .monotonic) == null) {
                    @branchHint(.likely);
                    return prev_int;
                }
            }
        }
    }

    pub fn release(self: *@This(), comptime mode: LockMode, saved: InterruptState) void {
        if (mode == .read) {
            const raw_prev = self.state.fetchSub(1, .release);
            const prev: LockState = @bitCast(raw_prev);

            if (prev.readers == 0) {
                @branchHint(.cold);
                @panic("RwLock: release(.read) called on an unlocked lock!");
            }

            if (prev.writer_active) {
                @branchHint(.cold);
                @panic("RwLock: release(.read) called on an exclusive lock!");
            }
        } else {
            const raw_prev = self.state.fetchAnd(~WRITER_BIT, .release);
            const prev: LockState = @bitCast(raw_prev);

            if (!prev.writer_active) {
                @branchHint(.cold);
                @panic("RwLock: release(.write) called but lock was not exclusive!");
            }
        }

        _ = interrupts.set(saved);
    }

    pub fn tryUpgrade(self: *@This()) bool {
        const raw_current = self.state.load(.monotonic);
        const current: LockState = @bitCast(raw_current);

        if (current.readers == 0 or current.writer_active) {
            @branchHint(.cold);
            @panic("RwLock: tryUpgrade called without a valid read lock!");
        }

        if (current.writer_gate) return false;

        if (current.readers == 1) {
            var next = current;
            next.readers = 0;
            next.writer_active = true;

            if (self.state.cmpxchgStrong(raw_current, @bitCast(next), .acquire, .monotonic) == null) {
                return true;
            }
        }

        return false;
    }

    pub fn downgrade(self: *@This()) void {
        while (true) {
            const raw_current = self.state.load(.monotonic);
            const current: LockState = @bitCast(raw_current);

            if (!current.writer_active) {
                @branchHint(.cold);
                @panic("RwLock: downgrade called but lock is not exclusive!");
            }

            var next = current;
            next.writer_active = false;
            next.readers = 1;

            if (self.state.cmpxchgWeak(raw_current, @bitCast(next), .release, .monotonic) == null) {
                @branchHint(.likely);
                break;
            }
        }
    }
};
