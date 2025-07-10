// --- imports --- //

const std = @import("std");
const builtin = @import("builtin");

const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64/cpu.zig"),
    .x86_64 => @import("x86_64/cpu.zig"),
    else => unreachable,
};

// --- cpu.zig --- //

pub fn init() void {
    arch.init();
}

// --- utils --- //

pub fn hcf() noreturn {
    while (true) {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile ("hlt"),
            .aarch64 => asm volatile ("wfi"),
            .riscv64 => asm volatile ("wfi"),
            else => unreachable,
        }
    }
}
