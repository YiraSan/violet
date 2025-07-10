const std = @import("std");
const basalt = @import("basalt");

pub fn build(b: *std.Build) void {
    const platform = b.option(basalt.Platform, "platform", "q35, virt, ..") orelse .q35;

    const exe = basalt.addExecutable(b, .{
        .name = "system",
        .optimize = .ReleaseSafe,
        .root_source_file = b.path("src/main.zig"),
        .platform = platform,
    });

    b.installArtifact(exe);
}
