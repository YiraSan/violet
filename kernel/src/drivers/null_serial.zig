pub fn init() !void {}

pub fn print(comptime format: []const u8, args: anytype) void {
    _ = format;
    _ = args;
}

pub fn read() ?u8 {
    return null;
}
