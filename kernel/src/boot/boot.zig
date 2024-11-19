const builtin = @import("builtin");
const limine = @import("limine.zig");

pub const entry = struct {
    pub fn start() callconv(.C) noreturn {
        while (true) {}
    }
};
