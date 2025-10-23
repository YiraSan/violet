const std = @import("std");
const basalt = @import("basalt");

pub fn build(b: *std.Build) !void {
    const platform = b.option(basalt.Platform, "platform", "aarch64_qemu, riscv64_qemu, ...") orelse .aarch64_qemu;
    const optimize = b.standardOptimizeOption(.{});

    const target_query = std.Target.Query{
        .cpu_arch = platform.arch(),
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
    };

    const target = b.resolveTargetQuery(target_query);

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption(basalt.Platform, "platform", platform);
    build_options.addOption([]const u8, "version", try getVersion(b));
    kernel_mod.addImport("build_options", build_options.createModule());

    const ark_dep = b.dependency("ark", .{
        .target = target,
        .optimize = optimize,
    });
    const ark_mod = ark_dep.module("ark");
    kernel_mod.addImport("ark", ark_mod);

    const kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
        .use_llvm = true,
    });

    kernel_exe.entry = .disabled;
    kernel_exe.want_lto = false;
    kernel_exe.setLinkerScript(b.path("linker.lds"));

    switch (target.result.cpu.arch) {
        .aarch64 => {
            kernel_exe.addAssemblyFile(b.path("src/exception.s"));
        },
        else => unreachable,
    }

    b.installArtifact(kernel_exe);
}

fn getVersion(b: *std.Build) ![]const u8 {
    var tree = try std.zig.Ast.parse(b.allocator, @embedFile("build.zig.zon"), .zon);
    defer tree.deinit(b.allocator);
    const version_str = tree.tokenSlice(tree.nodes.items(.main_token)[2]);
    return b.allocator.dupe(u8, version_str[1 .. version_str.len - 1]);
}
