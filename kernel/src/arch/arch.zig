const builtin = @import("builtin");

pub const init = switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64/arch.zig").init,
    .x86_64 => @import("x86_64/arch.zig").init,
    else => unreachable,
};

pub inline fn halt() noreturn {
    while (true) {
        if (comptime builtin.cpu.arch == .x86_64) {
            asm volatile ("hlt");
        } else if (comptime builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .riscv64) {
            asm volatile ("wfi");
        }
    }
    unreachable;
}
