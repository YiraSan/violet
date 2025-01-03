pub const null_serial = @import("null_serial.zig");

pub const uart = struct {
    pub const pl011 = @import("uart/pl011.zig");
};
