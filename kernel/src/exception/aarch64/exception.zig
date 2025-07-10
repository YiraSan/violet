// --- imports --- //

const std = @import("std");
const log = std.log.scoped(.exception);

const kernel = @import("root");
const cpu = kernel.cpu;
const mem = kernel.mem;
const phys = mem.phys;

// --- exception.s --- //

extern fn set_vbar_el1(addr: u64) callconv(.{ .aarch64_aapcs = .{} }) void;
extern fn set_sp_el1(addr: u64) callconv(.{ .aarch64_aapcs = .{} }) void;

extern const exception_vector_table: [2048]u8;

// --- exception.zig --- //

pub fn init() void {
    // TODO alloc 64 KiB instead of 4 KiB
    const page_addr = phys.alloc_page(.l4K) catch @panic("failed to allocate SP_EL1 page");
    set_sp_el1(mem.hhdm_offset + page_addr + phys.PageLevel.l4K.size() - 16 * 2);

    set_vbar_el1(@intFromPtr(&exception_vector_table));

    // unmask all exceptions
    asm volatile ("msr DAIFClr, #0b1111");
}

// --- exception handlers --- //

const ExceptionContext = struct {
    registers: [30]u64,
    elr_el1: u64,
    spsr_el1: u64,
    lr: u64,
};

export fn el1t_sync(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    const esr_el1 = ESR_EL1.load();

    switch (esr_el1.ec) {
        .brk_aarch64 => {
            log.info("BREAKPOINT EL1T_SYNC at address 0x{x} with immediate value {}", .{ ctx.elr_el1, esr_el1.iss });
            ctx.elr_el1 += 4;
            return;
        },
        else => {
            log.err("UNEXPECTED EL1T_SYNC", .{});
            esr_el1.dump();
        },
    }

    cpu.hcf();
}

export const el1t_irq = unexpected_exception;
export const el1t_fiq = unexpected_exception;
export const el1t_serror = unexpected_exception;

export const el1h_sync = unexpected_exception;
export const el1h_irq = unexpected_exception;
export const el1h_fiq = unexpected_exception;
export const el1h_serror = unexpected_exception;

export const el0_sync = unexpected_exception;
export const el0_irq = unexpected_exception;
export const el0_fiq = unexpected_exception;
export const el0_serror = unexpected_exception;

fn unexpected_exception(_: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    log.err("unexpected exception", .{});
    ESR_EL1.load().dump();
    cpu.hcf();
}

// --- structs --- //

const ESR_EL1 = packed struct(u64) {
    iss: u25, // bits 0-24
    il: enum(u1) { // bit 25
        b16,
        b32,
    },
    ec: enum(u6) { // bits 26-31
        unknown_reason = 0b000000,
        trapped_wfi_wfe = 0b000001,
        trapped_mcr_mrc_cp15 = 0b000011,
        trapped_mcrr_mrrc_cp15 = 0b000100,
        trapped_mcr_mrc_cp14 = 0b000101,
        trapped_ldc_stc = 0b000110,
        trapped_sme_sve_simd_fp = 0b000111,
        trapped_ptr_auth = 0b001001,
        trapped_uncovered = 0b001010,
        trapped_mrrc_cp14 = 0b001100,
        branch_target_exception = 0b001101,
        illegal_execution = 0b001110,
        svc_inst_aarch32 = 0b010001,
        trapped_msrr_mrrs_sys_uncovered_aarch64 = 0b010100,
        svc_inst_aarch64 = 0b010101,
        trapped_msr_mrs_sys_uncovered_aarch64 = 0b011000,
        trapped_sve = 0b011001,
        trapped_eret_erteaa_erteab = 0b011010,
        trapped_tstart = 0b011011,
        pac_fail = 0b011100,
        trapped_sme = 0b011101,
        inst_abort_lower_el = 0b100000,
        inst_abort_same_el = 0b100001,
        pc_align_fault = 0b100010,
        data_abort_lower_el = 0b100100,
        data_abort_same_el = 0b100101,
        sp_align_fault = 0b100110,
        mem_op = 0b100111,
        trapped_fp_aarch32 = 0b101000,
        trapped_fp_aarch64 = 0b101100,
        gcs = 0b101101,
        serror = 0b101111,
        breakpoint_lower_el = 0b110000,
        breakpoint_same_el = 0b110001,
        software_step_lower_el = 0b110010,
        software_step_same_el = 0b110011,
        watchpoint_lower_el = 0b110100,
        watchpoint_same_el = 0b110101,
        bkpt_aarch32 = 0b111000,
        brk_aarch64 = 0b111100,
        profiling = 0b111101,
    },
    _reserved: u32, // bit 32-63

    pub fn load() ESR_EL1 {
        const esr_el1: u64 = asm volatile (
            \\ mrs %[result], esr_el1
            : [result] "=r" (-> u64),
        );
        return @bitCast(esr_el1);
    }

    pub fn dump(self: @This()) void {
        log.info(
            \\ 
            \\ -------- ESR_EL1 --------
            \\
            \\ iss {}
            \\ il {s}
            \\ ec {s}
            \\
            \\ -------------------------
        , .{
            self.iss,
            @tagName(self.il),
            @tagName(self.ec),
        });
    }
};

const DAIF = packed struct(u64) {
    _reserved1: u6 = 0, // bits 0..5 (non utilisés ici)
    fiq_mask: bool, // bit 6  (F)
    irq_mask: bool, // bit 7  (I)
    serror_mask: bool, // bit 8  (A)
    debug_mask: bool, // bit 9  (D)
    _reserved2: u54 = 0, // bits 10..63

    pub fn load() @This() {
        const daif: u64 = asm volatile (
            \\ mrs %[result], daif
            : [result] "=r" (-> u64),
        );
        return @bitCast(daif);
    }

    pub fn store(self: @This()) void {
        asm volatile (
            \\ msr daif, %[input]
            :
            : [input] "r" (@as(u64, @bitCast(self))),
            : "memory"
        );
    }
};
