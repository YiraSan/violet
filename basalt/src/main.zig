const builtin = @import("builtin");

const mod = @import("mod");

export fn _start(local_ctx: *[4096]u8) callconv(switch (builtin.cpu.arch) {
    .aarch64 => .{ .aarch64_aapcs = .{} },
    .riscv64 => .{ .riscv64_lp64 = .{} },
    else => unreachable,
}) void {
    _ = local_ctx;
    mod.main() catch {};
}
