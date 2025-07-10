const std = @import("std");
const builtin = @import("builtin");

export fn _start() callconv(switch (builtin.cpu.arch) {
    .x86_64 => .{ .x86_64_sysv = .{} },
    .aarch64 => .{ .aarch64_aapcs = .{} },
    else => unreachable,
}) void {
    while (true) {}
}
