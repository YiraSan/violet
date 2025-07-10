const std = @import("std");
const basalt = @import("basalt");

pub fn build(b: *std.Build) void {
    const platform = b.option(basalt.Platform, "platform", "x86_64_q35, aarch64_virt, riscv64_virt") orelse .x86_64_q35;
    const optimize = b.standardOptimizeOption(.{});

    const exe = basalt.addExecutable(b, .{
        .name = "system",
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
        .platform = platform,
    });

    b.installArtifact(exe);
}
