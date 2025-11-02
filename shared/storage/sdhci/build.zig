const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const mod = b.addModule("sdhci", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    _ = mod;
}
