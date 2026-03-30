// Copyright (c) 2024-2025 The violetOS authors
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
const ark = @import("ark");

// --- imports --- //

const kernel = @import("root");

pub const heap = @import("heap.zig");
pub const phys = @import("phys.zig");
pub const syscalls = @import("syscalls.zig");
pub const vmm = @import("vmm.zig");

pub const PageLevel = ark.mem.PageLevel;

// --- collections --- //

pub const RwLock = struct {
    /// 0 = unlocked
    /// > 0 = reader count
    /// max count = writer
    state: std.atomic.Value(u32) = .init(0),

    const WRITER_LOCKED: u32 = std.math.maxInt(u32);

    pub fn lockShared(self: *@This()) u64 {
        const flags = kernel.arch.maskAndSave();

        for (0..1_000_000) |_| {
            const current = self.state.load(.monotonic);

            if (current == WRITER_LOCKED) {
                std.atomic.spinLoopHint();
                continue;
            }

            if (self.state.cmpxchgWeak(
                current,
                current + 1,
                .seq_cst,
                .monotonic,
            ) == null) {
                return flags;
            }
        }

        // std.log.err("deadlock on lockShared with return address: 0x{x}", .{@returnAddress()});
        @panic("deadlock on lockShared");
    }

    pub fn unlockShared(self: *@This(), saved_flags: u64) void {
        _ = self.state.fetchSub(1, .seq_cst);
        kernel.arch.restoreSaved(saved_flags);
    }

    pub fn tryLockExclusive(self: *@This()) ?u64 {
        const flags = kernel.arch.maskAndSave();
        if (self.state.cmpxchgStrong(0, WRITER_LOCKED, .seq_cst, .monotonic) == null) {
            return flags;
        }
        kernel.arch.restoreSaved(flags);
        return null;
    }

    pub fn lockExclusive(self: *@This()) u64 {
        const flags = kernel.arch.maskAndSave();

        for (0..1_000_000) |_| {
            if (self.state.load(.monotonic) != 0) {
                std.atomic.spinLoopHint();
                continue;
            }

            if (self.state.cmpxchgWeak(0, WRITER_LOCKED, .seq_cst, .monotonic) == null) {
                return flags;
            }
        }

        // std.log.err("deadlock on lockExclusive with return address: 0x{x}", .{@returnAddress()});
        @panic("deadlock on lockExclusive");
    }

    pub fn unlockExclusive(self: *@This(), saved_flags: u64) void {
        self.state.store(0, .seq_cst);
        kernel.arch.restoreSaved(saved_flags);
    }
};

// ---- //

comptime {
    _ = heap;
    _ = phys;
    _ = vmm;

    _ = RwLock;
}
