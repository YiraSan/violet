// --- dependencies --- //

const std = @import("std");
const ark = @import("ark");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const phys = mem.phys;
const virt = mem.virt;

const acpi = kernel.drivers.acpi;

// --- MMIO accessors --- //

fn mmio_read(comptime T: type, address: usize) T {
    const ptr = @as(*volatile T, @ptrFromInt(address));
    return @atomicLoad(T, ptr, .acquire);
}

fn mmio_write(comptime T: type, address: usize, data: T) void {
    const ptr = @as(*volatile T, @ptrFromInt(address));
    @atomicStore(T, ptr, data, .release);
}

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

                            virt.flush(gicd_base);

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
    mmio_write(u32, gicd_base + GICD_CTLR, 1);

    // Wait until the distributor is enabled
    while ((mmio_read(u32, gicd_base + GICD_CTLR) & 0x1) == 0) {}
}

pub fn disableDistributor() void {
    mmio_write(u32, gicd_base + GICD_CTLR, 0);
}

const GICD_TYPER = 0x004;
const GICD_IIDR = 0x008;
const GICD_IGROUPRn = 0x080;

const GICD_ISENABLERn = 0x100;

pub fn enableIRQ(irq: u32) void {
    const offset = (irq / 32) * 4;
    const bit = irq % 32;

    mmio_write(u32, gicd_base + GICD_ISENABLERn + offset, (@as(u32, 1) << @intCast(bit)));
}

const GICD_ICENABLERn = 0x180;

pub fn disableIRQ(irq: u32) void {
    const offset = (irq / 32) * 4;
    const bit = irq % 32;

    mmio_write(u32, gicd_base + GICD_ICENABLERn + offset, (@as(u32, 1) << @intCast(bit)));
}

/// Because cpu wakeups probably uses SGIs.
fn disableAllExceptSGI() void {
    var irq: usize = 16;
    while (irq < MAX_IRQS) : (irq += 32) {
        const offset_bytes = (irq / 32) * 4;
        var mask: u32 = 0xffffffff;
        if (irq == 16) mask = 0xffff0000;

        mmio_write(u32, gicd_base + GICD_ICENABLERn + offset_bytes, mask);
    }
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
    const mpidr_el1 = ark.cpu.armv8a_64.registers.MPIDR_EL1.get();
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

                                virt.flush(gicc_base[interface_number]);

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

    // Set minimum interrupt priority (lower value = higher priority)
    mmio_write(u32, gicc_base[interface_number] + GICC_PMR, 0xF0);

    // Enable Group 0 and Group 1 interrupts
    mmio_write(u32, gicc_base[interface_number] + GICC_CTLR, 1 | (1 << 1));

    // Wait for the CPU interface to become active
    while ((mmio_read(u32, gicc_base[interface_number] + GICC_CTLR) & 0x3) != 0x3) {}
}

pub fn acknowledge() u32 {
    const interface_number = getInterfaceNumber();
    return mmio_read(u32, gicc_base[interface_number] + GICC_IAR);
}

pub fn endOfInterrupt(irq_id: u32) void {
    const interface_number = getInterfaceNumber();
    mmio_write(u32, gicc_base[interface_number] + GICC_EOIR, irq_id);
}
