const std = @import("std");
const basalt = @import("basalt");

pub fn build(b: *std.Build) !void {
    const platform = b.option(basalt.Platform, "platform", "aarch64_qemu, riscv64_qemu, ...") orelse .aarch64_qemu;
    const optimize = b.standardOptimizeOption(.{});

    const target_query = std.Target.Query{
        .cpu_arch = platform.arch(),
        .os_tag = .uefi,
        .abi = .none,
        .ofmt = .coff,
    };

    const target = b.resolveTargetQuery(target_query);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .stack_check = false,
        .stack_protector = false,
    });

    const build_options = b.addOptions();
    build_options.addOption(basalt.Platform, "platform", platform);
    build_options.addOption([]const u8, "version", try getVersion(b));
    mod.addImport("build_options", build_options.createModule());

    const ark_dep = b.dependency("ark", .{
        .target = target,
        .optimize = optimize,
    });
    const ark_mod = ark_dep.module("ark");
    mod.addImport("ark", ark_mod);

    const exe = b.addExecutable(.{
        .name = "bootloader",
        .root_module = mod,
        .use_llvm = true,
    });

    exe.want_lto = false;
    exe.subsystem = .EfiApplication;

    b.installArtifact(exe);
}

fn getVersion(b: *std.Build) ![]const u8 {
    var tree = try std.zig.Ast.parse(b.allocator, @embedFile("build.zig.zon"), .zon);
    defer tree.deinit(b.allocator);
    const version_str = tree.tokenSlice(tree.nodes.items(.main_token)[2]);
    return b.allocator.dupe(u8, version_str[1 .. version_str.len - 1]);
}
