pub const null_serial = @import("null_serial.zig");
pub const q35_serial = @import("q35_serial.zig");

pub const uart = struct {
    pub const pl011 = @import("uart/pl011.zig");
};
