// --- dependencies --- //

const std = @import("std");
const basalt = @import("basalt");

// --- imports --- //

const kernel = @import("root");

const generic_timer = @import("../arch/aarch64/generic_timer.zig");

// --- drivers/timer.zig --- //

pub var selected_timer: enum { unselected, generic_timer } = .unselected;

pub var callback: ?*const fn (ctx: *kernel.arch.ExceptionContext) callconv(basalt.task.call_conv) void = null;

pub fn arm(delay: basalt.timer.Delay) void {
    switch (selected_timer) {
        .generic_timer => generic_timer.arm(delay),
        else => unreachable,
    }
}

pub fn cancel() void {
    switch (selected_timer) {
        .generic_timer => generic_timer.disable(),
        else => unreachable,
    }
}
