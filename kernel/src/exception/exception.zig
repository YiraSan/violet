const builtin = @import("builtin");

const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64/exception.zig"),
    .x86_64 => @import("x86_64/exception.zig"),
    else => unreachable,
};

pub const init = arch.init;
