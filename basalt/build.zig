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

pub fn build(b: *std.Build) void {
    const is_module = b.option(bool, "is_module", "is_module") orelse false;

    const basalt_mod = b.addModule("basalt", .{
        .root_source_file = b.path("src/root.zig"),
    });

    basalt_mod.addImport("basalt", basalt_mod);

    const build_options = b.addOptions();
    build_options.addOption(bool, "is_module", is_module);
    basalt_mod.addImport("build_options", build_options.createModule());
}

pub const ExecutableOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    arch: std.Target.Cpu.Arch,
    optimize: std.builtin.OptimizeMode = .Debug,
    is_module: bool = false,
};

pub fn addExecutable(b: *std.Build, options: ExecutableOptions) *std.Build.Step.Compile {
    const target_query = std.Target.Query{
        .cpu_arch = options.arch,
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
        .cpu_model = switch (options.arch) {
            .x86_64 => &std.Target.x86.cpu.x86_64_v2,
            else => std.Target.Cpu.Model.baseline(options.arch, .{ .tag = .freestanding, .version_range = .{ .none = {} } }),
        },
    };
    const target = b.resolveTargetQuery(target_query);

    const basalt = b.dependency("basalt", .{ .is_module = options.is_module });
    const basalt_mod = basalt.module("basalt");

    const user_mod = b.createModule(.{
        .root_source_file = options.root_source_file,
        .imports = &.{
            .{ .name = "basalt", .module = basalt_mod },
        },
    });

    const wrapper_mod = b.createModule(.{
        .root_source_file = basalt.path("src/main.zig"),
        .imports = &.{
            .{ .name = "basalt", .module = basalt_mod },
            .{ .name = "user", .module = user_mod },
        },

        .target = target,
        .optimize = options.optimize,

        .link_libc = false,
        .link_libcpp = false,
        .omit_frame_pointer = false,
        .pic = options.is_module,
        .red_zone = false,
        .stack_check = true,
        .stack_protector = true,
    });

    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = wrapper_mod,
        .use_llvm = true,
        .use_lld = true,
    });

    exe.entry = .disabled;
    exe.lto = .none;
    exe.pie = options.is_module;
    exe.bundle_compiler_rt = true;
    exe.out_filename = b.fmt("{s}.elf", .{options.name});
    exe.link_z_max_page_size = if (options.arch == .aarch64) 64 * 1024 else 4 * 1024;

    if (options.is_module) {
        exe.pie = true;
        exe.setLinkerScript(basalt.path("linker-scripts/module.lds"));
    } else {
        exe.setLinkerScript(basalt.path("linker-scripts/userland.lds"));
    }

    return exe;
}
