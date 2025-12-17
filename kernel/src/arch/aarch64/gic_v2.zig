// Copyright (c) 2024-2025 The violetOS authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// --- dependencies --- //

const std = @import("std");
const ark = @import("ark");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const phys = mem.phys;
const vmm = mem.vmm;

const acpi = kernel.drivers.acpi;

const gic = @import("gic.zig");

// --- aarch64/gic_v2.zig --- //

const MAX_IRQS = 1020;

const GICD_SIZE = 0x10000;
const GICC_SIZE = 0x2000;

var gicd_base: u64 = undefined;
var gicc_base: [128]u64 = undefined;

pub fn init() !void {
    var xsdt_iter = kernel.boot.xsdt.iter();
    xsdt_loop: while (xsdt_iter.next()) |xsdt_entry| {
        switch (xsdt_entry) {
            .madt => |madt| {
                var madt_iter = madt.iter();
                while (madt_iter.next()) |madt_entry| {
                    switch (madt_entry) {
                        .gicd => |gicd| {
                            const virtual_address = try vmm.kernel_space.allocator.alloc(GICD_SIZE, 0, null, 0, null, true);
                            const page_count = GICD_SIZE >> 12;

                            try vmm.kernel_space.paging.map(
                                virtual_address,
                                gicd.address,
                                page_count,
                                .l4K,
                                .{ .type = .device, .writable = true },
                            );

                            gicd_base = virtual_address;

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

    enableDistributor();
}

// --- GIC Distributor --- //

const GICD_CTLR = 0x000;

pub fn enableDistributor() void {
    const ctlr: *volatile u32 = @ptrFromInt(gicd_base + GICD_CTLR);

    ctlr.* = 1;
    asm volatile ("dsb sy" ::: "memory");

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

pub fn configure(irq: u32, trigger_mode: gic.TriggerMode, polarity: gic.Polarity) void {
    _ = polarity;

    const reg_index = irq / 16;
    const bit_shift = (irq % 16) * 2 + 1;

    const icfgr: *volatile u32 = @ptrFromInt(gicd_base + GICD_ICFGRn + (reg_index * 4));

    var val = icfgr.*;

    val &= ~(@as(u32, 1) << @intCast(bit_shift));

    if (trigger_mode == .edge) {
        val |= (@as(u32, 1) << @intCast(bit_shift));
    }

    icfgr.* = val;
}

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

pub fn initCpu() !void {
    const interface_number = getInterfaceNumber();

    var xsdt_iter = kernel.boot.xsdt.iter();
    xsdt_loop: while (xsdt_iter.next()) |xsdt_entry| {
        switch (xsdt_entry) {
            .madt => |madt| {
                var madt_iter = madt.iter();
                while (madt_iter.next()) |madt_entry| {
                    switch (madt_entry) {
                        .gicc => |gicc| {
                            if (gicc.interface_number == interface_number) {
                                const virtual_address = try vmm.kernel_space.allocator.alloc(GICC_SIZE, 0, null, 0, null, true);
                                const page_count = GICC_SIZE >> 12;

                                try vmm.kernel_space.paging.map(
                                    virtual_address,
                                    gicc.address,
                                    page_count,
                                    .l4K,
                                    .{ .type = .device, .writable = true },
                                );

                                gicc_base[interface_number] = virtual_address;

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

    @as(*volatile u32, @ptrFromInt(gicc_base_addr + GICC_PMR)).* = 0xf0;
    asm volatile ("dsb sy" ::: "memory");

    const igroupr0: *volatile u32 = @ptrFromInt(gicd_base + GICD_IGROUPRn);
    igroupr0.* |= 0x0000FFFF;

    const isenabler0: *volatile u32 = @ptrFromInt(gicd_base + GICD_ISENABLERn);
    isenabler0.* |= 0x0000FFFF;

    for (0..16) |i| {
        setPriority(@intCast(i), 0x0);
    }

    @as(*volatile u32, @ptrFromInt(gicc_base_addr + GICC_CTLR)).* = 0x1;
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

pub fn setPriority(irq: u32, priority: u8) void {
    const offset = (irq / 4) * 4;
    const shift = (irq % 4) * 8;
    const ipriorityr: *volatile u32 = @ptrFromInt(gicd_base + GICD_IPRIORITYRn + offset);

    var val = ipriorityr.*;
    val &= ~(@as(u32, 0xFF) << @intCast(shift));
    val |= (@as(u32, priority) << @intCast(shift));
    ipriorityr.* = val;
}

const GICD_SGIR = 0xF00;

pub fn sendIPI(target_cpu_id: u32, vector: u32) void {
    if (vector > 15) @panic("SGI vector > 15");

    const nsatt: u32 = 1 << 15;

    const target_list = @as(u32, 1) << @intCast(target_cpu_id);
    const val: u32 = (target_list << 16) | nsatt | vector;

    const sgir: *volatile u32 = @ptrFromInt(gicd_base + GICD_SGIR);
    sgir.* = val;
    asm volatile ("dsb sy" ::: "memory");
}
