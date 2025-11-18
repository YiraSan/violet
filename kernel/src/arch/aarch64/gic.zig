// --- dependencies --- //

const std = @import("std");
const ark = @import("ark");

// --- imports --- //

const kernel = @import("root");

const acpi = kernel.drivers.acpi;

const gic_v2 = @import("gic_v2.zig");

// --- aarch64/gic.zig --- //

var gic_version: enum { v2 } = undefined;

pub fn init() !void {
    switch (ark.armv8.registers.ID_AA64PFR0_EL1.load().gic) {
        .gic_cpu_not_implemented => {
            gic_version = .v2;

            try gic_v2.init();
            try gic_v2.initCpu();
        },
        else => @panic("unimplemented gic version"),
    }
}

pub fn initCpu() !void {
    switch (gic_version) {
        .v2 => {
            try gic_v2.initCpu();
        },
    }
}

pub fn enableIRQ(irq: u32) void {
    switch (gic_version) {
        .v2 => gic_v2.enableIRQ(irq),
    }
}

pub fn disableIRQ(irq: u32) void {
    switch (gic_version) {
        .v2 => gic_v2.disableIRQ(irq),
    }
}

pub fn acknowledge() u32 {
    return switch (gic_version) {
        .v2 => gic_v2.acknowledge(),
    };
}

pub fn endOfInterrupt(irq_id: u32) void {
    switch (gic_version) {
        .v2 => gic_v2.endOfInterrupt(irq_id),
    }
}
