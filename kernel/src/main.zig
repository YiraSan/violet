// --- dependencies --- //

const ark = @import("ark");
const build_options = @import("build_options");
const builtin = @import("builtin");
const std = @import("std");

// --- imports --- //

const serial = switch (build_options.platform) {
    .aarch64_qemu, .riscv64_qemu => @import("serial/pl011.zig"),
    else => @import("serial/null_serial.zig"),
};

// --- root static variables --- //

pub var vm: ark.mem.VirtualMemory = undefined;
pub var page_allocator: ark.mem.PageAllocator = undefined;

// --- main.zig --- //

const log = std.log.scoped(.main);

var memory_table: PhysicalMemory.MemoryTable = undefined;
var hhdm_base: u64 = undefined;
var hhdm_limit: u64 = undefined;

export fn kernel_entry(
    map: *anyopaque,
    map_size: u64,
    descriptor_size: u64,
    _hhdm_base: u64,
    _hhdm_limit: u64,
) callconv(switch (builtin.cpu.arch) {
    .aarch64 => .{ .aarch64_aapcs = .{} },
    .riscv64 => .{ .riscv64_lp64 = .{} },
    else => unreachable,
}) noreturn {
    memory_table = .{
        .map = map,
        .map_key = 0,
        .map_size = map_size,
        .descriptor_size = descriptor_size,
    };

    hhdm_base = _hhdm_base;
    hhdm_limit = _hhdm_limit;

    PhysicalMemory.init(memory_table) catch unreachable;

    const stack = PhysicalMemory.alloc_page(.l4K) catch unreachable;
    const stack_top = stack + 0x1000;

    asm volatile(
        \\ mov x1, #0
        \\ msr spsel, x1
        \\ isb
        \\
        \\ mov sp, %[st]
        \\ isb
        \\
        \\ b _main
        :
        : [st] "r" (stack_top)
        : "memory", "x1"
    );

    ark.cpu.halt();
}

export fn _main() noreturn {
    main() catch |err| {
        std.log.err("main returned with an error: {}", .{err});
    };

    ark.cpu.halt();
}

fn main() !void {
    vm = .{
        .user_space = @constCast(&ark.mem.VirtualSpace.init(.lower, switch (builtin.cpu.arch) {
            .aarch64 => @ptrFromInt(ark.cpu.armv8a_64.registers.TTBR0_EL1.get().l0_table),
            else => unreachable,
        })),
        .kernel_space = .init(.higher, switch (builtin.cpu.arch) {
            .aarch64 => @ptrFromInt(ark.cpu.armv8a_64.registers.TTBR1_EL1.get().l0_table),
            else => unreachable,
        }),
    };

    vm.kernel_space.last_addr = hhdm_limit;

    page_allocator = ark.mem.PageAllocator{
        .ctx = undefined,
        ._alloc = &_alloc,
        ._free = &_free,
    };

    {
        const reservation = ark.mem.VirtualReservation{
            .space = &vm.kernel_space,
            .virt = hhdm_base + 0x09000000,
            .size = 1,
        };

        reservation.map_contiguous(page_allocator, 0x09000000, .{
            .device = true,
            .writable = true,
        });
    }

    switch (build_options.platform) {
        .aarch64_qemu => {
            serial.init(hhdm_base + 0x09000000);
        },
        else => {},
    }

    log.info("kernel v{s}", .{build_options.version});

    exception_init();

    gic_v2.init();

    ark.cpu.halt();
}

fn _alloc(_: *anyopaque, count: usize) ark.mem.PageAllocator.AllocError![*]align(0x1000) u8 {
    const addr = PhysicalMemory.alloc_contiguous_pages(count, .l4K, false) catch return error.OutOfMemory;
    return @ptrFromInt(addr);
}

fn _free(_: *anyopaque, addr: [*]align(0x1000) u8, count: usize) void {
    PhysicalMemory.free_contiguous_pages(@intFromPtr(addr), count, .l4K);
}

// --- zig std features --- //

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = return_address;
    std.log.err("kernel panic: {s}", .{message});
    ark.cpu.halt();
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

