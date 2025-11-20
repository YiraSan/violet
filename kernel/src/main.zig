// Copyright (c) 2025 The violetOS authors
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

//! TODO Remove all @panic and unreachable that can be replaced by errors.

// --- dependencies --- //

const ark = @import("ark");
const basalt = @import("basalt");
const build_options = @import("build_options");
const builtin = @import("builtin");
const std = @import("std");

// --- imports --- //

pub const arch = @import("arch/root.zig");
pub const boot = @import("boot/root.zig");
pub const drivers = @import("drivers/root.zig");
pub const mem = @import("mem/root.zig");
pub const prism = @import("prism/root.zig");
pub const scheduler = @import("scheduler/root.zig");
pub const syscall = @import("syscall/root.zig");

comptime {
    _ = arch;
    _ = boot;
    _ = drivers;
    _ = mem;
    _ = prism;
    _ = scheduler;
    _ = syscall;
}

// --- main.zig --- //

pub fn stage0() !void {
    try mem.phys.init();

    try arch.initCpus();
    try mem.phys.initCpu();

    try mem.virt.init();

    try drivers.serial.init();
}

pub fn stage1() !void {
    std.log.info("current version is {s}", .{build_options.version});

    try arch.init();
    try syscall.init();
    try prism.init();
    try prism.initCpu();
    try mem.heap.init();
    try scheduler.init();

    // scheduler tests
    if (builtin.mode == .Debug) {
        const process = try scheduler.Process.create(.{
            .execution_level = .kernel,
        });

        const task0 = try process.createTask(.{ .entry_point = @intFromPtr(&_task0) });
        const task1 = try process.createTask(.{ .entry_point = @intFromPtr(&_task1) });

        try scheduler.register(task0);
        try scheduler.register(task1);
    }
}

pub fn stage2() !void {
    try drivers.init();

    try arch.bootCpus();

    // jump to scheduler
    arch.unmaskInterrupts();
    drivers.Timer.arm(._5ms);
}

fn _task0(_: *[0x1000]u8) callconv(basalt.task.call_conv) noreturn {
    asm volatile ("brk #0");

    std.log.info("hello from task 0 !", .{});

    basalt.task.terminate();
}

fn _task1(_: *[0x1000]u8) callconv(basalt.task.call_conv) noreturn {
    asm volatile ("brk #1");

    std.log.info("hello from task 1 !", .{});

    basalt.task.terminate();
}

// --- zig std features --- //

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = return_address;

    // TODO this could cause a deadlock on serial.
    std.log.err("panic: {s}", .{message});

    // NOTE little panic handler
    const local_scheduler = scheduler.Local.get();
    if (local_scheduler.current_task) |task| {
        task.terminate();
        drivers.Timer.arm(._1ms);
    }

    ark.cpu.halt();
}

pub fn logFn(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    const scope_prefix = if (scope == .default) "" else ":" ++ @tagName(scope);
    const prefix = "\x1b[35m[kernel" ++ scope_prefix ++ "] " ++ switch (level) {
        .err => "\x1b[31merror",
        .warn => "\x1b[33mwarn",
        .info => "\x1b[36minfo",
        .debug => "\x1b[90mdebug",
    } ++ ": \x1b[0m";
    drivers.serial.print(prefix ++ format ++ "\n", args);
}

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};
