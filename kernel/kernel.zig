const boot = @import("boot/boot.zig");

comptime {
    @export(boot.entry.start, .{ .name = "_start", .linkage = .strong });
}

const std = @import("std");
const arch = @import("arch/arch.zig");

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = return_address;
    std.log.err("kernel panic: {s}", .{message});
    arch.cpu.halt();
    unreachable;
}

pub fn logFn(comptime level: std.log.Level, comptime scope: @Type(.EnumLiteral), comptime format: []const u8, args: anytype) void {
    const scope_prefix = if (scope == .default) "main" else @tagName(scope);
    const prefix = "\x1b[35m[kernel:" ++ scope_prefix ++ "] " ++ switch (level) {
        .err => "\x1b[31merror",
        .warn => "\x1b[33mwarning",
        .info => "\x1b[36minfo",
        .debug => "\x1b[90mdebug",
    } ++ ": \x1b[0m";
    arch.serial.print(prefix ++ format ++ "\n", args);
}

pub const std_options: std.Options = .{
    .logFn = logFn
};
