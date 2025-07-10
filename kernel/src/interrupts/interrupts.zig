const builtin = @import("builtin");

const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64/interrupts.zig"),
    .x86_64 => @import("x86_64/interrupts.zig"),
    else => unreachable,
};

pub const init = arch.init;
