const std = @import("std");
const arch = @import("arch/arch.zig");
const build_options = @import("build_options");

const log = std.log.scoped(.main);

pub fn main() !void {
    try arch.init();

    log.info("violet v{s}", .{build_options.version});
}
