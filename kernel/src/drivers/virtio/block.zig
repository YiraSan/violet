// --- dependencies --- //

const std = @import("std");

const log = std.log.scoped(.virtio_blk_pci);

// --- imports --- //

const kernel = @import("root");

const Device = kernel.drivers.pcie.Device;

// --- virtio/block.zig --- //

var initialized: std.atomic.Value(bool) = .init(false);
pub fn init() !void {
    if (initialized.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null) {
        // ...
    }
}

pub fn handle(device: Device) !void {
    try init();

    log.debug("new device at ({})", .{device});
}
