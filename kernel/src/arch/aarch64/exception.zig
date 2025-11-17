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
    const sp_el1_stack = kernel.boot.hhdm_base + (phys.allocPage(.l4K, false) catch unreachable);
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
    spsr_el1: ark.armv8.registers.SPSR_EL1,
};

var first_entry = true;

// TODO dissociate sync_handler depending on EL0/EL1t/EL1h later
fn sync_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    kernel.arch.maskInterrupts();

    const esr_el1 = ark.armv8.registers.ESR_EL1.load();
    const cpu = kernel.arch.Cpu.get();

    switch (esr_el1.ec) {
        .data_abort_lower_el, .data_abort_same_el => {
            const far = ark.armv8.registers.loadFarEl1();
            const iss = esr_el1.iss.data_abort;

            if (iss.dfsc != .access_flag_lv1 and
                iss.dfsc != .access_flag_lv2 and
                iss.dfsc != .access_flag_lv3)
            {
                log.debug("DataAbort({s}) from {s} on 0x{x}", .{ @tagName(iss.dfsc), @tagName(ctx.spsr_el1.mode), far });
            }

            switch (iss.dfsc) {
                .access_flag_lv1, .access_flag_lv2, .access_flag_lv3 => {
                    const virt_space = if (far < 0xffff_8000_0000_0000) cpu.user_space else &mem.virt.kernel_space;

                    var mapping = virt_space.getPage(far) orelse unreachable;

                    switch (mapping.hint) {
                        .no_hint => unreachable,
                        .heap_begin, .heap_inbetween, .heap_end, .heap_single, .heap_begin_stack, .heap_stack => {
                            mapping.phys_addr = phys.allocPage(mapping.level, true) catch {
                                @panic("out of memory exception");
                            };
                            virt_space.setPage(far, mapping) orelse unreachable;
                            mem.virt.flush(far, .l4K);
                        },
                        .stack_begin_guard_page, .stack_end_guard_page => {
                            @panic("stack overflow exception");
                        },
                    }

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
                0 => {
                    _ = kernel.scheduler.terminateProcess(ctx);
                    return;
                },
                1 => {
                    _ = kernel.scheduler.terminateTask(ctx);
                    return;
                },
                else => {
                    // TODO specify how are returned syscall errors.
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
    kernel.arch.maskInterrupts();

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
    ark.armv8.registers.ESR_EL1.load().dump();
    ark.cpu.halt();
}

comptime {
    _ = el1t_sync;
    _ = el1t_irq;
    _ = el1t_fiq;
    _ = el1t_serror;

    _ = el1h_sync;
    _ = el1h_irq;
    _ = el1h_fiq;
    _ = el1h_serror;

    _ = el0_sync;
    _ = el0_irq;
    _ = el0_fiq;
    _ = el0_serror;
}
