pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot/boot.zig");
pub const device = @import("device/device.zig");
pub const drivers = @import("drivers/drivers.zig");

comptime {
    // TODO on raspi4b limine might be useless
    @export(&boot.entry.start, .{ .name = "_start", .linkage = .strong });
}

// std & zig features

const std = @import("std");

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = return_address;
    std.log.err("kernel panic: {s}", .{message});
    arch.halt();
    unreachable;
}

pub fn logFn(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    const scope_prefix = if (scope == .default) "main" else @tagName(scope);
    const prefix = "\x1b[35m[kernel:" ++ scope_prefix ++ "] " ++ switch (level) {
        .err => "\x1b[31merror",
        .warn => "\x1b[33mwarning",
        .info => "\x1b[36minfo",
        .debug => "\x1b[90mdebug",
    } ++ ": \x1b[0m";
    device.serial.print(prefix ++ format ++ "\n", args);
}

pub const std_options: std.Options = .{
    .logFn = logFn
};
