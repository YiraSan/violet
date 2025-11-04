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
var hhdm_limit: u64 = undefined;

// memory_map and configuration_tables becomes unavailable after full kernel initialization.

var memory_map: mem.MemoryMap = undefined;
var configuration_tables: []uefi.tables.ConfigurationTable = undefined;

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

    mem.init() catch unreachable;
    mem.phys.init(memory_map, hhdm_base) catch unreachable;
    mem.virt.init(hhdm_limit) catch unreachable;

    const stack = mem.phys.alloc_contiguous_pages(8, .l4K, false) catch unreachable;
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

    unreachable;
}

fn main() !void {
    var xsdt: *drivers.acpi.Xsdt = undefined;
    var xsdt_found = false;
    for (configuration_tables) |*entry| {
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid)) {
            @setRuntimeSafety(false);
            const rsdp: *drivers.acpi.Rsdp = @ptrFromInt(@intFromPtr(entry.vendor_table));
            xsdt = @ptrFromInt(rsdp.xsdt_addr);
            xsdt_found = true;
        }
    }

    if (!xsdt_found) return error.IncompatibleAcpi;

    try drivers.serial.init(xsdt);

    log.info("kernel v{s}", .{build_options.version});

    try arch.init(xsdt);

    try scheduler.init();

    const process = scheduler.Process.new(.kernel);

    _ = process.newTask(&_task0, .{});
    _ = process.newTask(&_task1, .{});

    arch.unmaskInterrupts();

    // Enter scheduler...
    switch (builtin.cpu.arch) {
        .aarch64 => {
            asm volatile ("svc #0");
        },
        else => unreachable,
    }

    @panic("not supposed to come back there !");
}

fn _task0() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    asm volatile ("brk #0");

    log.info("hello from task 0 !", .{});

    // TODO.
    while (true) {}

    // terminate task.
    asm volatile ("svc #1");

    unreachable;
}

fn _task1() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    asm volatile ("brk #1");

    log.info("hello from task 1 !", .{});

    // TODO.
    while (true) {}

    // terminate task.
    asm volatile ("svc #1");

    unreachable;
}

// --- zig std features --- //

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = return_address;
    std.log.err("kernel panic: {s}", .{message});
    ark.cpu.halt();
}

const SpinLock = struct {
    value: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *SpinLock) void {
        while (true) {
            if (self.value.cmpxchgWeak(0, 1, .seq_cst, .seq_cst) == null) {
                break;
            }
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.value.store(0, .seq_cst);
    }
};

var logfn_lock: SpinLock = .{};

pub fn logFn(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    const scope_prefix = if (scope == .default) "unknown" else @tagName(scope);
    const prefix = "\x1b[35m[kernel:" ++ scope_prefix ++ "] " ++ switch (level) {
        .err => "\x1b[31merror",
        .warn => "\x1b[33mwarn",
        .info => "\x1b[36minfo",
        .debug => "\x1b[90mdebug",
    } ++ ": \x1b[0m";
    logfn_lock.lock();
    defer logfn_lock.unlock();
    drivers.serial.print(prefix ++ format ++ "\n", args);
}

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};
