const std = @import("std");
const arch = @import("arch/arch.zig");
const build_options = @import("build_options");

pub fn main() !void {
    try arch.init();

    std.log.info("violet v{s}", .{build_options.version});
}
