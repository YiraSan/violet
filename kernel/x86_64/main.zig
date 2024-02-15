const arch = @import("arch.zig");

const cr = @import("cr.zig");
const main = @import("../main.zig").main;

pub fn start() callconv(.C) noreturn {

    // init floating point unit
    asm volatile ("fninit");

    // enable sse
    var cr0 = cr.read(0);
    cr0 &= ~(@as(u64, 1) << 2);
    cr0 |= @as(u64, 1) << 1;
    cr.write(0, cr0);

    var cr4 = cr.read(4);
    cr4 |= @as(u64, 3) << 9;
    cr.write(4, cr4);

    arch.serial.init() catch arch.idle();
    main() catch arch.idle();
    arch.idle();

}
