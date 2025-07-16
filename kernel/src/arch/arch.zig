// --- imports --- //

const std = @import("std");
const builtin = @import("builtin");

const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64/arch.zig"),
    .x86_64 => @import("x86_64/arch.zig"),
    else => unreachable,
};

pub fn init() void {
    arch.init();
}

pub const ThreadContext = arch.ThreadContext;
pub const TaskContext = arch.TaskContext;
