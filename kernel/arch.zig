const builtin = @import("builtin");

pub usingnamespace switch (builtin.cpu.arch) {
    .x86_64 => @import("x86_64/arch.zig"),
    .aarch64 => @import("aarch64/arch.zig"),
    .riscv64 => @import("riscv64/arch.zig"),
    else => unreachable,
};
