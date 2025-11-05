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
pub const Cpu = impl.Cpu;

// -- arch/root.zig -- //

pub fn init(xsdt: *acpi.Xsdt) !void {
    try impl.init(xsdt);
}

pub fn initCpus(xsdt: *acpi.Xsdt) !void {
    try impl.initCpus(xsdt);
}

pub fn bootCpus() !void {
    try impl.bootCpus();
}

pub fn maskInterrupts() void {
    impl.maskInterrupts();
}

pub fn unmaskInterrupts() void {
    impl.unmaskInterrupts();
}

// TODO implements those inside Process and Task.

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
