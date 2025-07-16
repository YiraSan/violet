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
export var module_request: limine.ModuleRequest linksection(".limine_requests") = .{};

// --- main.zig --- //

pub const arch = @import("arch/arch.zig");
pub const cpu = @import("cpu/cpu.zig");
pub const mem = @import("mem/mem.zig");
pub const process = @import("process/process.zig");

pub const serial = switch (build_options.platform) {
    .aarch64_virt, .riscv64_virt => @import("serial/pl011.zig"),
    .x86_64_q35 => @import("serial/q35_serial.zig"),
};

export fn kernel_entry() callconv(switch (builtin.cpu.arch) {
    .x86_64 => .{ .x86_64_sysv = .{} },
    .aarch64 => .{ .aarch64_aapcs = .{} },
    .riscv64 => .{ .riscv64_lp64 = .{} },
    else => unreachable,
}) void {
    if (!base_revision.isSupported()) {
        @panic("unsupported limine base revision");
    }

    // STAGE 0

    mem.init();
    mem.phys.init();
    mem.virt.init();
    serial.init();

    log.info("violet/kernel {s}", .{build_options.version});

    // STAGE 1

    arch.init();
    process.init();

    if (module_request.response) |module_response| {
        const resp: *limine.ModuleResponse = module_response;

        for (resp.getModules()) |module| {
            if (std.mem.eql(u8, std.mem.span(module.path), "/system.elf")) {
                log.info("loading system...", .{});
                const sys_proc = process.Process.load(@as([*]align(4096) u8, @ptrCast(module.address))[0..module.size]) catch unreachable;
                const sys_thread = sys_proc.new_thread() catch unreachable;
                const sys_task = sys_thread.new_task(sys_proc.entry_point_virt) catch unreachable;

                sys_task.jump();

                break;
            }
        }
    }

    cpu.hcf();
}

// --- zig std features --- //

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = return_address;
    std.log.err("kernel panic: {s}", .{message});
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
