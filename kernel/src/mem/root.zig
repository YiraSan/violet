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

pub fn init() !void {}
