pub const cpu = @import("cpu.zig");
pub const serial = @import("serial.zig");

const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .riscv64) {
        @compileError("riscv64 has been referenced while compiling to " ++ @tagName(builtin.cpu.arch));
    }
}

pub fn init() !void {
    try serial.init();
}
