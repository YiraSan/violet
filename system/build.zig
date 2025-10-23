const std = @import("std");
const basalt = @import("basalt");

pub fn build(b: *std.Build) void {
    const platform = b.option(basalt.Platform, "platform", "aarch64_qemu, riscv64_qemu, ...") orelse .aarch64_qemu;
    const optimize = b.standardOptimizeOption(.{});

    const exe = basalt.addExecutable(b, .{
        .name = "system",
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
        .platform = platform,
    });

    b.installArtifact(exe);
}
