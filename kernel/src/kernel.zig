// --- imports --- /

const std = @import("std");
const log = std.log.scoped(.main);

const builtin = @import("builtin");
const build_options = @import("build_options");

// --- bootloader requests --- //

const limine = @import("limine");

export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

export var base_revision: limine.BaseRevision linksection(".limine_requests") = .init(3);

// --- main.zig --- //

pub const cpu = @import("cpu/cpu.zig");
pub const interrupts = @import("interrupts/interrupts.zig");
pub const mem = @import("mem/mem.zig");
pub const serial = @import("serial/serial.zig");

export fn kernel_entry() callconv(switch (builtin.cpu.arch) {
    .x86_64 => .{ .x86_64_sysv = .{} },
    .aarch64 => .{ .aarch64_aapcs = .{} },
    else => unreachable,
}) void {
    if (!base_revision.isSupported()) {
        @panic("unsupported limine base revision");
    }

    // STAGE 0

    mem.init();
    mem.phys.init();
    cpu.init();

    // STAGE 1

    mem.virt.init();
    serial.init();
    interrupts.init();

    // STAGE 2

    log.info("violet/kernel {s}", .{build_options.version});

    cpu.hcf();
}

// --- zig std features --- //

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = return_address;
    log.err("kernel panic: {s}", .{message});
    cpu.hcf();
}

pub fn logFn(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    const scope_prefix = if (scope == .default) "unknown" else @tagName(scope);
    const prefix = "\x1b[35m[kernel:" ++ scope_prefix ++ "] " ++ switch (level) {
        .err => "\x1b[31merror",
        .warn => "\x1b[33mwarn",
        .info => "\x1b[36minfo",
        .debug => "\x1b[90mdebug",
    } ++ ": \x1b[0m";
    serial.print(prefix ++ format ++ "\n", args);
}

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};
