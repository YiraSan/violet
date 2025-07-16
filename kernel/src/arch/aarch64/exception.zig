// --- imports --- //

const std = @import("std");
const log = std.log.scoped(.exception);

const kernel = @import("root");
const cpu = kernel.cpu;
const mem = kernel.mem;
const phys = mem.phys;

const gic_v2 = @import("gic_v2.zig");
const timer = @import("timer.zig");
const regs = @import("regs.zig");

// --- exception.s --- //

extern fn set_vbar_el1(addr: u64) callconv(.{ .aarch64_aapcs = .{} }) void;
extern fn set_sp_el1(addr: u64) callconv(.{ .aarch64_aapcs = .{} }) void;
extern fn set_sp_el0(addr: u64) callconv(.{ .aarch64_aapcs = .{} }) void;

extern const exception_vector_table: [2048]u8;

// --- exception.zig --- //

const sp_el1_stack_size = 0x1000 * 64;
const sp_el1_stack: [sp_el1_stack_size]u8 align(0x1000) linksection(".bss") = undefined;

pub fn init() void {
    set_sp_el1(@intFromPtr(&sp_el1_stack) + sp_el1_stack_size);
    set_vbar_el1(@intFromPtr(&exception_vector_table));
}

// --- exception handlers --- //

const ExceptionContext = extern struct {
    lr: u64,
    _: u64 = 0, // padding
    xregs: [30]u64,
    vregs: [32]u128,
    fpcr: u64,
    fpsr: u64,
    elr_el1: u64,
    spsr_el1: regs.SPSR_EL1,
};

fn sync_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    const esr_el1 = regs.ESR_EL1.load();

    switch (esr_el1.ec) {
        .brk_aarch64 => {
            log.info("BREAKPOINT from {s} at address 0x{x} with immediate value {}", .{ @tagName(ctx.spsr_el1.mode), ctx.elr_el1, esr_el1.iss });
            ctx.elr_el1 += 4;
            return;
        },
        .svc_inst_aarch64 => {
            switch (ctx.spsr_el1.mode) {
                .el0t => {
                    std.log.info("hello world!", .{});
                },
                else => {
                    const task: *kernel.process.Task = @ptrFromInt(ctx.xregs[0]);

                    ctx.lr = task.context.lr;
                    ctx.xregs = task.context.xregs;
                    ctx.vregs = task.context.vregs;
                    ctx.fpcr = task.context.fpcr;
                    ctx.fpsr = task.context.fpsr;
                    ctx.elr_el1 = task.context.elr_el1;
                    ctx.spsr_el1 = task.context.spsr_el1;

                    asm volatile (
                        \\ mov x0, %[val]
                        \\ msr tpidr_el1, x0
                        :
                        : [val] "r" (task.context.tpidr_el1),
                        : "x0", "memory"
                    );

                    asm volatile (
                        \\ mov x0, %[val]
                        \\ msr tpidrro_el0, x0
                        :
                        : [val] "r" (task.context.tpidrro_el0),
                        : "x0", "memory"
                    );

                    asm volatile (
                        \\ mov x0, %[val]
                        \\ msr ttbr0_el1, x0
                        :
                        : [val] "r" (task.thread.process.address_space.root_table_phys),
                        : "x0", "memory"
                    );

                    mem.virt.flush_all();

                    set_sp_el0(task.context.sp_el0);

                    return;
                },
            }
        },
        else => {
            log.err("UNEXPECTED SYNCHRONOUS EXCEPTION from {s}", .{@tagName(ctx.spsr_el1.mode)});
            esr_el1.dump();
        },
    }

    cpu.hcf();
}

fn irq_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    // Read the interrupt ID from the GICC interface (acknowledge)
    const irq_id = gic_v2.mmio_read(u32, gic_v2.gicc_base + gic_v2.GICC_IAR_OFFSET);

    switch (irq_id) {
        30 => { // generic timer
            log.info("Generic timer IRQ received from {s}", .{@tagName(ctx.spsr_el1.mode)});
            timer.ack();
        },
        1023 => {
            // 0x3FF = spurious interrupt (no valid IRQ pending)
            log.warn("Spurious IRQ received (no valid source)", .{});
        },
        else => {
            log.warn("Unhandled IRQ ID: {}", .{irq_id});
        },
    }

    // Signal End Of Interrupt to the GIC
    gic_v2.mmio_write(u32, gic_v2.gicc_base + gic_v2.GICC_EOIR_OFFSET, irq_id);
}

fn fiq_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    log.err("UNEXPECTED FIQ from {s}", .{@tagName(ctx.spsr_el1.mode)});
    regs.ESR_EL1.load().dump();
    cpu.hcf();
}

fn serror_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    log.err("UNEXPECTED SERROR from {s}", .{@tagName(ctx.spsr_el1.mode)});
    regs.ESR_EL1.load().dump();
    cpu.hcf();
}

export const el1t_sync = sync_handler;
export const el1t_irq = irq_handler;
export const el1t_fiq = unexpected_exception;
export const el1t_serror = unexpected_exception;

export const el1h_sync = sync_handler;
export const el1h_irq = irq_handler;
export const el1h_fiq = unexpected_exception;
export const el1h_serror = unexpected_exception;

export const el0_sync = sync_handler;
export const el0_irq = irq_handler;
export const el0_fiq = unexpected_exception;
export const el0_serror = unexpected_exception;

fn unexpected_exception(_: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    log.err("unexpected exception", .{});
    regs.ESR_EL1.load().dump();
    cpu.hcf();
}
