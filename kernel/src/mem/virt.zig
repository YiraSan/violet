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

pub fn init() void {
    arch.init();
}

pub fn flush(virt_addr: u64) void {
    arch.flush(virt_addr);
}

pub fn flush_all() void {
    arch.flush_all();
}

pub var kernel_space: AddressSpace = undefined;

// --- structs --- //

pub const MapFlags = struct {
    writable: bool = false,
    executable: bool = false,
    user: bool = false,
    no_cache: bool = false,
    device: bool = false,
};

const VIRTUAL_SPACE_BASE = 0x0000_0000_4000_0000; // 1 GiB
const VIRTUAL_SPACE_END = 0x0000_2000_0000_0000; // 32 TiB
const VIRTUAL_PAGE_SIZE = 32 * 0x0010_0000; // 32 MiB
const VIRTUAL_PAGE_SHIFT = 25;
const VIRTUAL_SPACE_LEN = VIRTUAL_SPACE_END / VIRTUAL_PAGE_SIZE;
const BITMAP_SIZE = VIRTUAL_SPACE_LEN / 8; // 128 KiB
const BITMAP_PAGE_LEN = BITMAP_SIZE / mem.phys.PageLevel.l4K.size(); // 32 pages

pub const AddressRange = struct {
    virt_base_index: u32,
    virt_page_len: u32,

    pub fn base(self: AddressRange) u64 {
        return @as(u64, self.virt_base_index) << VIRTUAL_PAGE_SHIFT;
    }

    pub fn len(self: AddressRange) u64 {
        return @as(u64, self.virt_page_len) << VIRTUAL_PAGE_SHIFT;
    }
};

pub const AddressSpace = struct {
    root_table_phys: u64,
    bitmap: []u64,
    next_hint: u64,

    pub fn init(root_table_phys: ?u64) !@This() {
        var virtual_space: @This() = undefined;

        virtual_space.bitmap = @as([*]u64, @ptrFromInt(mem.hhdm_offset + try mem.phys.alloc_contiguous_pages(BITMAP_PAGE_LEN, .l4K, false)))[0 .. VIRTUAL_SPACE_LEN / 64];
        @memset(virtual_space.bitmap[0 .. (VIRTUAL_SPACE_BASE >> VIRTUAL_PAGE_SHIFT) / 64], 0xffff_ffff_ffff_ffff);

        virtual_space.next_hint = VIRTUAL_SPACE_BASE >> VIRTUAL_PAGE_SHIFT;

        if (root_table_phys) |root_addr| {
            virtual_space.root_table_phys = root_addr;
        } else {
            virtual_space.root_table_phys = try phys.alloc_page(.l4K);
            const ptr: []u8 = @as([*]u8, @ptrFromInt(mem.hhdm_offset + virtual_space.root_table_phys))[0..phys.PageLevel.l4K.size()];
            @memset(ptr, 0);
        }

        return virtual_space;
    }

    pub fn deinit(self: *@This()) void {
        arch.free_table_recursive(self.root_table_phys, 0);
        mem.phys.free_contiguous_pages(@intFromPtr(self.bitmap) - mem.hhdm_offset, BITMAP_PAGE_LEN, .l4K);
    }

    inline fn read_bitmap(self: *@This(), page_index: u64) bool {
        const bit_index = page_index % 64;
        const word_index = page_index / 64;
        const word = self.bitmap[word_index];
        const mask: u64 = @as(u64, 1) << @as(u6, @intCast(bit_index));
        return (word & mask) != 0;
    }

    inline fn write_bitmap(self: *@This(), page_index: u64, value: bool) void {
        const bit_index = page_index % 64;
        const word_index = page_index / 64;

        const mask: u64 = @as(u64, 1) << @as(u6, @intCast(bit_index));
        if (value) {
            self.bitmap[word_index] |= mask;
        } else {
            self.bitmap[word_index] &= ~mask;
        }
    }

    pub fn allocate(self: *@This(), num_pages: u64, level: phys.PageLevel) AddressRange {
        const length = std.math.divCeil(u64, num_pages << level.shift(), VIRTUAL_PAGE_SIZE) catch unreachable;

        var i: usize = self.next_hint;
        while (i < VIRTUAL_SPACE_LEN) {
            var run: usize = 0;

            while (i + run < VIRTUAL_SPACE_LEN and !self.read_bitmap(run + i)) {
                run += 1;
                if (run == length) {
                    for (0..length) |j| {
                        self.write_bitmap(i + j, true);
                    }
                    
                    self.next_hint = i + length;

                    return .{
                        .virt_base_index = @truncate(i),
                        .virt_page_len = @truncate(length),
                    };
                }
            }

            if (run == 0) {
                i += 1;
            } else {
                i += run;
            }
        }

        // NOTE this is temporary
        @panic("reached the end of virtual address space");
    }

    pub fn free(self: *@This(), range: AddressRange) void {
        for (range.virt_base_index..(range.virt_base_index + range.virt_page_len)) |idx| {
            self.write_bitmap(idx, false);
        }
    }

    pub fn map_contiguous(self: *@This(), range: AddressRange, phys_addr: u64, num_pages: u64, level: phys.PageLevel, flags: MapFlags) void {
        std.debug.assert(std.mem.isAligned(phys_addr, level.size()));
        std.debug.assert(num_pages << level.shift() <= range.len());

        const virt_base = range.base();

        var offset: usize = 0;
        for (0..num_pages) |_| {
            arch.map_page(self, virt_base + offset, phys_addr + offset, level, flags, false); // TODO implement contiguous mapping
            offset += level.size();
        }
    }

    pub fn map_noncontiguous(self: *@This(), range: AddressRange, pages: []u64, level: phys.PageLevel, flags: MapFlags) void {
        std.debug.assert(pages.len << level.shift() <= range.len());

        const virt_base = range.base();

        var offset: usize = 0;
        for (0..pages.len) |i| {
            arch.map_page(self, virt_base + offset, pages[i], level, flags, false);
            offset += level.size();
        }
    }
};
