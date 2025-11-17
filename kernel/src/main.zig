// --- dependencies --- //

const ark = @import("ark");
const build_options = @import("build_options");
const builtin = @import("builtin");
const std = @import("std");

// --- imports --- //

pub const arch = @import("arch/root.zig");
pub const boot = @import("boot/root.zig");
pub const drivers = @import("drivers/root.zig");
pub const mem = @import("mem/root.zig");
pub const scheduler = @import("scheduler/root.zig");

comptime {
    _ = arch;
    _ = boot;
    _ = drivers;
    _ = mem;
    _ = scheduler;
}

// --- main.zig --- //

pub fn stage0() !void {
    try mem.phys.init();

    try arch.initCpus(boot.xsdt);
    try mem.phys.initCpu();

    try mem.virt.init();

    try drivers.serial.init(boot.xsdt);
}

pub fn stage1() !void {
    std.log.info("current version is {s}", .{build_options.version});

    try arch.init(boot.xsdt);
    try scheduler.init();

    // TODO implement SMP on rpi4
    if (build_options.platform != .rpi4) try arch.bootCpus();
}

pub fn stage2() !void {
    try drivers.pcie.init(boot.xsdt);

    const process = try scheduler.Process.create(.{
        .execution_level = .kernel,
    });

    const task0 = try process.createTask(.{ .entry_point = &_task0 });
    const task1 = try process.createTask(.{ .entry_point = &_task1 });

    try scheduler.registerTask(task0);
    try scheduler.registerTask(task1);

    // jump to scheduler
    arch.unmaskInterrupts();
    drivers.Timer.arm(._5ms);
}

fn _task0(_: *[0x1000]u8) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    asm volatile ("brk #0");

    std.log.info("hello from task 0 !", .{});

    // terminate task.
    asm volatile ("svc #1");
    unreachable;
}

fn _task1(_: *[0x1000]u8) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    asm volatile ("brk #1");

    std.log.info("hello from task 1 !", .{});

    // terminate task.
    asm volatile ("svc #1");
    unreachable;
}

// --- zig std features --- //

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = return_address;
    std.log.err("panic: {s}", .{message});

    // NOTE little panic handler
    const cpu = arch.Cpu.get();
    if (cpu.current_task) |task| {
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
