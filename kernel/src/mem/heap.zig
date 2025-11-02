// --- dependencies --- //

const std = @import("std");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const virt = mem.virt;

// --- mem/heap.zig --- //

pub fn alloc(space: *virt.Space, level: mem.PageLevel, count: u16, flags: mem.virt.MemoryFlags) u64 {
    if (level != .l4K) @panic("todo");
    const res = space.reserve(count);

    res.map(0, flags);

    return res.address();
}

/// Reallocate virtually the memory somewhere else in the virtual space with more space.
pub fn ralloc(space: *virt.Space, address: u64, new_size: u16) u64 {
    _ = space;
    _ = address;
    _ = new_size;
    unreachable;
}

pub fn free(space: *virt.Space, address: u64) void {
    _ = space;
    _ = address;
    unreachable;
}
