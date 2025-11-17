// --- dependencies --- //

const std = @import("std");
const ark = @import("ark");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const phys = mem.phys;
const virt = mem.virt;

const acpi = kernel.drivers.acpi;

// --- aarch64/gic_v2.zig --- //

const MAX_IRQS = 1020;

const GICD_SIZE = 0x10000;
const GICC_SIZE = 0x1000;

var gicd_base: u64 = undefined;
var gicc_base: [128]u64 = undefined;

pub fn init(xsdt: *acpi.Xsdt) !void {
    var xsdt_iter = xsdt.iter();
    xsdt_loop: while (xsdt_iter.next()) |xsdt_entry| {
        switch (xsdt_entry) {
            .madt => |madt| {
                var madt_iter = madt.iter();
                while (madt_iter.next()) |madt_entry| {
                    switch (madt_entry) {
                        .gicd => |gicd| {
                            const reservation = virt.kernel_space.reserve(GICD_SIZE >> 12);

                            reservation.map(gicd.address, .{
                                .device = true,
                                .writable = true,
                            }, .no_hint);

                            gicd_base = reservation.address();

                            break :xsdt_loop;
                        },
                        else => {},
                    }
                }

                @panic("No GICD found.");
            },
            else => {},
        }
    }

    disableDistributor();

    disableAllExceptSGI();

    // // Route SPIs (>=32) to CPU0 (not required for PPIs)
    // i = 32;
    // while (i < 64) : (i += 4) {
    //     mmio_write(u32, gicd_base + 0x800 + i, 0x01010101); // GICD_ITARGETSRn
    // }

    enableDistributor();
}

// --- GIC Distributor --- //

const GICD_CTLR = 0x000;

pub fn enableDistributor() void {
    const ctlr: *volatile u32 = @ptrFromInt(gicd_base + GICD_CTLR);

    ctlr.* = 1;

    asm volatile ("dsb sy" ::: "memory");

    // Wait until the distributor is enabled
    while ((ctlr.* & 0x1) == 0) {}

    asm volatile ("dsb sy" ::: "memory");
}

pub fn disableDistributor() void {
    const ctlr: *volatile u32 = @ptrFromInt(gicd_base + GICD_CTLR);

    ctlr.* = 0;

    asm volatile ("dsb sy" ::: "memory");
}

const GICD_TYPER = 0x004;
const GICD_IIDR = 0x008;
const GICD_IGROUPRn = 0x080;

const GICD_ISENABLERn = 0x100;

pub fn enableIRQ(irq: u32) void {
    const offset = (irq / 32) * 4;
    const bit = irq % 32;

    const isenabler: *volatile u32 = @ptrFromInt(gicd_base + GICD_ISENABLERn + offset);

    isenabler.* = @as(u32, 1) << @intCast(bit);

    asm volatile ("dsb sy" ::: "memory");
}

const GICD_ICENABLERn = 0x180;

pub fn disableIRQ(irq: u32) void {
    const offset = (irq / 32) * 4;
    const bit = irq % 32;

    const icenabler: *volatile u32 = @ptrFromInt(gicd_base + GICD_ICENABLERn + offset);

    icenabler.* = @as(u32, 1) << @intCast(bit);

    asm volatile ("dsb sy" ::: "memory");
}

/// Because cpu wakeups probably uses SGIs.
fn disableAllExceptSGI() void {
    var irq: usize = 16;
    while (irq < MAX_IRQS) : (irq += 32) {
        const offset = (irq / 32) * 4;
        var mask: u32 = 0xffffffff;
        if (irq == 16) mask = 0xffff0000;

        const icenabler: *volatile u32 = @ptrFromInt(gicd_base + GICD_ICENABLERn + offset);

        icenabler.* = mask;
    }

    asm volatile ("dsb sy" ::: "memory");
}

const GICD_ISPENDRn = 0x200;
const GICD_ICPENDRn = 0x280;
const GICD_ISACTIVERn = 0x300;
const GICD_ICACTIVERn = 0x380;
const GICD_IPRIORITYRn = 0x400;
const GICD_ITARGETSRn = 0x800;
const GICD_ICFGRn = 0xC00;

// --- GIC CPU --- //

const GICC_CTLR = 0x000;
const GICC_PMR = 0x004;
const GICC_BPR = 0x008;
const GICC_IAR = 0x00C;
const GICC_EOIR = 0x010;
const GICC_RPR = 0x014;
const GICC_HPPIR = 0x018;
const GICC_ABPR = 0x01C;
const GICC_AIAR = 0x020;
const GICC_AEOIR = 0x024;

fn getInterfaceNumber() u32 {
    const mpidr_el1 = ark.armv8.registers.MPIDR_EL1.load();
    const interface_number =
        @as(u32, @intCast(mpidr_el1.aff0)) |
        (@as(u32, @intCast(mpidr_el1.aff1)) << 8) |
        (@as(u32, @intCast(mpidr_el1.aff2)) << 16) |
        (@as(u32, @intCast(mpidr_el1.aff3)) << 24);

    return interface_number;
}

pub fn initCpu(xsdt: *acpi.Xsdt) !void {
    const interface_number = getInterfaceNumber();

    var xsdt_iter = xsdt.iter();
    xsdt_loop: while (xsdt_iter.next()) |xsdt_entry| {
        switch (xsdt_entry) {
            .madt => |madt| {
                var madt_iter = madt.iter();
                while (madt_iter.next()) |madt_entry| {
                    switch (madt_entry) {
                        .gicc => |gicc| {
                            if (gicc.interface_number == interface_number) {
                                const reservation = virt.kernel_space.reserve(GICC_SIZE >> 12);

                                reservation.map(gicc.address, .{
                                    .device = true,
                                    .writable = true,
                                }, .no_hint);

                                gicc_base[interface_number] = reservation.address();

                                break :xsdt_loop;
                            }
                        },
                        else => {},
                    }
                }

                @panic("No GICC found.");
            },
            else => {},
        }
    }

    const gicc_base_addr = gicc_base[interface_number];

    // Set minimum interrupt priority (lower value = higher priority)
    @as(*volatile u32, @ptrFromInt(gicc_base_addr + GICC_PMR)).* = 0xf0;

    asm volatile ("dsb sy" ::: "memory");

    // Enable Group 0 and Group 1 interrupts
    @as(*volatile u32, @ptrFromInt(gicc_base_addr + GICC_CTLR)).* = 1;

    asm volatile ("dsb sy" ::: "memory");
}

pub fn acknowledge() u32 {
    const interface_number = getInterfaceNumber();
    return @as(*volatile u32, @ptrFromInt(gicc_base[interface_number] + GICC_IAR)).*;
}

pub fn endOfInterrupt(irq_id: u32) void {
    const interface_number = getInterfaceNumber();
    @as(*volatile u32, @ptrFromInt(gicc_base[interface_number] + GICC_EOIR)).* = irq_id;
}
