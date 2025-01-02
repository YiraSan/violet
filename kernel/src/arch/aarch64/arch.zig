const std = @import("std");

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

pub fn init() void {
    const current_el = currentEL();
    if (current_el != 1) {
        std.log.err("wrong execution level {}", .{current_el});
        unreachable;
    }
}
