// --- dependencies --- //

const std = @import("std");
const builtin = @import("builtin");

// --- imports --- //

const kernel = @import("root");

const acpi = kernel.drivers.acpi;

const impl = switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64/root.zig"),
    else => unreachable,
};

pub const ProcessContext = impl.ProcessContext;
pub const TaskContext = impl.TaskContext;

// -- arch/root.zig -- //

pub fn init(xsdt: *acpi.Xsdt) !void {
    try impl.init(xsdt);
}

pub fn maskInterrupts() void {
    impl.maskInterrupts();
}

pub fn unmaskInterrupts() void {
    impl.unmaskInterrupts();
}

pub fn storeContext(
    arch_data: *anyopaque,
    process_ctx: ?*kernel.arch.ProcessContext,
    task_ctx: ?*kernel.arch.TaskContext,
) void {
    impl.storeContext(arch_data, process_ctx, task_ctx);
}

pub fn loadContext(
    arch_data: *anyopaque,
    process_ctx: ?*kernel.arch.ProcessContext,
    task_ctx: ?*kernel.arch.TaskContext,
) void {
    impl.loadContext(arch_data, process_ctx, task_ctx);
}
