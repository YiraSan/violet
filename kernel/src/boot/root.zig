// --- dependencies --- //

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

// --- imports --- //

const kernel = @import("root");

const adapter =
    if (build_options.use_uefi) @import("uefi/root.zig") else switch (build_options.platform) {
        else => unreachable,
    };

comptime {
    _ = adapter;
}

// --- boot/root.zig --- //

pub var hhdm_base: u64 = 0;
pub var hhdm_limit: u64 = 0;

pub const MemoryEntry = struct {
    physical_base: *u64,
    number_of_pages: *u64,
};

pub const UsableMemoryIterator = adapter.UsableMemoryIterator;

/// TODO temp structure
pub var xsdt: *kernel.drivers.acpi.Xsdt = undefined;
