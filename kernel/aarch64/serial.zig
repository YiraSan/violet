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
