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

const Arch = std.Target.Cpu.Arch;

pub const GenericTier = enum {
    v1,
    v2,
    v3,
    v4,

    pub fn getCpuModel(self: GenericTier, arch: Arch) *const std.Target.Cpu.Model {
        return switch (arch) {
            .x86_64 => switch (self) {
                .v1 => &std.Target.x86.cpu.x86_64,
                .v2 => &std.Target.x86.cpu.x86_64_v2,
                .v3 => &std.Target.x86.cpu.x86_64_v3,
                .v4 => &std.Target.x86.cpu.x86_64_v4,
            },
            else => std.Target.Cpu.Model.generic(arch),
        };
    }
};

pub fn build(b: *std.Build) void {
    const is_module = b.option(bool, "is_module", "is_module") orelse false;

    const basalt_mod = b.addModule("basalt", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const build_options = b.addOptions();
    build_options.addOption(bool, "is_module", is_module);
    basalt_mod.addImport("build_options", build_options.createModule());
}
