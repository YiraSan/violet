// --- imports --- //

const std = @import("std");
const log = std.log.scoped(.mem_virt);

const builtin = @import("builtin");

const kernel = @import("root");
const mem = kernel.mem;
const phys = mem.phys;

// --- virt.zig --- //

const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64/virt.zig"),
    .x86_64 => @import("x86_64/virt.zig"),
    else => unreachable,
};

pub const init = arch.init;
pub const flush = arch.flush;
pub const flush_all = arch.flush_all;

pub var kernel_space: VirtualSpace = undefined;

// --- structs --- //

pub const VirtualSpace = struct {
    root_table_phys: u64,

    pub fn init() !@This() {
        const addr = try phys.alloc_page(.l4K);

        const ptr: []u8 = @as([*]u8, @ptrFromInt(mem.hhdm_offset + addr))[0..phys.PageLevel.l4K.size()];
        @memset(ptr, 0);
        return .{ .root_table_phys = addr };
    }

    pub fn deinit(self: *@This()) void {
        arch.free_table_recursive(self.root_table_phys, 0);
    }

    pub fn map_contiguous(self: *@This(), virt_addr: u64, phys_addr: u64, num_pages: u64, level: phys.PageLevel, flags: MapFlags) void {
        if (!std.mem.isAligned(virt_addr, level.size())) return;
        if (!std.mem.isAligned(phys_addr, level.size())) return;

        var offset: usize = 0;
        for (0..num_pages) |_| {
            arch.map_page(self, virt_addr + offset, phys_addr + offset, level, flags, false); // TODO implement contiguous_segment
            offset += level.size();
        }
    }
};

pub const MapFlags = struct {
    writable: bool = false,
    executable: bool = false,
    user: bool = false,
    no_cache: bool = false,
    device: bool = false,
};
