const builtin = @import("builtin");

const mod = @import("mod");

export fn _start() callconv(switch (builtin.cpu.arch) {
    .aarch64 => .{ .aarch64_aapcs = .{} },
    .riscv64 => .{ .riscv64_lp64 = .{} },
    else => unreachable,
}) void {
    mod.main() catch {};
}
