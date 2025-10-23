// --- imports --- //

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const ark = @import("ark");

const kernel = @import("root");

const timer = @import("timer.zig");

// --- MMIO base addresses --- //

const GICD_PHYS_BASE = switch (build_options.platform) {
    .aarch64_qemu => 0x08000000,
    else => unreachable,
};

const GICC_PHYS_BASE = switch (build_options.platform) {
    .aarch64_qemu => 0x08010000,
    else => unreachable,
};

const GICD_SIZE = 0x10000;
const GICC_SIZE = 0x1000;

pub var gicd_base: u64 = undefined;
pub var gicc_base: u64 = undefined;

pub const GICC_IAR_OFFSET = 0x0C;
pub const GICC_EOIR_OFFSET = 0x10;

// --- MMIO accessors --- //

pub fn mmio_read(comptime T: type, address: usize) T {
    const ptr = @as(*volatile T, @ptrFromInt(address));
    return @atomicLoad(T, ptr, .acquire);
}

pub fn mmio_write(comptime T: type, address: usize, data: T) void {
    const ptr = @as(*volatile T, @ptrFromInt(address));
    @atomicStore(T, ptr, data, .release);
}

// --- gic_v2.zig --- //

pub fn init() void {
    const page_level = ark.mem.PageLevel.l4K;
    const num_pages = (GICD_SIZE + GICC_SIZE) >> page_level.shift();
    const range = kernel.vm.kernel_space.reserve(num_pages);

    range.map_contiguous(kernel.page_allocator, GICD_PHYS_BASE, .{
        .device = true,
        .writable = true,
    });

    const base = range.address();

    ark.cpu.armv8a_64.pagging.flush(base);

    gicd_base = base;
    gicc_base = base + GICD_SIZE;

    init_dist();
    init_cpu();

    timer.init();

    asm volatile ("msr DAIFClr, #0b1111");
    asm volatile ("isb");
}

// --- GIC Distributor (global) --- //

fn init_dist() void {
    // Disable Distributor (GICD_CTLR)
    mmio_write(u32, gicd_base + 0x000, 0);

    // Enable SGIs and PPIs if needed (IRQ 0-31)
    // SGI (0–15) typically already enabled, PPIs (16–31) can be set here if needed

    // Enable IRQ 30 (Generic Timer CNTP, PPI)
    mmio_write(u32, gicd_base + 0x100, (1 << 30)); // GICD_ISENABLER0

    // Enable IRQs 32–63 for devices
    var i: usize = 32;
    while (i < 64) : (i += 4) {
        mmio_write(u32, gicd_base + 0x100 + i, 0xFFFFFFFF);
    }

    // Route SPIs (>=32) to CPU0 (not required for PPIs)
    i = 32;
    while (i < 64) : (i += 4) {
        mmio_write(u32, gicd_base + 0x800 + i, 0x01010101); // GICD_ITARGETSRn
    }

    // Enable Distributor
    mmio_write(u32, gicd_base + 0x000, 1);

    // Wait until the distributor is enabled
    while ((mmio_read(u32, gicd_base + 0x000) & 0x1) == 0) {}
}

// --- GIC CPU interface (per-core) --- //

fn init_cpu() void {
    // Set minimum interrupt priority (lower value = higher priority)
    mmio_write(u32, gicc_base + 0x004, 0xF0); // GICC_PMR

    // Enable Group 0 and Group 1 interrupts (GICC_CTLR)
    mmio_write(u32, gicc_base + 0x000, 1 | (1 << 1));

    // Wait for the CPU interface to become active
    while ((mmio_read(u32, gicc_base + 0x000) & 0x3) != 0x3) {}
}
