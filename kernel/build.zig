const std = @import("std");
const basalt = @import("basalt");

pub fn build(b: *std.Build) !void {
    const platform = b.option(basalt.Platform, "platform", "x86_64_q35, aarch64_virt, riscv64_virt") orelse .x86_64_q35;
    const optimize = b.standardOptimizeOption(.{});

    var kernel_query = std.Target.Query{
        .cpu_arch = platform.arch(),
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
    };

    switch (kernel_query.cpu_arch.?) {
        .x86_64 => {
            const Features = std.Target.x86.Feature;
            kernel_query.cpu_features_sub.addFeature(@intFromEnum(Features.mmx));
            kernel_query.cpu_features_sub.addFeature(@intFromEnum(Features.sse));
            kernel_query.cpu_features_sub.addFeature(@intFromEnum(Features.sse2));
            kernel_query.cpu_features_sub.addFeature(@intFromEnum(Features.avx));
            kernel_query.cpu_features_sub.addFeature(@intFromEnum(Features.avx2));
            kernel_query.cpu_features_add.addFeature(@intFromEnum(Features.soft_float));
        },
        .aarch64 => {},
        .riscv64 => {},
        else => unreachable,
    }

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel.zig"),
        .target = b.resolveTargetQuery(kernel_query),
        .optimize = optimize,
        .red_zone = false,
    });

    const limine_zig = b.dependency("limine_zig", .{
        .api_revision = 3,
    });

    kernel_mod.addImport("limine", limine_zig.module("limine"));

    const build_options = b.addOptions();
    build_options.addOption(basalt.Platform, "platform", platform);
    build_options.addOption([]const u8, "version", try getVersion(b));
    kernel_mod.addImport("build_options", build_options.createModule());

    const kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
        .code_model = switch (kernel_query.cpu_arch.?) {
            .aarch64 => .small,
            .x86_64 => .kernel,
            .riscv64 => .medium,
            else => unreachable,
        },
        .use_llvm = true,
    });

    kernel_exe.pie = true;
    kernel_exe.entry = .disabled;
    kernel_exe.want_lto = false;
    kernel_exe.out_filename = "kernel.elf";
    kernel_exe.setLinkerScript(b.path("linker.lds"));

    switch (kernel_query.cpu_arch.?) {
        .aarch64 => {
            kernel_exe.addAssemblyFile(b.path("src/arch/aarch64/exception.s"));
        },
        .x86_64 => {
            kernel_exe.addAssemblyFile(b.path("src/arch/x86_64/gdt.s"));
        },
        else => {},
    }

    b.installArtifact(kernel_exe);
}

fn getVersion(b: *std.Build) ![]const u8 {
    var tree = try std.zig.Ast.parse(b.allocator, @embedFile("build.zig.zon"), .zon);
    defer tree.deinit(b.allocator);
    const version_str = tree.tokenSlice(tree.nodes.items(.main_token)[2]);
    return b.allocator.dupe(u8, version_str[1 .. version_str.len - 1]);
}
