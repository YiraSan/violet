const build_options = @import("build_options");

pub usingnamespace switch (build_options.platform) {
    .q35 => @import("q35_serial.zig"),
    .virt => @import("pl011.zig"),
    else => @import("null_serial.zig"),
};
