pub const serial = @import("serial.zig");
pub const main = @import("main.zig");

pub const Spinlock = @import("spinlock.zig").Spinlock;

const int = @import("int.zig");

pub fn idle() noreturn {
    int.disable();
    while (true) {
        asm volatile ("hlt");
    }
}
