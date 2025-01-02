const build_options = @import("build_options");

const drivers = @import("root").drivers;

pub const serial = switch (build_options.device) {
    .virt => drivers.uart.pl011,
    else => unreachable,
};

pub fn init() void {

    // TODO device tree will be used later on aarch64

    switch (build_options.device) {
        .virt => {
            drivers.uart.pl011.base_address = 0x09000000;
        },
        else => unreachable,
    }

    try serial.init();

}
