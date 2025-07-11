// --- imports --- //

const std = @import("std");
const log = std.log.scoped(.interrupts);

const gdt = @import("gdt.zig");
const idt = @import("idt.zig");

// --- interrupts.zig --- //

pub fn init() void {
    gdt.init();
    idt.init();
}
