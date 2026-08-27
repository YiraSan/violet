// Copyright (c) 2024-2026 YiraSan
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
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const query = b.standardTargetOptionsQueryOnly(.{});
    const arch = query.cpu_arch orelse .aarch64;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = query.cpu_model,
        .cpu_features_add = getFeaturesAdd(arch),
        .cpu_features_sub = getFeaturesSub(arch),
    });

    const optimize = b.standardOptimizeOption(.{});

    if (optimize == .ReleaseFast) {
        @panic("ReleaseFast is forbidden");
    }

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = switch (arch) {
            .aarch64 => .small,
            .riscv64 => .medany,
            .x86_64 => .kernel,
            else => unreachable,
        },
        .red_zone = false,
        .omit_frame_pointer = false,
        .stack_check = false,
        .stack_protector = false,
        .link_libc = false,
    });

    const drivers = b.option([]const u8, "drivers", "kernel drivers set") orelse "";

    const page_size = b.option(usize, "page_size", "4, 16, 64") orelse 4;
    const page_levels = b.option(usize, "page_levels", "3, 4, 5") orelse 4;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", zon.version);
    build_options.addOption([]const u8, "drivers", drivers);
    build_options.addOption(usize, "page_size", page_size);
    build_options.addOption(usize, "page_levels", page_levels);
    kernel_mod.addImport("build_options", build_options.createModule());

    const limine_dep = b.dependency("limine", .{ .revision = 6 });
    kernel_mod.addImport("limine", limine_dep.module("limine"));

    const basalt_dep = b.dependency("basalt", .{
        .is_module = true,
    });
    const basalt_mod = basalt_dep.module("basalt");
    kernel_mod.addImport("basalt", basalt_mod);

    const kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
        .use_llvm = true,
        .use_lld = true,
    });

    kernel_exe.entry = .disabled;
    kernel_exe.lto = .none;
    kernel_exe.pie = false;
    kernel_exe.setLinkerScript(b.path("linker.lds"));

    b.installArtifact(kernel_exe);
}

fn getFeaturesAdd(arch: std.Target.Cpu.Arch) std.Target.Cpu.Feature.Set {
    var features_add = std.Target.Cpu.Feature.Set.empty;

    switch (arch) {
        .aarch64 => {
            const Feature = std.Target.aarch64.Feature;

            _ = Feature;
        },
        .x86_64 => {
            const Feature = std.Target.x86.Feature;

            features_add.addFeature(@intFromEnum(Feature.popcnt));
            features_add.addFeature(@intFromEnum(Feature.soft_float));
        },
        .riscv64 => {
            const Feature = std.Target.riscv.Feature;

            _ = Feature;
        },
        else => unreachable,
    }

    return features_add;
}

fn getFeaturesSub(arch: std.Target.Cpu.Arch) std.Target.Cpu.Feature.Set {
    var features_sub = std.Target.Cpu.Feature.Set.empty;

    switch (arch) {
        .aarch64 => {
            const Feature = std.Target.aarch64.Feature;

            features_sub.addFeature(@intFromEnum(Feature.fp_armv8));
            features_sub.addFeature(@intFromEnum(Feature.neon));
            features_sub.addFeature(@intFromEnum(Feature.crypto));
        },
        .x86_64 => {
            const Feature = std.Target.x86.Feature;

            features_sub.addFeature(@intFromEnum(Feature.mmx));

            features_sub.addFeature(@intFromEnum(Feature.sse));
            features_sub.addFeature(@intFromEnum(Feature.sse2));

            features_sub.addFeature(@intFromEnum(Feature.avx));
            features_sub.addFeature(@intFromEnum(Feature.avx2));
        },
        .riscv64 => {
            const Feature = std.Target.riscv.Feature;

            features_sub.addFeature(@intFromEnum(Feature.f));
            features_sub.addFeature(@intFromEnum(Feature.d));
            features_sub.addFeature(@intFromEnum(Feature.q));
            features_sub.addFeature(@intFromEnum(Feature.v));
        },
        else => unreachable,
    }

    return features_sub;
}
