// --- imports --- //

const std = @import("std");
const log = std.log.scoped(.arch);

const builtin = @import("builtin");

const exception = @import("exception.zig");

const gic_v2 = @import("gic_v2.zig");

// --- arch.zig --- //

pub fn init() void {
    const features0 = ID_AA64PFR0_EL1.load();

    if (features0.fp != 0x01) {
        @panic("hardware floating point is unsupported");
    }

    if (features0.adv_simd != 0x01) {
        @panic("advanced SIMD is unsupported");
    }

    exception.init();

    switch (features0.gic_regs) {
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

const ID_AA64PFR0_EL1 = packed struct(u64) {
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
