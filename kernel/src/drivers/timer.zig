const basalt = @import("basalt");

const generic_timer = @import("../arch/aarch64/generic_timer.zig");

pub var selected_timer: enum { unselected, generic_timer } = .unselected;

pub fn arm(delay: basalt.timer.Delay) void {
    switch (selected_timer) {
        .generic_timer => generic_timer.arm(delay),
        else => unreachable,
    }
}

pub fn cancel() void {
    switch (selected_timer) {
        .generic_timer => generic_timer.disable(),
        else => unreachable,
    }
}
