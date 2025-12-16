// Copyright (c) 2024-2025 The violetOS authors
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

// --- imports --- //

const basalt = @import("basalt");

const syscall = basalt.syscall;
const time = basalt.time;

// --- task/root.zig --- //

pub const call_conv: std.builtin.CallingConvention = switch (builtin.cpu.arch) {
    .aarch64 => .{ .aarch64_aapcs = .{} },
    .riscv64 => .{ .riscv64_lp64 = .{} },
    else => unreachable,
};

pub const Quantum = enum(u8) {
    /// 1ms
    ultra_light = 0x0,
    /// 5ms
    light = 0x1,
    /// 10ms
    moderate = 0x2,
    /// 50ms
    heavy = 0x3,
    /// 100ms
    ultra_heavy = 0x4,

    pub fn toDelay(self: @This()) time.Delay {
        return switch (self) {
            .ultra_light => ._1ms,
            .light => ._5ms,
            .moderate => ._10ms,
            .heavy => ._50ms,
            .ultra_heavy => ._100ms,
        };
    }
};

pub const Priority = enum(u8) {
    background = 0x0,
    normal = 0x1,
    reactive = 0x2,
    realtime = 0x3,

    pub fn minResolution(self: Priority) u64 {
        return switch (self) {
            .background => 20 * std.time.ns_per_ms,
            .normal => 5 * std.time.ns_per_ms,
            .reactive => 1 * std.time.ns_per_ms,
            .realtime => 500 * std.time.ns_per_us,
        };
    }
};

pub fn id() u64 {
    return syscall.KernelLocals.get().task_id;
}

pub const sleep = time.sleep;

/// Yield current task and switch to another task.
pub fn yield() void {
    _ = syscall.syscall0(.task_yield) catch {};
}

/// Terminate current task.
pub fn terminate() noreturn {
    _ = syscall.syscall0(.task_terminate) catch {};
    unreachable;
}
