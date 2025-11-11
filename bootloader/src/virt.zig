// --- dependencies --- //

const std = @import("std");
const builtin = @import("builtin");
const ark = @import("ark");

pub const PageLevel = ark.mem.PageLevel;
pub const MemoryFlags = ark.mem.MemoryFlags;

const uefi = std.os.uefi;
const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;

const impl = switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64/virt.zig"),
    else => unreachable,
};

// --- virt.zig --- //

pub var last_high_addr: u64 = 0xffff_8000_0000_0000;
pub var hhdm_base: u64 = 0;
pub var hhdm_limit: u64 = 0;

pub var table: u64 = 0;

pub fn init(boot_services: *uefi.tables.BootServices) void {
    impl.init(boot_services);
}

pub fn mapContiguous(
    l0_table: u64,
    virt_addr: u64,
    phys_addr: u64,
    page_level: PageLevel,
    flags: MemoryFlags,
    count: usize,
) void {
    var offset: usize = 0;
    for (0..count) |_| {
        const pa = phys_addr + offset;
        const va = virt_addr + offset;

        mapPage(l0_table, va, pa, page_level, flags);

        offset += page_level.size();
    }
}

pub fn mapPage(
    l0_table: u64,
    virt_addr: u64,
    phys_addr: u64,
    page_level: PageLevel,
    flags: MemoryFlags,
) void {
    impl.mapPage(l0_table, virt_addr, phys_addr, page_level, flags);
}
