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

pub fn build(b: *std.Build) void {
    const module_mode = b.option(bool, "module_mode", "kernel module mode") orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("basalt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption(bool, "module_mode", module_mode);
    mod.addImport("build_options", build_options.createModule());

    mod.addImport("basalt", mod);

    const ark_dep = b.dependency("ark", .{
        .target = target,
        .optimize = optimize,
    });
    const ark_mod = ark_dep.module("ark");
    mod.addImport("ark", ark_mod);

    const main_mod = b.addModule("basalt_main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    main_mod.addImport("basalt", mod);
}

pub fn addExecutable(b: *std.Build, options: ExecutableOptions) *std.Build.Step.Compile {
    const target_query = std.Target.Query{
        .cpu_arch = options.platform.arch(),
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
    };

    const target = b.resolveTargetQuery(target_query);

    const basalt = b.dependency("basalt", .{
        .target = target,
        .optimize = options.optimize,
        .module_mode = options.kernel_module,
    });
    const basalt_mod = basalt.module("basalt");
    const basalt_main_mod = basalt.module("basalt_main");

    if (options.kernel_module) {
        basalt_main_mod.pic = true;
    }

    const mod = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = target,
        .optimize = options.optimize,
        .pic = options.kernel_module,
    });

    mod.addImport("basalt", basalt_mod);
    basalt_main_mod.addImport("mod", mod);

    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = basalt_main_mod,
        .use_llvm = true,
    });

    exe.entry = .disabled;

    // TODO works only with 0.15+
    // exe.out_filename = b.fmt("{s}.elf", .{options.name});

    exe.setLinkerScript(basalt.path("linker.lds"));

    return exe;
}

pub const ExecutableOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    platform: Platform,
    optimize: std.builtin.OptimizeMode = .Debug,
    kernel_module: bool = false,
};

pub const Platform = enum {
    aarch64_qemu,
    riscv64_qemu,

    rpi4,
    rpi3,

    pub fn arch(self: Platform) std.Target.Cpu.Arch {
        return switch (self) {
            .aarch64_qemu, .rpi4, .rpi3 => .aarch64,
            .riscv64_qemu => .riscv64,
        };
    }

    pub fn cpuModel(self: Platform) *const std.Target.Cpu.Model {
        return switch (self) {
            .rpi4, .aarch64_qemu => &std.Target.aarch64.cpu.cortex_a72,
            .rpi3 => &std.Target.aarch64.cpu.cortex_a53,
            else => std.Target.Cpu.Model.generic(self.arch()),
        };
    }
};
