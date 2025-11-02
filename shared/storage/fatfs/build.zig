const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const mod = b.addModule("fatfs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const diskio_dep = b.dependency("diskio", .{
        .target = target,
    });

    mod.addImport("diskio", diskio_dep.module("diskio"));
}
