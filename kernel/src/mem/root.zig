// --- dependencies --- //

const std = @import("std");

const uefi = std.os.uefi;

// --- imports --- //

pub const phys = @import("phys.zig");
pub const virt = @import("virt.zig");
pub const heap = @import("heap.zig");

// --- mem/root.zig --- //

pub const PageLevel = enum(u2) {
    l4K = 0b00,
    l2M = 0b01,
    l1G = 0b10,

    pub inline fn size(self: @This()) u64 {
        return switch (self) {
            .l4K => 0x0000_1000,
            .l2M => 0x0020_0000,
            .l1G => 0x4000_0000,
        };
    }

    pub inline fn shift(self: @This()) u6 {
        return switch (self) {
            .l4K => 12,
            .l2M => 21,
            .l1G => 30,
        };
    }
};

pub const SpinLock = struct {
    value: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *SpinLock) void {
        while (true) {
            if (self.value.cmpxchgWeak(0, 1, .seq_cst, .seq_cst) == null) {
                break;
            }
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.value.store(0, .seq_cst);
    }
};

pub const MemoryMap = struct {
    map: [*]uefi.tables.MemoryDescriptor,
    map_size: usize,
    descriptor_size: usize,

    pub fn get(self: MemoryMap, index: usize) ?*uefi.tables.MemoryDescriptor {
        const i = self.descriptor_size * index;
        if (i > (self.map_size - self.descriptor_size)) return null;
        return @ptrFromInt(@intFromPtr(self.map) + i);
    }
};

pub const Arc = struct {
    reference_counter: std.atomic.Value(u64) = .init(0),

    pub fn acquire(self: *@This()) void {
        _ = self.reference_counter.fetchAdd(1, .seq_cst);
    }

    pub fn drop(self: *@This()) void {
        _ = self.reference_counter.fetchSub(1, .seq_cst);
    }

    pub fn isDropped(self: *@This()) bool {
        return self.reference_counter.load(.seq_cst) == 0;
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
