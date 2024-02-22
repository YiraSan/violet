const std = @import("std");
const serial = @import("../arch.zig").serial;

fn write(_: *anyopaque, bytes: []const u8) anyerror!usize {
    serial.print(bytes);
    return bytes.len;
}

pub const writer = std.io.Writer(
    *anyopaque,
    anyerror,
    write,
){ .context = undefined };
