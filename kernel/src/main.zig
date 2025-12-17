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
pub const scheduler = @import("scheduler/root.zig");
pub const syscall = @import("syscall/root.zig");

// --- main.zig --- //

pub fn stage0() !void {
    try mem.phys.init();

    try arch.initCpus();
    try mem.phys.initCpu();

    try mem.vmm.init();

    try drivers.serial.init();
}

pub fn stage1() !void {
    std.log.info("current version is {s}", .{build_options.version});

    try arch.init();
    try syscall.init();
    try scheduler.init();
    try mem.syscalls.init();
    try drivers.Timer.init();
    try drivers.Timer.initCpu();

    // scheduler tests
    if (builtin.mode == .Debug or true) {
        const test_process_id = try scheduler.Process.create(.{
            .execution_level = .module,
        });

        const task0 = try scheduler.Task.create(test_process_id, .{
            .entry_point = @intFromPtr(&task0_entry),
        });
        try scheduler.register(task0);

        const task1 = try scheduler.Task.create(test_process_id, .{
            .entry_point = @intFromPtr(&task1_entry),
        });
        try scheduler.register(task1);

        const task2 = try scheduler.Task.create(test_process_id, .{
            .entry_point = @intFromPtr(&task2_entry),
        });
        try scheduler.register(task2);

        const task3 = try scheduler.Task.create(test_process_id, .{
            .entry_point = @intFromPtr(&task3_entry),
        });
        try scheduler.register(task3);
    }
}

pub fn stage2() !void {
    try drivers.init();

    try arch.bootCpus();

    // jump to scheduler
    arch.unmaskInterrupts();
    drivers.Timer.arm(1 * std.time.ns_per_ms);
}

const task0_log = std.log.scoped(.task0);

fn task0_entry(_: basalt.sync.Facet, _: *const basalt.module.KernelIndirectionTable) callconv(basalt.task.call_conv) noreturn {
    task0_main() catch |err| {
        task0_log.err("terminated with: {}", .{err});
    };

    basalt.task.terminate();
}

fn task0_main() !void {
    @breakpoint();

    task0_log.info("hello world !", .{});

    var debug_allocator: std.heap.DebugAllocator(.{ .thread_safe = false }) = .init;
    defer _ = debug_allocator.deinit();

    const allocator = debug_allocator.allocator();

    var list: std.ArrayList(u64) = .init(allocator);
    defer list.deinit();

    try list.append(790);
    try list.append(10000);
    try list.append(12000);
    try list.append(1);

    for (list.items) |item| {
        task0_log.info("{}", .{item});
    }

    task0_log.info("sleeping for 5s...", .{});
    try basalt.task.sleep(._5s);
    task0_log.info("sleep finished !", .{});

    const timer_10s = try basalt.time.SingleTimer.init(._10s);
    const timer_5s = try basalt.time.SingleTimer.init(._5s);

    var wait_list: basalt.sync.WaitList = .init;

    const timer_10s_index = try timer_10s.addToList(&wait_list);
    const timer_5s_index = try timer_5s.addToList(&wait_list);

    while (try wait_list.wait(.race, .wait)) |result| {
        switch (result) {
            .resolved => |resolved| {
                wait_list.remove(resolved.index);

                if (resolved.index == timer_10s_index) {
                    task0_log.info("timer_10s_index done !", .{});
                } else if (resolved.index == timer_5s_index) {
                    task0_log.info("timer_5s_index done !", .{});
                }
            },
            .canceled, .invalid => |index| {
                task0_log.info("{} failed.", .{index});
            },
            .insolvent => break,
        }
    }

    task0_log.info("wait list done !", .{});
}

const task1_log = std.log.scoped(.task1);

fn task1_entry(_: basalt.sync.Facet, _: *const basalt.module.KernelIndirectionTable) callconv(basalt.task.call_conv) noreturn {
    task1_main() catch |err| {
        task1_log.err("terminated with: {}", .{err});
    };

    basalt.task.terminate();
}

fn task1_main() !void {
    @breakpoint();

    task1_log.info("hello world !", .{});

    var sequential_timer = try basalt.time.SequentialTimer.init(._60hz);
    defer sequential_timer.deinit();

    for (0..5) |_| {
        const delta = try sequential_timer.wait();

        task1_log.info("elapsed ticks since last: {}", .{delta});

        try basalt.task.sleep(._1s);
    }
}

const PING_PONG_ITERATIONS: u64 = 100_000;

const task2_log = std.log.scoped(.task2);

fn task2_entry(_: basalt.sync.Facet, _: *const basalt.module.KernelIndirectionTable) callconv(basalt.task.call_conv) noreturn {
    task2_main() catch |err| {
        task2_log.err("terminated with: {}", .{err});
    };

    basalt.task.terminate();
}

var task2_facet: std.atomic.Value(basalt.sync.Facet) = .init(.null);

fn task2_main() !void {
    task2_log.info("hey there !", .{});

    var prism = try basalt.sync.Prism.create(.{});
    defer prism.destroy();

    const facet = try basalt.sync.Facet.create(prism, basalt.process.id());
    defer facet.drop();

    task2_facet.store(facet, .release);

    while (try prism.consume(.wait)) |invocation| {
        const val = invocation.arg.pair64.arg0 + 1;
        try invocation.future.resolve(val);
        if (val >= PING_PONG_ITERATIONS) break;
    }
}

const task3_log = std.log.scoped(.task3);

fn task3_entry(_: basalt.sync.Facet, _: *const basalt.module.KernelIndirectionTable) callconv(basalt.task.call_conv) noreturn {
    task3_main() catch |err| {
        task3_log.err("terminated with: {}", .{err});
    };

    basalt.task.terminate();
}

fn task3_main() !void {
    task3_log.info("here to benchmark for {} iterations !", .{PING_PONG_ITERATIONS});

    while (task2_facet.load(.acquire).isNull()) {
        std.atomic.spinLoopHint();
    }
    var out_facet: basalt.sync.Facet = task2_facet.load(.acquire);

    const start_time = drivers.Timer.getUptime();

    var counter: u64 = 0;
    while (counter < PING_PONG_ITERATIONS) : (counter += 1) {
        const future = try out_facet.invoke(.{ .pair64 = .{ .arg0 = counter, .arg1 = 0 } }, .wait);

        const result = try future.wait(null, .wait) orelse return task3_log.info("benchmark failed", .{});

        if (result != counter + 1) {
            task3_log.err("missmatch! sent {} got {}", .{ counter, result });
            break;
        }
    }

    const end_time = drivers.Timer.getUptime();

    task3_log.info("benchmark done in {} ns", .{end_time - start_time});
}

// --- zig std features --- //

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    std.log.err("panic(0x{?x}): {s}", .{ return_address, message });

    // NOTE little panic handler
    const local_scheduler = scheduler.Local.get();
    if (local_scheduler.current_task) |_| {
        switch (builtin.cpu.arch) {
            .aarch64 => {
                const spsel = asm volatile (
                    \\ msr spsel, %[out]
                    : [out] "=r" (-> u64),
                );

                if (spsel == 0) {
                    basalt.task.terminate();
                } else {
                    scheduler.task_terminate(undefined) catch {};
                }
            },
            else => unreachable,
        }
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
    .page_size_max = basalt.heap.PAGE_SIZE,
    .page_size_min = basalt.heap.PAGE_SIZE,
};

pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = basalt.heap.page_allocator;
    };
};

// ---- //

comptime {
    _ = arch;
    _ = boot;
    _ = drivers;
    _ = mem;
    _ = scheduler;
    _ = syscall;
}
