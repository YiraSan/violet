// --- dependencies --- //

const std = @import("std");
const ark = @import("ark");

// --- imports --- //

const kernel = @import("root");

const acpi = kernel.drivers.acpi;

const exception = @import("exception.zig");
const gic = @import("gic.zig");
const generic_timer = @import("generic_timer.zig");

// --- aarch64/root.zig --- //

pub fn init(xsdt: *acpi.Xsdt) !void {
    try exception.init();
    try gic.init(xsdt);
    try generic_timer.init(xsdt);
}

pub fn maskInterrupts() void {
    asm volatile (
        \\ msr daifset, #0b1111
        \\ isb
    );
}

pub fn unmaskInterrupts() void {
    asm volatile (
        \\ msr daifclr, #0b1111
        \\ isb
    );
}

pub const ProcessContext = struct {};

pub const TaskContext = struct {
    // operational registers
    lr: u64,
    xregs: [30]u64,
    vregs: [32]u128,
    fpcr: u64,
    fpsr: u64,
    elr_el1: u64,
    spsr_el1: ark.cpu.armv8a_64.registers.SPSR_EL1,
    sp: u64,
};

pub fn save_context(
    arch_data: *anyopaque,
    process_ctx: ?*kernel.arch.ProcessContext,
    task_ctx: ?*kernel.arch.TaskContext,
) void {
    const exception_ctx: *exception.ExceptionContext = @ptrCast(@alignCast(arch_data));

    if (process_ctx) |process| {
        _ = process;
    }

    if (task_ctx) |task| {
        task.lr = exception_ctx.lr;
        task.xregs = exception_ctx.xregs;
        task.vregs = exception_ctx.vregs;
        task.fpcr = exception_ctx.fpcr;
        task.fpsr = exception_ctx.fpsr;
        task.elr_el1 = exception_ctx.elr_el1;
        task.spsr_el1 = exception_ctx.spsr_el1;

        task.sp = exception.get_sp_el0();
    }
}

pub fn load_context(
    arch_data: *anyopaque,
    process_ctx: ?*kernel.arch.ProcessContext,
    task_ctx: ?*kernel.arch.TaskContext,
) void {
    const exception_ctx: *exception.ExceptionContext = @ptrCast(@alignCast(arch_data));

    if (process_ctx) |process| {
        _ = process;
    }

    if (task_ctx) |task| {
        exception_ctx.lr = task.lr;
        exception_ctx.xregs = task.xregs;
        exception_ctx.vregs = task.vregs;
        exception_ctx.fpcr = task.fpcr;
        exception_ctx.fpsr = task.fpsr;
        exception_ctx.elr_el1 = task.elr_el1;
        exception_ctx.spsr_el1 = task.spsr_el1;

        exception.set_sp_el0(task.sp);
    }
}
