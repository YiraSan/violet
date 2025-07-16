const std = @import("std");
const builtin = @import("builtin");
const mod = @import("mod");

export fn _start() callconv(switch (builtin.cpu.arch) {
    .x86_64 => .{ .x86_64_sysv = .{} },
    .aarch64 => .{ .aarch64_aapcs = .{} },
    .riscv64 => .{ .riscv64_lp64 = .{} },
    else => unreachable,
}) void {
    mod.main() catch {};
}
