const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 4) return error.MissingArguments;

    const in_path = args[1];
    const out_path = args[2];
    const size_str = args[3];

    const target_size = try std.fmt.parseInt(u64, size_str, 10);

    const cwd = std.Io.Dir.cwd();

    try cwd.copyFile(in_path, cwd, out_path, io, .{});

    if (target_size > 0) {
        var file = try cwd.openFile(io, out_path, .{ .mode = .read_write });
        defer file.close(io);

        try file.setLength(io, target_size - 1);
        try file.sync(io);
    }
}
