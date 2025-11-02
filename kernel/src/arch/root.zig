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

pub fn mask_interrupts() void {
    impl.mask_interrupts();
}

pub fn unmask_interrupts() void {
    impl.unmask_interrupts();
}

pub fn save_context(
    arch_data: *anyopaque,
    process_ctx: ?*kernel.arch.ProcessContext,
    task_ctx: ?*kernel.arch.TaskContext,
) void {
    impl.save_context(arch_data, process_ctx, task_ctx);
}

pub fn load_context(
    arch_data: *anyopaque,
    process_ctx: ?*kernel.arch.ProcessContext,
    task_ctx: ?*kernel.arch.TaskContext,
) void {
    impl.load_context(arch_data, process_ctx, task_ctx);
}
