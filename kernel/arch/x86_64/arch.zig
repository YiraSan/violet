pub const cpu = @import("cpu.zig");
pub const serial = @import("serial.zig");

const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .x86_64) {
        @compileError("x86_64 has been referenced while compiling to " ++ @tagName(builtin.cpu.arch));
    }
}

pub fn init() !void {
    try serial.init();
}
