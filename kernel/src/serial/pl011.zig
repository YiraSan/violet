// --- imports --- //

const std = @import("std");

const builtin = @import("builtin");
const build_options = @import("build_options");

var uart_pl011: @import("uart_pl011") = undefined;

pub fn init(base_address: u64) void {
    uart_pl011.init(base_address);
}

// fn drain(_: *std.io.Writer, data: []const []const u8, _: usize) std.io.Writer.Error!usize {
//     const arr0 = data[0];
//     for (arr0) |char| {
//         uart_pl011.write(char);
//     }
//     return arr0.len;
// }

// pub var writer = std.io.Writer{
//     .buffer = &.{},
//     .vtable = &.{
//         .drain = drain,
//     },
// };

fn writeHandler(_: *anyopaque, bytes: []const u8) anyerror!usize {
    for (bytes) |char| {
        uart_pl011.write(char);
    }
    return bytes.len;
}

pub const writer = std.io.Writer(
    *anyopaque,
    anyerror,
    writeHandler,
){ .context = undefined };

pub fn print(comptime format: []const u8, args: anytype) void {
    writer.print(format, args) catch {};
}

pub fn read() ?u8 {
    return uart_pl011.read();
}
