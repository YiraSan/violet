// Copyright (c) 2024-2025 The violetOS Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const basalt = @import("basalt");

pub fn build(b: *std.Build) !void {
    const platform = b.option(basalt.Platform, "platform", "aarch64_qemu, riscv64_qemu, ...") orelse .aarch64_qemu;
    const use_uefi = b.option(bool, "use_uefi", "Kernel entry point will be configured for UEFI.") orelse true;
    const optimize = b.standardOptimizeOption(.{});

    var features_sub = std.Target.Cpu.Feature.Set.empty;
    switch (platform.arch()) {
        .aarch64 => {
            features_sub.addFeature(@intFromEnum(std.Target.aarch64.Feature.neon));
            features_sub.addFeature(@intFromEnum(std.Target.aarch64.Feature.fp_armv8));
        },
        else => {},
    }

    const target_query = std.Target.Query{
        .cpu_arch = platform.arch(),
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
        .cpu_model = .{ .explicit = platform.cpuModel() },
        .cpu_features_sub = features_sub,
    };

    const target = b.resolveTargetQuery(target_query);

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption(basalt.Platform, "platform", platform);
    build_options.addOption(bool, "use_uefi", use_uefi);
    build_options.addOption([]const u8, "version", try getVersion(b));
    kernel_mod.addImport("build_options", build_options.createModule());

    const ark_dep = b.dependency("ark", .{
        .target = target,
        .optimize = optimize,
    });
    const ark_mod = ark_dep.module("ark");
    kernel_mod.addImport("ark", ark_mod);

    const whba_dep = b.dependency("whba", .{
        .target = target,
        .optimize = optimize,
    });
    const whba_mod = whba_dep.module("whba");
    kernel_mod.addImport("whba", whba_mod);

    const basalt_dep = b.dependency("basalt", .{
        .target = target,
        .optimize = optimize,
    });
    const basalt_mod = basalt_dep.module("basalt");
    kernel_mod.addImport("basalt", basalt_mod);

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
            kernel_exe.addAssemblyFile(b.path("src/arch/aarch64/exception.s"));
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
