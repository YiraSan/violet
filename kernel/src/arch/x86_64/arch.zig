// --- imports --- //

const gdt = @import("gdt.zig");
const idt = @import("idt.zig");

// --- arch.zig --- //

pub fn init() void {
    gdt.init();
    idt.init();
}
