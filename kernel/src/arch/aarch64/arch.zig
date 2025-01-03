const std = @import("std");
const arch = @import("../arch.zig");
const boot = @import("../../boot/boot.zig");

fn currentEL() u64 {
    var current_el: u64 = 0;
     
    asm volatile (
        "mrs %[result], CurrentEL"
        : [result] "=r" (current_el)
        : 
        : "memory"
    );

    current_el = (current_el >> 2) & 0x3;

    return current_el;
}

fn getESR() u64 {
    var esr: u64 = 0;

    asm volatile (
        "mrs %[result], ESR_EL1"
        : [result] "=r" (esr)
        :
        : "memory"
    );

    return esr;
}

export fn sync_handler() callconv(.{ .aarch64_aapcs = .{} }) void {
    const esr = getESR();
    const ec = (esr >> 26) & 0x3F; // Exception Class (EC) is in bits [31:26]

    // checking if we are in EL1 should be nice
    if (ec == 0x3c) {
        std.log.info("BRK exception occurred! Handling breakpoint.", .{});

        const imm16 = esr & 0xFFFF;
        std.log.info("BRK immediate value: {}", .{imm16});
        
        var elr: u64 = 0;

        asm volatile (
            "mrs %[result], ELR_EL1"
            : [result] "=r" (elr)
            :
            : "memory"
        );

        elr += 4;
        asm volatile (
            "msr ELR_EL1, %[elr]"
            :
            : [elr] "r" (elr)
            : "memory"
        );

        return;
    }

    std.log.info("unhandled sync exception with EC: {x}", .{ ec });
    arch.halt();
}

export fn fault_handler() callconv(.{ .aarch64_aapcs = .{} }) void {
    std.log.info("unhandled fault", .{});
    arch.halt();
}

export fn irq_handler() callconv(.{ .aarch64_aapcs = .{} }) void {
    std.log.info("unhandled irq", .{});
    arch.halt();
}

extern const _vector_table: opaque {};

fn init_vector_table() void {
    // mask all interrupts
    asm volatile("msr DAIFSet, #0b1111");

    const vt_base: u64 = @intFromPtr(&_vector_table);

    asm volatile (
        "msr VBAR_EL1, %[vt_base]"
        : 
        : [vt_base] "r" (vt_base)
        : "memory"
    );

    // ensure changes take effect
    asm volatile("isb");

    // unmask all
    asm volatile("msr DAIFClr, #0b1111");
}

pub fn init() void {
    const current_el = currentEL();
    if (current_el != 1) {
        std.log.err("wrong execution level {}", .{current_el});
        unreachable;
    }

    init_vector_table();

    // temporary test
    asm volatile("brk #1");
}
