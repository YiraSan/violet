// --- imports --- //

const std = @import("std");
const log = std.log.scoped(.arch);

const kernel = @import("root");
const process = kernel.process;

const builtin = @import("builtin");

const exception = @import("exception.zig");

const regs = @import("regs.zig");
const gic_v2 = @import("gic_v2.zig");

// --- arch.zig --- //

pub fn init() void {
    const id_aa64pfr0_el1 = regs.ID_AA64PFR0_EL1.load();
    var cpacr_el1 = regs.CPACR_EL1.load();

    if (id_aa64pfr0_el1.fp != 0x01) {
        @panic("FP/NEON is required on violetOS");
    }

    cpacr_el1.fpen = .el0_el1; // TODO el1_only then trap to active dynamic context switching

    if (id_aa64pfr0_el1.adv_simd == 0x01) {
        log.warn("ADV SIMD detected. Not supported now.", .{});
    }

    cpacr_el1.store();

    exception.init();

    switch (id_aa64pfr0_el1.gic_regs) {
        0x00 => { // GIC V2
            gic_v2.init();
        },
        0x01 => { // GIC V3+
            @panic("unsupported GIC V3+, coming soon.");
        },
        else => unreachable,
    }
}

// --- structs --- //

pub const TaskContext = struct {
    xregs: [30]u64 = std.mem.zeroes([30]u64), // x0-x29
    lr: u64 = 0, // x30 (link register)
    spsr_el1: regs.SPSR_EL1, // process state (flags + mode)
    elr_el1: u64, // return address (PC)
    sp_el0: u64, // stack pointer (SP_EL0)
    tpidr_el1: u64, // pointer to Task (kernel)
    tpidrro_el0: process.TaskInfo, // pointer to TaskInfo for userland
    // FP/NEON
    vregs: [32]u128 = std.mem.zeroes([32]u128),
    fpcr: u64 = 0,
    fpsr: u64 = 0,
};

pub const ThreadContext = struct {
    sp_el1: u64,
    tpidr_el0: u64 = 0,
};
