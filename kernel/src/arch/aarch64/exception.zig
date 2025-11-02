// --- dependencies --- //

const std = @import("std");
const ark = @import("ark");

const log = std.log.scoped(.exception);

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const phys = mem.phys;

// --- aarch64/exception.zig --- //

pub fn init() !void {
    const sp_el1_stack = kernel.hhdm_base + (phys.alloc_page(.l4K, false) catch unreachable);
    const sp_el1_stack_size = 0x1000;

    set_sp_el1(sp_el1_stack + sp_el1_stack_size);
    set_vbar_el1(@intFromPtr(&exception_vector_table));
}

// --- old --- //

extern fn set_vbar_el1(addr: u64) callconv(.{ .aarch64_aapcs = .{} }) void;

pub extern fn set_sp_el1(addr: u64) callconv(.{ .aarch64_aapcs = .{} }) void;
pub extern fn set_sp_el0(addr: u64) callconv(.{ .aarch64_aapcs = .{} }) void;

pub extern fn get_sp_el0() callconv(.{ .aarch64_aapcs = .{} }) u64;

extern const exception_vector_table: [2048]u8 linksection(".bss");

pub const ExceptionContext = extern struct {
    lr: u64,
    _: u64 = 0, // padding
    xregs: [30]u64,
    vregs: [32]u128,
    fpcr: u64,
    fpsr: u64,
    elr_el1: u64,
    spsr_el1: ark.cpu.armv8a_64.registers.SPSR_EL1,
};

var first_entry = true;

// TODO dissociate sync_handler depending on EL0/EL1t/EL1h later
fn sync_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    const esr_el1 = ark.cpu.armv8a_64.registers.ESR_EL1.get();

    switch (esr_el1.ec) {
        .data_abort_lower_el, .data_abort_same_el => {
            const far = ark.cpu.armv8a_64.registers.FAR_EL1.get().address;
            const iss = esr_el1.iss.data_abort;

            log.debug("DataAbort({s}) from {s} on 0x{x}", .{ @tagName(iss.dfsc), @tagName(ctx.spsr_el1.mode), far });

            switch (iss.dfsc) {
                .access_flag_lv1, .access_flag_lv2, .access_flag_lv3 => {
                    // TODO it might be nice to not consider lowerEL same as sameEL
                    if (far < 0xffff_8000_0000_0000) {
                        @panic("access flag abort in userspace memory");
                    } else {
                        var mapping = mem.virt.kernel_space.getPage(far) orelse {
                            @panic("this is literally impossible.");
                        };

                        mapping.tocommit_heap = false;
                        mapping.phys_addr = phys.alloc_page(mapping.level, true) catch @panic("no more memory uhh");

                        mem.virt.kernel_space.setPage(far, mapping) orelse {
                            @panic("uhhh ???");
                        };

                        mem.virt.flush(far);
                    }

                    // no needs to increment elr_el1 since the faulted instruction needs to be executed again.
                    return;
                },
                else => {
                    @panic("unimplemented data abort exception");
                },
            }
        },
        .brk_aarch64 => {
            const iss = esr_el1.iss.brk_aarch64;

            log.debug("Breakpoint({}) from {s} at address 0x{x}", .{ iss.comment, @tagName(ctx.spsr_el1.mode), ctx.elr_el1 });

            ctx.elr_el1 += 4;
            return;
        },
        .svc_inst_aarch64 => {
            const iss = esr_el1.iss.svc_hvc;

            switch (iss.imm16) {
                // SYSCALL:TERMINATE_PROCESS
                0 => if (first_entry) {
                    first_entry = false;
                    kernel.scheduler.firstEntry(ctx);
                    return;
                } else {
                    kernel.scheduler.terminateProcess(ctx);
                    return;
                },
                // SYSCALL:TERMINATE_TASK
                1 => {
                    kernel.scheduler.terminateTask(ctx);
                    return;
                },
                // SYSCALL:YIELD_TASK
                2 => {
                    kernel.scheduler.switchTask(ctx);
                    return;
                },
                else => {
                    // TODO specifiy how are returned syscall errors.
                    @panic("bad syscall id");
                },
            }
        },
        else => {
            log.err("UNEXPECTED SYNCHRONOUS EXCEPTION from {s}", .{@tagName(ctx.spsr_el1.mode)});
            esr_el1.dump();
        },
    }

    ark.cpu.halt();
}

const gic = @import("gic.zig");

pub const IrqCallback = *const fn (ctx: *ExceptionContext) void;
pub var irq_callbacks: [1024]?IrqCallback linksection(".bss") = undefined;

fn irq_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    const irq_id = gic.acknowledge();

    if (irq_id >= 1023) {
        log.warn("Spurious IRQ received (no valid source)", .{});
    } else if (irq_callbacks[irq_id]) |callback| {
        callback(ctx);
    } else {
        log.warn("Unhandled IRQ ID: {}", .{irq_id});
    }

    gic.endOfInterrupt(irq_id);
}

fn fiq_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    log.err("UNEXPECTED FIQ from {s}", .{@tagName(ctx.spsr_el1.mode)});
    ark.cpu.armv8a_64.registers.ESR_EL1.get().dump();
    ark.cpu.halt();
}

fn serror_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    log.err("UNEXPECTED SERROR from {s}", .{@tagName(ctx.spsr_el1.mode)});
    ark.cpu.armv8a_64.registers.ESR_EL1.get().dump();
    ark.cpu.halt();
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
    ark.cpu.armv8a_64.registers.ESR_EL1.get().dump();
    ark.cpu.halt();
}
