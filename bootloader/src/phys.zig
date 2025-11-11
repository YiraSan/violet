// --- dependencies --- //

const std = @import("std");
const ark = @import("ark");

const uefi = std.os.uefi;
const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;

// --- phys.zig --- //

pub fn allocPages(count: usize) u64 {
    var physical_address: [*]align(0x1000) u8 = undefined;
    _ = uefi.system_table.boot_services.?.allocatePages(.allocate_any_pages, .loader_data, count, &physical_address);
    @memset(physical_address[0..0x1000], 0);
    return @intFromPtr(physical_address);
}

pub fn freePages(address: u64, count: usize) void {
    _ = uefi.system_table.boot_services.?.freePages(@ptrFromInt(address), count);
}
