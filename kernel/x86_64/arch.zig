pub const serial = @import("serial.zig");
pub const main = @import("main.zig");

pub fn idle() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}
