// --- dependencies --- //

const std = @import("std");
const builtin = @import("builtin");

// --- imports --- //

const kernel = @import("root");

const acpi = kernel.drivers.acpi;

const impl = switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64/root.zig"),
    else => unreachable,
};

pub const Context = impl.Context;
pub const ExceptionContext = impl.ExceptionContext;

pub const Cpu = impl.Cpu;

comptime {
    _ = impl;
}

// -- arch/root.zig -- //

pub fn init(xsdt: *acpi.Xsdt) !void {
    try impl.init(xsdt);
}

pub fn initCpus(xsdt: *acpi.Xsdt) !void {
    try impl.initCpus(xsdt);
}

pub fn bootCpus() !void {
    try impl.bootCpus();
}

pub fn maskInterrupts() void {
    impl.maskInterrupts();
}

pub fn unmaskInterrupts() void {
    impl.unmaskInterrupts();
}
