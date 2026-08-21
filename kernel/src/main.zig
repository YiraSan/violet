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

// --- imports --- //

pub const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("arch/aarch64/root.zig"),
    .riscv64 => @import("arch/riscv64/root.zig"),
    .x86_64 => @import("arch/x86_64/root.zig"),
    else => @compileError("Unsupported architecture."),
};

pub const boot = @import("boot/root.zig");
pub const mem = @import("mem/root.zig");

// --- main.zig --- //

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = message;
    _ = stack_trace;
    _ = return_address;

    arch.cpu.halt();
}

pub fn logFn(comptime message_level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    const scope_prefix = if (scope == .default) "" else ":" ++ @tagName(scope);
    const prefix = "\x1b[35m[kernel" ++ scope_prefix ++ "] " ++ switch (message_level) {
        .err => "\x1b[31merror",
        .warn => "\x1b[33mwarn",
        .info => "\x1b[36minfo",
        .debug => "\x1b[90mdebug",
    } ++ ": \x1b[0m";

    _ = prefix;
    _ = format;
    _ = args;
}

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

comptime {
    _ = arch;
    _ = boot;
    _ = mem;
}
