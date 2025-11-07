//! TODO make a boot/ that will contains agnostic interface in order to avoid using directly ACPI and make the kernel bootloading-agnostic. To then implement UEFI-less bootloading.
// --- dependencies --- //

const ark = @import("ark");
const build_options = @import("build_options");
const builtin = @import("builtin");
const std = @import("std");

const uefi = std.os.uefi;

const log = std.log.scoped(.main);

// --- imports --- //

pub const arch = @import("arch/root.zig");
pub const drivers = @import("drivers/root.zig");
pub const mem = @import("mem/root.zig");
pub const scheduler = @import("scheduler/root.zig");

// --- main.zig --- //

pub var hhdm_base: u64 = undefined;
pub var hhdm_limit: u64 = undefined;

pub var boot_space: mem.virt.Space = undefined;
pub var xsdt: *drivers.acpi.Xsdt = undefined;
pub var memory_map: mem.MemoryMap = undefined;
pub var configuration_tables: []uefi.tables.ConfigurationTable = undefined;

export fn kernel_entry(
    _memory_map_ptr: [*]uefi.tables.MemoryDescriptor,
    _memory_map_size: u64,
    _memory_map_descriptor_size: u64,
    _hhdm_base: u64,
    _hhdm_limit: u64,
    _configuration_tables: [*]uefi.tables.ConfigurationTable,
    _configuration_number_of_entries: usize,
) callconv(switch (builtin.cpu.arch) {
    .aarch64 => .{ .aarch64_aapcs = .{} },
    .riscv64 => .{ .riscv64_lp64 = .{} },
    else => unreachable,
}) noreturn {
    arch.maskInterrupts();

    memory_map = .{
        .map = _memory_map_ptr,
        .map_size = _memory_map_size,
        .descriptor_size = _memory_map_descriptor_size,
    };

    hhdm_base = _hhdm_base;
    hhdm_limit = _hhdm_limit;

    configuration_tables = _configuration_tables[0.._configuration_number_of_entries];

    mem.phys.init(memory_map, hhdm_base) catch unreachable;

    var xsdt_found = false;
    for (configuration_tables) |*entry| {
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid)) {
            @setRuntimeSafety(false);
            const rsdp: *drivers.acpi.Rsdp = @ptrFromInt(@intFromPtr(entry.vendor_table));
            xsdt = @ptrFromInt(rsdp.xsdt_addr);
            xsdt_found = true;
        }
    }

    if (!xsdt_found) unreachable;

    arch.initCpus(xsdt) catch unreachable;
    mem.phys.initCpu() catch unreachable;

    mem.virt.init(hhdm_limit) catch unreachable;

    boot_space = .init(.lower, switch (builtin.cpu.arch) {
        .aarch64 => ark.cpu.armv8a_64.registers.TTBR0_EL1.get().l0_table,
        else => unreachable,
    });

    const stack = mem.phys.allocContiguousPages(8, .l4K, false) catch unreachable;
    const stack_top = hhdm_base + stack + (0x1000 * 8);

    switch (builtin.cpu.arch) {
        .aarch64 => {
            asm volatile (
                \\ mov x1, #0
                \\ msr spsel, x1
                \\ isb
                \\
                \\ mov sp, %[st]
                \\ isb
                \\
                \\ b _main
                :
                : [st] "r" (stack_top),
                : "memory", "x1"
            );
        },
        else => unreachable,
    }

    unreachable;
}

export fn _main() noreturn {
    main() catch |err| {
        std.log.err("main returned with an error: {}", .{err});
    };

    ark.cpu.halt();
}

fn main() !void {
    try drivers.serial.init(xsdt);

    log.info("kernel v{s}", .{build_options.version});

    try arch.init(xsdt);
    try scheduler.init();
    try arch.bootCpus();

    const process = try scheduler.Process.create(.{
        .execution_level = .kernel,
    });

    const task0 = try process.createTask(.{ .entry_point = &_task0 });
    const task1 = try process.createTask(.{ .entry_point = &_task1 });

    try scheduler.registerTask(task0);
    try scheduler.registerTask(task1);

    // jump to scheduler
    arch.unmaskInterrupts();
    drivers.Timer.arm(._5ms);
}

fn _task0(_: *[0x1000]u8) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    asm volatile ("brk #0");

    log.info("hello from task 0 !", .{});

    // terminate task.
    asm volatile ("svc #1");
    unreachable;
}

fn _task1(_: *[0x1000]u8) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    asm volatile ("brk #1");

    log.info("hello from task 1 !", .{});

    // terminate task.
    asm volatile ("svc #1");
    unreachable;
}

// --- zig std features --- //

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = return_address;
    std.log.err("kernel panic: {s}", .{message});

    // NOTE little panic handler
    const cpu = arch.Cpu.get();
    if (cpu.current_task) |task| {
        task.terminate();
        drivers.Timer.arm(._1ms);
    }

    ark.cpu.halt();
}

pub fn logFn(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    const scope_prefix = if (scope == .default) "" else ":" ++ @tagName(scope);
    const prefix = "\x1b[35m[kernel" ++ scope_prefix ++ "] " ++ switch (level) {
        .err => "\x1b[31merror",
        .warn => "\x1b[33mwarn",
        .info => "\x1b[36minfo",
        .debug => "\x1b[90mdebug",
    } ++ ": \x1b[0m";
    drivers.serial.print(prefix ++ format ++ "\n", args);
}

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};
