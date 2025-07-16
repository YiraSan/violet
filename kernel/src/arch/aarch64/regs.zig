const std = @import("std");

pub const ID_AA64PFR0_EL1 = packed struct(u64) {
    el0: u4, // bit 0-3
    el1: u4, // bit 4-7
    el2: u4, // bit 8-11
    el3: u4, // bit 12-15
    fp: u4, // bit 16-19
    adv_simd: u4, // bit 20-23
    gic_regs: u4, // bit 24-27
    _reserved: u36, // bit 28-63

    pub fn load() ID_AA64PFR0_EL1 {
        const id_aa64pfr0_el1: ID_AA64PFR0_EL1 = asm volatile (
            \\ mrs %[result], id_aa64pfr0_el1
            : [result] "=r" (-> ID_AA64PFR0_EL1),
        );
        return id_aa64pfr0_el1;
    }
};

pub const SPSR_EL1 = packed struct(u64) {
    mode: enum(u4) { // bit 0-3
        el0t = 0b0000,
        el1t = 0b0100,
        el1h = 0b0101,
    },
    _reserved0: u4 = 0, // bits 4-7
    ss: bool, // bit 8
    il: bool, // bit 9
    f: bool, // bit 10 (FIQ mask)
    i: bool, // bit 11 (IRQ mask)
    a: bool, // bit 12 (SError mask)
    d: bool, // bit 13 (Debug mask)
    _reserved1: u14 = 0, // bits 14-27
    v: bool = false, // bit 28
    c: bool = false, // bit 29
    z: bool = false, // bit 30
    n: bool = false, // bit 31, MSB
    _ignored: u32 = 0, // bit 32-63

    pub fn load() SPSR_EL1 {
        const spsr_el1: SPSR_EL1 = asm volatile (
            \\ mrs %[result], spsr_el1
            : [result] "=r" (-> SPSR_EL1),
        );
        return spsr_el1;
    }
};

pub const ESR_EL1 = packed struct(u64) {
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
        std.log.info(
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

pub const CPACR_EL1 = packed struct(u64) {
    _reserved0: u16, // [0..15] Reserved (RES0)
    zen: u2, // [16..17] SVE access
    _reserved1: u2, // [18..19] Reserved (RES0)
    fpen: enum(u2) { // [20..21] Floating-point/SIMD access
        off = 0b00,
        el1 = 0b01,
        el0_el1 = 0b11,
    },
    smen: u2, // [22..23] SME (Scalable Matrix Extension) access
    _reserved2: u4, // [24..27] Reserved (RES0)
    tta: bool, // [28] Trace Trap Access
    _reserved3: u3, // [29..31] Reserved (RES0)
    _reserved4: u32, // [32..63] Reserved (RES0)

    pub fn load() CPACR_EL1 {
        const cpacr_el1: CPACR_EL1 = asm volatile (
            \\ mrs %[result], cpacr_el1
            : [result] "=r" (-> CPACR_EL1),
        );
        return cpacr_el1;
    }

    pub fn store(self: CPACR_EL1) void {
        asm volatile (
            \\ msr cpacr_el1, %[input]
            :
            : [input] "r" (self),
            : "memory"
        );
    }
};
