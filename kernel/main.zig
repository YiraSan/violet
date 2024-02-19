const std = @import("std");
const build_options = @import("build_options");

const limine = @import("limine.zig");
const pmm = @import("mm/pmm.zig");

pub fn main() !void {

    std.log.debug("kernel/version {s}\n", .{build_options.version});
    std.log.debug("boot time: {}", .{limine.boot_time.boot_time});

    try limine.init();
    try pmm.init();

    // test: framebuffer
    if (limine.framebuffer.framebuffer_count > 0) {
        const framebuffer = limine.framebuffer.framebuffers()[0];

        for (0..100) |i| {
            const pixel_offset = i * framebuffer.pitch + i * 4;

            @as(*u32, @ptrCast(@alignCast(framebuffer.address + pixel_offset))).* = 0xFFFFFFFF;
        }
    }
    
}
