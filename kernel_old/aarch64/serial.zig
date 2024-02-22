pub fn init() !void {
    
}

pub fn write(char: u8) void {
    // @fence(.SeqCst);
    // @as(*volatile u8, @ptrFromInt(0x09000000)).* = char;
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
