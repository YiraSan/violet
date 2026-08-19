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

pub const Drivers = enum {
    uart_pl011,
    ns16550a,
};

pub fn build(b: *std.Build) !void {
    const query = b.standardTargetOptionsQueryOnly(.{});
    const arch = query.cpu_arch.?;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = query.cpu_model,
        .cpu_features_sub = getFeaturesSub(arch),
    });

    const optimize = b.standardOptimizeOption(.{});

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
    });

    const drivers = b.option([]const u8, "drivers", "optional kernel drivers") orelse "";
    _ = drivers;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", try getVersion(b));
    kernel_mod.addImport("build_options", build_options.createModule());

    const limine_dep = b.dependency("limine", .{
        .revision = 6,
        .no_pointers = false,
    });
    kernel_mod.addImport("limine", limine_dep.module("limine"));

    const basalt_dep = b.dependency("basalt", .{
        .target = target,
        .optimize = optimize,
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

fn getVersion(b: *std.Build) ![]const u8 {
    var tree = try std.zig.Ast.parse(b.allocator, @embedFile("build.zig.zon"), .{ .mode = .zon });
    defer tree.deinit(b.allocator);
    const version_str = tree.tokenSlice(tree.nodes.items(.main_token)[2]);
    return b.allocator.dupe(u8, version_str[1 .. version_str.len - 1]);
}

fn getFeaturesSub(arch: std.Target.Cpu.Arch) std.Target.Cpu.Feature.Set {
    var features_sub = std.Target.Cpu.Feature.Set.empty;

    switch (arch) {
        .aarch64 => {
            const Feature = std.Target.aarch64.Feature;

            features_sub.addFeature(@backingInt(Feature.fp_armv8));
            features_sub.addFeature(@backingInt(Feature.neon));
            features_sub.addFeature(@backingInt(Feature.crypto));
            features_sub.addFeature(@backingInt(Feature.aes));
            features_sub.addFeature(@backingInt(Feature.sha2));
            features_sub.addFeature(@backingInt(Feature.sha3));
            features_sub.addFeature(@backingInt(Feature.sm4));
            features_sub.addFeature(@backingInt(Feature.fullfp16));
            features_sub.addFeature(@backingInt(Feature.fp16fml));
            features_sub.addFeature(@backingInt(Feature.bf16));
            features_sub.addFeature(@backingInt(Feature.i8mm));
            features_sub.addFeature(@backingInt(Feature.dotprod));
            features_sub.addFeature(@backingInt(Feature.rdm));
            features_sub.addFeature(@backingInt(Feature.complxnum));
            features_sub.addFeature(@backingInt(Feature.jsconv));

            features_sub.addFeature(@backingInt(Feature.sve));
            features_sub.addFeature(@backingInt(Feature.sve2));
            features_sub.addFeature(@backingInt(Feature.sve2p1));
            features_sub.addFeature(@backingInt(Feature.sve2_aes));
            features_sub.addFeature(@backingInt(Feature.sve2_bitperm));
            features_sub.addFeature(@backingInt(Feature.sve2_sha3));
            features_sub.addFeature(@backingInt(Feature.sve2_sm4));
            features_sub.addFeature(@backingInt(Feature.f32mm));
            features_sub.addFeature(@backingInt(Feature.f64mm));

            features_sub.addFeature(@backingInt(Feature.sme));
            features_sub.addFeature(@backingInt(Feature.sme2));
            features_sub.addFeature(@backingInt(Feature.sme2p1));
        },
        .x86_64 => {
            const Feature = std.Target.x86.Feature;

            features_sub.addFeature(@backingInt(Feature.mmx));

            features_sub.addFeature(@backingInt(Feature.sse3));
            features_sub.addFeature(@backingInt(Feature.ssse3));
            features_sub.addFeature(@backingInt(Feature.sse4_1));
            features_sub.addFeature(@backingInt(Feature.sse4_2));
            features_sub.addFeature(@backingInt(Feature.sse4a));

            features_sub.addFeature(@backingInt(Feature.avx));
            features_sub.addFeature(@backingInt(Feature.avx2));
            features_sub.addFeature(@backingInt(Feature.fma));
            features_sub.addFeature(@backingInt(Feature.f16c));
            features_sub.addFeature(@backingInt(Feature.gfni));
            features_sub.addFeature(@backingInt(Feature.vaes));
            features_sub.addFeature(@backingInt(Feature.vpclmulqdq));

            features_sub.addFeature(@backingInt(Feature.avx512f));
            features_sub.addFeature(@backingInt(Feature.avx512cd));
            features_sub.addFeature(@backingInt(Feature.avx512bw));
            features_sub.addFeature(@backingInt(Feature.avx512dq));
            features_sub.addFeature(@backingInt(Feature.avx512vl));
            features_sub.addFeature(@backingInt(Feature.avx512ifma));
            features_sub.addFeature(@backingInt(Feature.avx512vbmi));
            features_sub.addFeature(@backingInt(Feature.avx512vbmi2));
            features_sub.addFeature(@backingInt(Feature.avx512vnni));
            features_sub.addFeature(@backingInt(Feature.avx512bitalg));
            features_sub.addFeature(@backingInt(Feature.avx512vpopcntdq));
            features_sub.addFeature(@backingInt(Feature.avx512bf16));
            features_sub.addFeature(@backingInt(Feature.avx512fp16));

            features_sub.addFeature(@backingInt(Feature.amx_tile));
            features_sub.addFeature(@backingInt(Feature.amx_int8));
            features_sub.addFeature(@backingInt(Feature.amx_bf16));
            features_sub.addFeature(@backingInt(Feature.amx_fp16));
        },
        .riscv64 => {
            const Feature = std.Target.riscv.Feature;

            features_sub.addFeature(@backingInt(Feature.f));
            features_sub.addFeature(@backingInt(Feature.d));
            features_sub.addFeature(@backingInt(Feature.q));
            features_sub.addFeature(@backingInt(Feature.zfh));
            features_sub.addFeature(@backingInt(Feature.zfhmin));

            features_sub.addFeature(@backingInt(Feature.v));
            features_sub.addFeature(@backingInt(Feature.zve32x));
            features_sub.addFeature(@backingInt(Feature.zve32f));
            features_sub.addFeature(@backingInt(Feature.zve64x));
            features_sub.addFeature(@backingInt(Feature.zve64f));
            features_sub.addFeature(@backingInt(Feature.zve64d));

            features_sub.addFeature(@backingInt(Feature.zvbb));
            features_sub.addFeature(@backingInt(Feature.zvbc));
            features_sub.addFeature(@backingInt(Feature.zvkg));
            features_sub.addFeature(@backingInt(Feature.zvkn));
            features_sub.addFeature(@backingInt(Feature.zvks));
            features_sub.addFeature(@backingInt(Feature.zvkt));
        },
        else => unreachable,
    }

    return features_sub;
}
