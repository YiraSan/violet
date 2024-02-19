const PL011 = @import("serial/pl011.zig");
const NS16550 = @import("serial/ns16550.zig");

pub fn init() !void {
    
}

pub fn write(char: u8) void {

    if (char == '\n') write('\r');
}

pub fn print(text: []const u8) void {
    for (text) |char| {
        write(char);
    }
}

pub fn read() u8 {
    return 0;
}