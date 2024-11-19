pub const arch = @import("arch/arch.zig");
pub const boot = @import("boot/boot.zig");
pub const device = @import("device/device.zig");
pub const drivers = @import("drivers/drivers.zig");

comptime {
    @export(&boot.entry.start, .{ .name = "_start", .linkage = .strong });
}
