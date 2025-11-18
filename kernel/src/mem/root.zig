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

pub const SpinLock = struct {
    value: std.atomic.Value(u32) = .init(0),
    lock_core: std.atomic.Value(usize) = .init(std.math.maxInt(usize)),

    pub fn lock(self: *SpinLock) void {
        const cpu_id = kernel.arch.Cpu.id();
        while (true) {
            if (self.value.cmpxchgWeak(0, 1, .seq_cst, .seq_cst) == null) {
                self.lock_core.store(cpu_id, .seq_cst);
                break;
            } else if (self.lock_core.load(.seq_cst) == cpu_id) {
                break; // TODO investigating on the possibility that it creates issues.
            }
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.value.store(0, .seq_cst);
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