// --- exceptions --- //

extern fn set_vbar_el1(addr: u64) callconv(.{ .aarch64_aapcs = .{} }) void;
extern fn set_sp_el1(addr: u64) callconv(.{ .aarch64_aapcs = .{} }) void;
extern fn set_sp_el0(addr: u64) callconv(.{ .aarch64_aapcs = .{} }) void;

extern const exception_vector_table: [2048]u8;

const sp_el1_stack_size = 0x1000 * 64;
const sp_el1_stack: [sp_el1_stack_size]u8 align(0x1000) linksection(".bss") = undefined;

pub fn exception_init() void {
    set_sp_el1(@intFromPtr(&sp_el1_stack) + sp_el1_stack_size);
    set_vbar_el1(@intFromPtr(&exception_vector_table));
}

const ExceptionContext = extern struct {
    lr: u64,
    _: u64 = 0, // padding
    xregs: [30]u64,
    vregs: [32]u128,
    fpcr: u64,
    fpsr: u64,
    elr_el1: u64,
    spsr_el1: ark.cpu.armv8a_64.registers.SPSR_EL1,
};

fn sync_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    const esr_el1 = ark.cpu.armv8a_64.registers.ESR_EL1.get();

    switch (esr_el1.ec) {
        .brk_aarch64 => {
            log.info("BREAKPOINT from {s} at address 0x{x} with immediate value {}", .{ @tagName(ctx.spsr_el1.mode), ctx.elr_el1, esr_el1.iss });
            ctx.elr_el1 += 4;
            return;
        },
        .svc_inst_aarch64 => {
            switch (ctx.spsr_el1.mode) {
                .el0 => {
                    std.log.info("hello from userland!", .{});
                },
                else => {
                    // const task: *kernel.process.Task = @ptrFromInt(ctx.xregs[0]);

                    // ctx.lr = task.context.lr;
                    // ctx.xregs = task.context.xregs;
                    // ctx.vregs = task.context.vregs;
                    // ctx.fpcr = task.context.fpcr;
                    // ctx.fpsr = task.context.fpsr;
                    // ctx.elr_el1 = task.context.elr_el1;
                    // ctx.spsr_el1 = task.context.spsr_el1;

                    // asm volatile (
                    //     \\ mov x0, %[val]
                    //     \\ msr tpidr_el1, x0
                    //     :
                    //     : [val] "r" (task.context.tpidr_el1),
                    //     : "x0", "memory"
                    // );

                    // asm volatile (
                    //     \\ mov x0, %[val]
                    //     \\ msr tpidrro_el0, x0
                    //     :
                    //     : [val] "r" (task.context.tpidrro_el0),
                    //     : "x0", "memory"
                    // );

                    // asm volatile (
                    //     \\ mov x0, %[val]
                    //     \\ msr ttbr0_el1, x0
                    //     :
                    //     : [val] "r" (task.thread.process.address_space.root_table_phys),
                    //     : "x0", "memory"
                    // );

                    // mem.virt.flush_all();

                    // set_sp_el0(task.context.sp_el0);

                    // return;
                },
            }
        },
        else => {
            log.err("UNEXPECTED SYNCHRONOUS EXCEPTION from {s}", .{@tagName(ctx.spsr_el1.mode)});
            esr_el1.dump();
        },
    }

    ark.cpu.halt();
}

const gic_v2 = @import("gic_v2.zig");
const timer = @import("timer.zig");

fn irq_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    // Read the interrupt ID from the GICC interface (acknowledge)
    const irq_id = gic_v2.mmio_read(u32, gic_v2.gicc_base + gic_v2.GICC_IAR_OFFSET);

    switch (irq_id) {
        30 => { // generic timer
            log.info("Generic timer IRQ received from {s}", .{@tagName(ctx.spsr_el1.mode)});
            timer.ack();
        },
        1023 => {
            // 0x3FF = spurious interrupt (no valid IRQ pending)
            log.warn("Spurious IRQ received (no valid source)", .{});
        },
        else => {
            log.warn("Unhandled IRQ ID: {}", .{irq_id});
        },
    }

    // Signal End Of Interrupt to the GIC
    gic_v2.mmio_write(u32, gic_v2.gicc_base + gic_v2.GICC_EOIR_OFFSET, irq_id);
}

