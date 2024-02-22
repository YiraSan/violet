const arch = @import("arch.zig");

const main = @import("../main.zig").main;

pub fn start() callconv(.C) noreturn {

    arch.serial.init() catch arch.idle();
    main() catch arch.idle();
    arch.idle();

}
