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

// --- dependencies --- //

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

// --- exports --- //

pub const call = @import("call.zig");

pub const Process = @import("Process.zig");
pub const Task = @import("Task.zig");

pub const call_conv: std.builtin.CallingConvention = switch (builtin.cpu.arch) {
    .aarch64 => .{ .aarch64_aapcs = .{} },
    .riscv64 => .{ .riscv64_lp64 = .{} },
    // The kernel don't and will never support the redzone. So it has to be disabled.
    .x86_64 => .{ .x86_64_sysv = .{} },
    else => unreachable,
};

pub const is_module = build_options.is_module;
