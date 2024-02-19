pub const serial = @import("serial.zig");
pub const main = @import("main.zig");

pub const Spinlock = @import("spinlock.zig").Spinlock;

pub fn idle() noreturn {
    while (true) {}
    unreachable;
}