fn fiq_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    log.err("UNEXPECTED FIQ from {s}", .{@tagName(ctx.spsr_el1.mode)});
    ark.cpu.armv8a_64.registers.ESR_EL1.get().dump();
    ark.cpu.halt();
}

fn serror_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    log.err("UNEXPECTED SERROR from {s}", .{@tagName(ctx.spsr_el1.mode)});
    ark.cpu.armv8a_64.registers.ESR_EL1.get().dump();
    ark.cpu.halt();
}

export const el1t_sync = sync_handler;
export const el1t_irq = irq_handler;
export const el1t_fiq = unexpected_exception;
export const el1t_serror = unexpected_exception;

export const el1h_sync = sync_handler;
export const el1h_irq = irq_handler;
export const el1h_fiq = unexpected_exception;
export const el1h_serror = unexpected_exception;

export const el0_sync = sync_handler;
export const el0_irq = irq_handler;
export const el0_fiq = unexpected_exception;
export const el0_serror = unexpected_exception;

fn unexpected_exception(_: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    log.err("unexpected exception", .{});
    ark.cpu.armv8a_64.registers.ESR_EL1.get().dump();
    ark.cpu.halt();
}

pub const VirtualMemory = struct {

};

pub const Timer = struct {
    pub fn init() void {}
    pub fn set_alarm() void {}
    pub fn cancel() void {}
};

/// If conditions are met, the system will give the quantum asked by the process, 
/// if the system' charge increase the quantum will probably be reduced, the minimum being 1ms.
pub const Quantum = enum {
    /// 1ms
    ultra_light,
    /// 5ms
    light,
    /// 10ms
    moderate,
    /// 50ms
    /// 
    /// Require a permission if used with reactive.
    /// It is impossible to use heavy with realtime.
    heavy,
    /// 100ms
    /// 
    /// Require a permission if not used with normal and reactive.
    /// It is impossible to use ultra_heavy with realtime.
    ultra_heavy,
};

pub const Priority = enum {
    /// Will not be scheduled in order to reduce system charge.
    background,
    /// Guarantee a minimal amount of CPU-time under massive charge.
    normal,
    /// Gives the priority over normal-task, while having the same aspect as normal tasks.
    reactive,
    /// Guarantee that the task is scheduled very often even under massive charge.
    /// 
    /// Whenever a realtime task becomes ready the kernel preempts the currently running task immediately if it is not also a realtime task.
    realtime,
};

/// Precision = min(Precision, Quantum).
/// Under heavy load precision is reduced but not if the task has realtime priority.
pub const Precision = enum {
    /// 10ms
    low,
    /// 5ms
    moderate,
    /// 1ms
    high,
    /// 0.5ms
    realtime,
};

