const std = @import("std");

pub fn build(b: *std.Build) void {
    const mod = b.addModule("uart_pl011", .{
        .root_source_file = b.path("src/root.zig"),
    });

    _ = mod;
}
