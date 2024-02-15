pub const serial = @import("serial.zig");
pub const main = @import("main.zig");

pub fn idle() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}