pub const PhysicalMemory = struct {
    const PageLevel = ark.mem.PageLevel;

    var bitmap_4k: []u64 = undefined;
    var bitmap_2m: []u64 = undefined;
    var bitmap_1g: []u64 = undefined;

    var counter_2m: []u16 = undefined;
    var counter_1g: []u16 = undefined;
    var counter_1g_4k: []u32 = undefined;

    var page_count_4k: u64 = 0;
    var page_count_2m: u64 = 0;
    var page_count_1g: u64 = 0;

    var base_usable_address: u64 = 0;
    var max_usable_address: u64 = 0;

    var total_pages: u64 = 0;
    var available_pages: u64 = 0;
    var used_pages: u64 = 0;

    inline fn get_bitmap(level: PageLevel) []u64 {
        return switch (level) {
            .l4K => bitmap_4k,
            .l2M => bitmap_2m,
            .l1G => bitmap_1g,
        };
    }

    inline fn read_bitmap(page_index: u64, level: PageLevel) bool {
        const bitmap = get_bitmap(level);
        const bit_index = page_index % 64;
        const word_index = page_index / 64;
        const word = bitmap[word_index];
        const mask: u64 = @as(u64, 1) << @as(u6, @intCast(bit_index));
        return (word & mask) != 0;
    }

    inline fn write_bitmap(page_index: u64, level: PageLevel, value: bool) void {
        const bitmap = get_bitmap(level);
        const bit_index = page_index % 64;
        const word_index = page_index / 64;

        const mask: u64 = @as(u64, 1) << @as(u6, @intCast(bit_index));
        if (value) {
            bitmap[word_index] |= mask;
        } else {
            bitmap[word_index] &= ~mask;
        }
    }

    pub inline fn available_memory() u64 {
        return available_pages << PageLevel.l4K.shift();
    }

    pub inline fn used_memory() u64 {
        return used_pages << PageLevel.l4K.shift();
    }

    inline fn is_page_used(page_index: u64, level: PageLevel) bool {
        return switch (level) {
            .l1G => read_bitmap(page_index, .l1G),
            .l2M => read_bitmap(page_index, .l2M) or
                (read_bitmap(page_index >> 9, .l1G) and counter_1g[page_index >> 9] == 0),
            .l4K => read_bitmap(page_index, .l4K) or
                (read_bitmap(page_index >> 9, .l2M) and counter_2m[page_index >> 9] == 0) or
                (read_bitmap(page_index >> 18, .l1G) and counter_1g[page_index >> 18] == 0),
        };
    }

    inline fn is_page_available(index: u64, level: PageLevel) bool {
        return !is_page_used(index, level);
    }

    inline fn is_page_primary(page_index: u64, level: PageLevel) bool {
        return switch (level) {
            .l1G => read_bitmap(page_index, .l1G) and counter_1g[page_index] == 0,
            .l2M => read_bitmap(page_index, .l2M) and counter_2m[page_index] == 0,
            .l4K => read_bitmap(page_index, .l4K),
        };
    }

    inline fn is_page_secondary(page_index: u64, level: PageLevel) bool {
        return is_page_used(page_index, level) and !is_page_primary(page_index, level);
    }

    inline fn is_page_sub_available(page_index: u64, level: PageLevel) bool {
        return is_page_available(page_index, level) or is_page_secondary(page_index, level);
    }

    inline fn mark_page(page_index: u64, level: PageLevel) void {
        if (is_page_used(page_index, level)) return;

        const num_4k = level.size() >> 12;
        available_pages -= num_4k;
        used_pages += num_4k;

        var current_level = level;
        var index = page_index;
        while (true) {
            write_bitmap(index, current_level, true);

            const parent_index = index >> 9;

            switch (current_level) {
                .l4K => {
                    counter_2m[parent_index] += 1;
                    counter_1g_4k[parent_index >> 9] += 1;
                    if (counter_2m[parent_index] == 1) {
                        current_level = .l2M;
                        index = parent_index;
                        continue;
                    }
                },
                .l2M => {
                    counter_1g[parent_index] += 1;
                    if (counter_1g[parent_index] == 1) {
                        current_level = .l1G;
                        index = parent_index;
                        continue;
                    }
                },
                .l1G => {},
            }

            break;
        }
    }

    inline fn unmark_page(page_index: u64, level: PageLevel) void {
        if (!is_page_used(page_index, level)) return;
        if (!is_page_primary(page_index, level)) return;

        const num_4k = level.size() >> 12;
        available_pages += num_4k;
        used_pages -= num_4k;

        var current_level = level;
        var index = page_index;
        while (true) {
            write_bitmap(index, current_level, false);

            const parent_index = index >> 9;

            switch (current_level) {
                .l4K => {
                    counter_2m[parent_index] -= 1;
                    counter_1g_4k[parent_index >> 9] -= 1;
                    if (counter_2m[parent_index] == 0) {
                        current_level = .l2M;
                        index = parent_index;
                        continue;
                    }
                },
                .l2M => {
                    counter_1g[parent_index] -= 1;
                    if (counter_1g[parent_index] == 0) {
                        current_level = .l1G;
                        index = parent_index;
                        continue;
                    }
                },
                .l1G => {},
            }

            break;
        }
    }

    pub const AllocError = error{
        OutOfMemory,
        OutOfContiguousMemory,
        InvalidAlignment,
    };

    inline fn check_memory_availability(length: usize, level: PageLevel) AllocError!void {
        const length_4k = switch (level) {
            .l4K => length,
            .l2M => length << 9,
            .l1G => length << 18,
        };

        if (length_4k > available_pages) {
            return AllocError.OutOfMemory;
        }
    }

    inline fn check_alignment(address: u64, level: PageLevel) AllocError!void {
        if (!std.mem.isAligned(address, level.size())) {
            return AllocError.InvalidAlignment;
        }
    }

    pub fn alloc_page(level: PageLevel) AllocError!u64 {
        var pages: [1]u64 = undefined;
        try alloc_noncontiguous_pages(&pages, level);
        return pages[0];
    }

    pub fn free_page(address: u64, level: PageLevel) void {
        unmark_page(address >> level.shift(), level);
    }

    pub fn alloc_noncontiguous_pages(pages: []u64, level: PageLevel) AllocError!void {
        if (pages.len == 0) return;

        try check_memory_availability(pages.len, level);

        var i: usize = 0;

        switch (level) {
            .l1G => {
                for (0..page_count_1g) |page_index| {
                    if (is_page_available(page_index, level)) {
                        mark_page(page_index, level);
                        pages[i] = page_index << level.shift();
                        i += 1;
                        if (i == pages.len) return;
                    }
                }
            },
            .l2M => {
                while (i < pages.len) {
                    var hotspot_max: u64 = 0;
                    var hotspot_index: u64 = 0;
                    var hotspot_set = false;

                    for (0..page_count_1g) |page_index| {
                        const count_2m = counter_1g[page_index];
                        if (count_2m < 512 and (count_2m > hotspot_max or !hotspot_set)) {
                            hotspot_index = page_index;
                            hotspot_max = count_2m;
                            hotspot_set = true;
                        }
                    }

                    if (!hotspot_set) break;

                    for (0..512) |idx| {
                        const page_index = (hotspot_index << 9) | idx;
                        if (is_page_available(page_index, level)) {
                            mark_page(page_index, level);
                            pages[i] = page_index << level.shift();
                            i += 1;
                            if (i == pages.len) return;
                        }
                    }
                }
            },
            .l4K => {
                while (i < pages.len) {
                    var hotspot_max_1g: u64 = 0;
                    var hotspot_index_1g: u64 = 0;
                    var hotspot_set_1g = false;

                    for (0..page_count_1g) |idx| {
                        if (counter_1g_4k[idx] < 512 * 512 and (counter_1g_4k[idx] > hotspot_max_1g or !hotspot_set_1g)) {
                            hotspot_max_1g = counter_1g_4k[idx];
                            hotspot_index_1g = idx;
                            hotspot_set_1g = true;
                        }
                    }

                    if (!hotspot_set_1g) break;

                    while (i < pages.len) {
                        var hotspot_max_2m: u64 = 0;
                        var hotspot_index_2m: u64 = 0;
                        var hotspot_set_2m = false;

                        for (0..512) |idx| {
                            const page_index = (hotspot_index_1g << 9) | idx;
                            if (counter_2m[page_index] < 512 and (counter_2m[page_index] > hotspot_max_2m or !hotspot_set_2m)) {
                                hotspot_max_2m = counter_2m[page_index];
                                hotspot_index_2m = page_index;
                                hotspot_set_2m = true;
                            }
                        }

                        if (!hotspot_set_2m) break;

                        for (0..512) |idx| {
                            const page_index = (hotspot_index_2m << 9) | idx;
                            if (is_page_available(page_index, level)) {
                                mark_page(page_index, level);
                                pages[i] = page_index << level.shift();
                                i += 1;
                                if (i == pages.len) return;
                            }
                        }
                    }
                }
            },
        }

        free_noncontiguous_pages(pages[0..i], level);

        return AllocError.OutOfContiguousMemory;
    }

    pub fn free_noncontiguous_pages(pages: []u64, level: PageLevel) void {
        for (pages) |page_addr| {
            unmark_page(page_addr >> level.shift(), level);
        }
    }

    pub fn alloc_contiguous_pages(length: usize, level: PageLevel, length_align: bool) AllocError!u64 {
        if (length == 0) return 0;

        try check_memory_availability(length, level);

        if (length > 1) {
            // TODO this version is highly unoptimized, doesn't use the counters..

            const page_count = switch (level) {
                .l1G => page_count_1g,
                .l2M => page_count_2m,
                .l4K => page_count_4k,
            };

            var i: usize = 0;
            while (i < page_count) : (i += 1) {
                if (length_align and (i % length != 0)) continue;

                var run: usize = 0;

                while (i + run < page_count and is_page_available(i + run, level)) {
                    run += 1;
                    if (run == length) {
                        for (0..length) |j| {
                            mark_page(i + j, level);
                        }
                        return i << level.shift();
                    }
                }

                i += run;
            }

            return AllocError.OutOfContiguousMemory;
        } else if (length == 1) {
            return alloc_page(level);
        }

        return 0;
    }

    pub fn free_contiguous_pages(address: u64, length: usize, level: PageLevel) void {
        const addr = address >> level.shift();
        var offset: usize = 0;
        while (offset < length) : (offset += 1) {
            unmark_page(addr + offset, level);
        }
    }

    const uefi = std.os.uefi;

    pub const MemoryTable = struct {
        map: *anyopaque,
        map_key: usize,
        map_size: usize,
        descriptor_size: usize,

        pub fn get(self: MemoryTable, index: usize) ?*uefi.tables.MemoryDescriptor {
            const i = self.descriptor_size * index;
            if (i > (self.map_size - self.descriptor_size)) return null;
            return @ptrFromInt(@intFromPtr(self.map) + i);
        }
    };

    pub fn init(
        memory_map: MemoryTable,
    ) !void {
        var i: usize = 0;
        var is_base_set = false;
        while (memory_map.get(i)) |entry| : (i+=1) {
            if (entry.type == .conventional_memory) {
                const original_base = entry.physical_start;
                entry.physical_start = std.mem.alignForward(u64, entry.physical_start, PageLevel.l4K.size());
                var entry_length = entry.number_of_pages << PageLevel.l4K.shift();
                entry_length = entry_length - (entry.physical_start - original_base);
                entry_length = std.mem.alignBackward(u64, entry_length, PageLevel.l4K.size());
                entry.number_of_pages = entry_length >> PageLevel.l4K.shift();

                if (is_base_set) {
                    if (entry.physical_start < base_usable_address) {
                        base_usable_address = entry.physical_start;
                    }
                } else {
                    is_base_set = true;
                    base_usable_address = entry.physical_start;
                }

                const end_addr = entry.physical_start + entry_length;
                if (end_addr > max_usable_address) {
                    max_usable_address = end_addr;
                }
            }
        }

        max_usable_address = std.mem.alignForward(u64, max_usable_address, PageLevel.l1G.size());

        page_count_4k = max_usable_address >> PageLevel.l4K.shift();
        page_count_2m = max_usable_address >> PageLevel.l2M.shift();
        page_count_1g = max_usable_address >> PageLevel.l1G.shift();

        const len_4k = (page_count_4k + 63) / 64;
        const len_2m = (page_count_2m + 63) / 64;
        const len_1g = (page_count_1g + 63) / 64;

        const maps_size = std.mem.alignForward(
            u64,
            len_4k * @sizeOf(u64) +
                len_2m * @sizeOf(u64) +
                len_1g * @sizeOf(u64) +
                page_count_2m * @sizeOf(u16) +
                page_count_1g * @sizeOf(u16) +
                page_count_1g * @sizeOf(u32) +
                @sizeOf(u64) * 6, // headroom for alignment
            PageLevel.l4K.size(),
        ) >> 12;

        i = 0;
        while (memory_map.get(i)) |entry| : (i+=1) {
            if (entry.type == .conventional_memory and entry.number_of_pages > maps_size) {
                var alloc_base = std.mem.alignForward(u64, entry.physical_start, @alignOf(u64));

                bitmap_4k.ptr = @ptrFromInt(hhdm_base + std.mem.alignForward(u64, alloc_base, @alignOf(u64)));
                bitmap_4k.len = len_4k;
                @memset(bitmap_4k, 0xffff_ffff_ffff_ffff);

                alloc_base += bitmap_4k.len * @sizeOf(u64);

                bitmap_2m.ptr = @ptrFromInt(hhdm_base + std.mem.alignForward(u64, alloc_base, @alignOf(u64)));
                bitmap_2m.len = len_2m;
                @memset(bitmap_2m, 0);

                alloc_base += bitmap_2m.len * @sizeOf(u64);

                bitmap_1g.ptr = @ptrFromInt(hhdm_base + std.mem.alignForward(u64, alloc_base, @alignOf(u64)));
                bitmap_1g.len = len_1g;
                @memset(bitmap_1g, 0);

                alloc_base += bitmap_1g.len * @sizeOf(u64);

                counter_2m.ptr = @ptrFromInt(hhdm_base + std.mem.alignForward(u64, alloc_base, @alignOf(u64)));
                counter_2m.len = page_count_2m;
                @memset(counter_2m, 0);

                alloc_base += counter_2m.len * @sizeOf(u16);

                counter_1g.ptr = @ptrFromInt(hhdm_base + std.mem.alignForward(u64, alloc_base, @alignOf(u64)));
                counter_1g.len = page_count_1g;
                @memset(counter_1g, 0);

                alloc_base += counter_1g.len * @sizeOf(u16);

                counter_1g_4k.ptr = @ptrFromInt(hhdm_base + std.mem.alignForward(u64, alloc_base, @alignOf(u64)));
                counter_1g_4k.len = page_count_1g;
                @memset(counter_1g_4k, 0);

                alloc_base += counter_1g_4k.len * @sizeOf(u32);

                const new_base = std.mem.alignForward(u64, alloc_base, PageLevel.l4K.size());
                if (entry.physical_start == base_usable_address) {
                    base_usable_address = new_base;
                }
                entry.number_of_pages = entry.number_of_pages - (std.mem.alignForward(u64, (new_base - entry.physical_start), 0x1000) >> PageLevel.l4K.shift());
                entry.physical_start = new_base;

                break;
            }
        }

        // configure bitmap_4k
        i = 0;
        while (memory_map.get(i)) |entry| : (i+=1) {
            if (entry.type == .conventional_memory) {
                var page_index = entry.physical_start >> PageLevel.l4K.shift();
                const page_end = page_index + entry.number_of_pages;
                while (page_index < page_end) : (page_index += 1) {
                    write_bitmap(page_index, .l4K, false);
                    total_pages += 1;
                }
            }
        }

        available_pages = total_pages;

        // configure counter_2m & bitmap_2m
        for (0..page_count_2m) |page_index_2m| {
            const page_index_1g = page_index_2m >> 9;
            for (0..512) |idx| {
                const page_index_4k = (page_index_2m << 9) | idx;
                const page_used_4k = read_bitmap(page_index_4k, .l4K);
                if (page_used_4k) {
                    counter_2m[page_index_2m] += 1;
                    counter_1g_4k[page_index_1g] += 1;
                }
            }
            if (counter_2m[page_index_2m] > 0) write_bitmap(page_index_2m, .l2M, true);
        }

        // configure counter_1g & bitmap_1g
        for (0..page_count_1g) |page_index_1g| {
            for (0..512) |idx| {
                const page_index_2m = (page_index_1g << 9) | idx;
                const page_used_2m = read_bitmap(page_index_2m, .l2M);
                if (page_used_2m) counter_1g[page_index_1g] += 1;
            }
            if (counter_1g[page_index_1g] > 0) write_bitmap(page_index_1g, .l1G, true);
        }
    }
};
