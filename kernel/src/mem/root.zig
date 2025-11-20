// Copyright (c) 2025 The violetOS authors
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

const uefi = std.os.uefi;

const ark = @import("ark");

// --- imports --- //

const kernel = @import("root");

pub const phys = @import("phys.zig");
pub const virt = @import("virt.zig");
pub const heap = @import("heap.zig");

// --- mem/root.zig --- //

pub const PageLevel = ark.mem.PageLevel;

pub const RwLock = struct {
    /// 0 = unlocked
    /// > 0 = reader count
    /// max count = writer
    state: std.atomic.Value(u32) = .init(0),

    const WRITER_LOCKED: u32 = std.math.maxInt(u32);

    pub fn lockShared(self: *@This()) u64 {
        const flags = kernel.arch.maskAndSave();

        while (true) {
            const current = self.state.load(.monotonic);

            if (current == WRITER_LOCKED) {
                std.atomic.spinLoopHint();
                continue;
            }

            if (self.state.cmpxchgWeak(
                current,
                current + 1,
                .acq_rel,
                .monotonic,
            ) == null) {
                return flags;
            }
        }
    }

    pub fn unlockShared(self: *@This(), saved_flags: u64) void {
        _ = self.state.fetchSub(1, .release);
        kernel.arch.restoreSaved(saved_flags);
    }

    pub fn lockExclusive(self: *@This()) u64 {
        const flags = kernel.arch.maskAndSave();

        while (true) {
            if (self.state.load(.monotonic) != 0) {
                std.atomic.spinLoopHint();
                continue;
            }

            if (self.state.cmpxchgWeak(0, WRITER_LOCKED, .acq_rel, .monotonic) == null) {
                return flags;
            }
        }
    }

    pub fn unlockExclusive(self: *@This(), saved_flags: u64) void {
        self.state.store(0, .release);
        kernel.arch.restoreSaved(saved_flags);
    }
};

pub fn Queue(comptime T: type) type {
    return struct {
        items: []T = undefined,
        cursor: usize = 0,
        alloc_count: usize = 0,

        pub fn count(self: *@This()) usize {
            return self.items.len - self.cursor;
        }

        pub fn append(self: *@This(), item: T) !void {
            if (self.alloc_count > 0) {
                const used_size = self.items.len * @sizeOf(T);
                const alloc_size = self.alloc_count << PageLevel.l4K.shift();
                const current_count = (alloc_size - used_size) / @sizeOf(T);

                if ((self.items.len + 1) > current_count) {
                    self.alloc_count += std.mem.alignForward(usize, @sizeOf(T), PageLevel.l4K.size()) >> PageLevel.l4K.shift();
                    self.items.ptr = @ptrFromInt(heap.realloc(
                        &virt.kernel_space,
                        @intFromPtr(self.items.ptr),
                        @intCast(self.alloc_count),
                    ));
                }

                self.items.len += 1;
            } else {
                self.alloc_count = std.mem.alignForward(usize, @sizeOf(T), PageLevel.l4K.size()) >> PageLevel.l4K.shift();
                self.items.ptr = @ptrFromInt(heap.alloc(
                    &virt.kernel_space,
                    .l4K,
                    @intCast(self.alloc_count),
                    .{ .writable = true },
                    false,
                ));

                self.items.len = 1;
            }

            self.items[self.items.len - 1] = item;
        }

        pub fn pop(self: *@This()) T {
            const item_ptr = &self.items[self.cursor];
            const item = item_ptr.*;
            self.cursor += 1;

            if (self.cursor * @sizeOf(T) > 0x1000) {
                std.log.warn("Queue.pop unimplemented buffer shrinking.", .{});
                // self.cursor = 0;
            }

            return item;
        }
    };
}

pub const SlotKey = packed struct(u64) {
    id: u24,
    /// Ignored by uninstancied SlotMap.
    instance: u8,
    generation: u32,

    pub fn isNull(self: @This()) bool {
        return self.generation == 0;
    }
};

pub fn SlotMap(comptime T: type) type {
    return struct {
        pub fn insert(self: *@This(), value: T) !SlotKey {
            _ = self;
            _ = value;
            unreachable;
        }

        pub fn remove(self: *@This(), key: SlotKey) void {
            _ = self;
            _ = key;
            unreachable;
        }

        pub fn get(self: *@This(), key: SlotKey) ?*T {
            _ = self;
            _ = key;
            unreachable;
        }
    };
}

pub fn ShardedSlotMap(comptime T: type) type {
    _ = T;

    return struct {
        instances: [256]*Instance = undefined,
        instance_count: std.atomic.Value(usize) = .init(0),

        pub const Instance = struct {
            id: u8,
        };

        pub fn init(self: *@This(), instance: *Instance) void {
            const instance_id = self.instance_count.fetchAdd(1, .seq_cst);
            if (instance_id > 255) @panic("too much slot map");

            instance.* = .{
                .id = instance_id,
            };

            self.instances[instance_id] = instance;
        }
    };
}
