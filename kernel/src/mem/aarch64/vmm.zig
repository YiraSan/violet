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

const Entry = ark.armv8.stage1_pagging.Entry;
const TableDescriptor = ark.armv8.stage1_pagging.TableDescriptor;
const BlockPageDescriptor = ark.armv8.stage1_pagging.BlockPageDescriptor;

// --- imports --- //

const kernel = @import("root");

const boot = kernel.boot;
const mem = kernel.mem;

const phys = mem.phys;
const vmm = mem.vmm;

// --- aarch64/vmm.zig --- //

pub fn init() !void {
    vmm.kernel_space = try .init(.higher, ark.armv8.registers.loadTtbr1El1(), false);
}

pub fn invalidate(address: u64, level: mem.PageLevel) void {
    asm volatile ("dsb ishst");

    const va = address >> 12;

    switch (level) {
        .l4K => asm volatile (
            \\ tlbi vae1is, %[va]
            :
            : [va] "r" (va),
            : "memory"
        ),
        .l2M, .l1G => asm volatile (
            \\ tlbi vale1is, %[va]
            :
            : [va] "r" (va),
            : "memory"
        ),
    }

    asm volatile (
        \\ dsb ish
        \\ isb
    );
}

pub fn invalidateGlobalTLB() void {
    asm volatile (
        \\ dsb ishst
        \\ tlbi vmalle1is
        \\ dsb ish
        \\ isb
        ::: "memory");
}

pub fn invalidateLocalTLB() void {
    asm volatile (
        \\ dsb nshst
        \\ tlbi vmalle1
        \\ dsb nsh
        \\ isb
        ::: "memory");
}

pub fn mapPage(
    l0_table: u64,
    virtual_address: u64,
    physical_address: u64,
    page_level: mem.PageLevel,
    flags: vmm.Paging.Flags,
) !void {
    const l0_index = (virtual_address >> 39) & 0x1FF;
    const l1_index = (virtual_address >> 30) & 0x1FF;
    const l2_index = (virtual_address >> 21) & 0x1FF;
    const l3_index = (virtual_address >> 12) & 0x1FF;

    const descriptor = buildDescriptor(physical_address, flags);

    const l1_table = try ensureTable(l0_table, l0_index);
    if (page_level == .l1G) {
        const l1_entry = pruneAndGetEntry(l1_table, l1_index, .l1G);

        if (l1_entry.valid) {
            l1_entry.valid = false;
            invalidate(virtual_address, .l1G);
        }

        l1_entry.* = .{
            .valid = true,
            .not_a_block = false,
            .descriptor = .{
                .block_page = descriptor,
            },
        };

        return;
    }

    const l2_table = try ensureTable(l1_table, l1_index);
    if (page_level == .l2M) {
        const l2_entry = pruneAndGetEntry(l2_table, l2_index, .l2M);

        if (l2_entry.valid) {
            l2_entry.valid = false;
            invalidate(virtual_address, .l2M);
        }

        l2_entry.* = .{
            .valid = true,
            .not_a_block = false,
            .descriptor = .{
                .block_page = descriptor,
            },
        };
        return;
    }

    const l3_table = try ensureTable(l2_table, l2_index);
    const l3_entry = pruneAndGetEntry(l3_table, l3_index, .l4K);

    if (l3_entry.valid) {
        l3_entry.valid = false;
        invalidate(virtual_address, .l4K);
    }

    l3_entry.* = .{
        .valid = true,
        .not_a_block = true,
        .descriptor = .{
            .block_page = descriptor,
        },
    };
}

pub fn unmapPage(
    l0_table: u64,
    virtual_address: u64,
) void {
    const l0_index = (virtual_address >> 39) & 0x1FF;
    const l1_index = (virtual_address >> 30) & 0x1FF;
    const l2_index = (virtual_address >> 21) & 0x1FF;
    const l3_index = (virtual_address >> 12) & 0x1FF;

    const l0_entry: *Entry = @ptrFromInt(boot.hhdm_base + l0_table + l0_index * 8);
    if (!l0_entry.valid) return;
    if (!l0_entry.not_a_block) unreachable; // should not be possible since 512 GiB allocation is not permitted.

    const l1_table: u64 = l0_entry.descriptor.table.next_level_table << 12;
    const l1_entry: *Entry = @ptrFromInt(boot.hhdm_base + l1_table + l1_index * 8);
    if (!l1_entry.valid) return;

    if (!l1_entry.not_a_block) {
        l1_entry.valid = false;
        invalidate(virtual_address, .l1G);
        return;
    }

    const l2_table: u64 = l1_entry.descriptor.table.next_level_table << 12;
    const l2_entry: *Entry = @ptrFromInt(boot.hhdm_base + l2_table + l2_index * 8);
    if (!l2_entry.valid) return;

    if (!l2_entry.not_a_block) {
        l2_entry.valid = false;
        invalidate(virtual_address, .l2M);
        return;
    }

    const l3_table: u64 = l2_entry.descriptor.table.next_level_table << 12;
    const l3_entry: *Entry = @ptrFromInt(boot.hhdm_base + l3_table + l3_index * 8);
    if (!l3_entry.valid) return;
    l3_entry.valid = false;
    invalidate(virtual_address, .l4K);
}

pub fn getPage(
    l0_table: u64,
    virt_addr: u64,
) ?vmm.Paging.Mapping {
    const l0_index = (virt_addr >> 39) & 0x1FF;
    const l1_index = (virt_addr >> 30) & 0x1FF;
    const l2_index = (virt_addr >> 21) & 0x1FF;
    const l3_index = (virt_addr >> 12) & 0x1FF;

    const l0_entry: *Entry = @ptrFromInt(boot.hhdm_base + l0_table + l0_index * 8);
    if (!l0_entry.valid) return null;
    if (!l0_entry.not_a_block) unreachable; // should not be possible since 512 GiB allocation is not permitted.

    const l1_table: u64 = l0_entry.descriptor.table.next_level_table << 12;
    const l1_entry: *Entry = @ptrFromInt(boot.hhdm_base + l1_table + l1_index * 8);
    if (!l1_entry.valid) return null;

    // 1 GiB page
    if (!l1_entry.not_a_block) {
        return .{
            .phys_addr = l1_entry.descriptor.block_page.output_address << 12,
        };
    }

    const l2_table: u64 = l1_entry.descriptor.table.next_level_table << 12;
    const l2_entry: *Entry = @ptrFromInt(boot.hhdm_base + l2_table + l2_index * 8);
    if (!l2_entry.valid) return null;

    // 2 MiB page
    if (!l2_entry.not_a_block) {
        return .{
            .phys_addr = l2_entry.descriptor.block_page.output_address << 12,
        };
    }

    // 4 KiB page
    const l3_table: u64 = l2_entry.descriptor.table.next_level_table << 12;
    const l3_entry: *Entry = @ptrFromInt(boot.hhdm_base + l3_table + l3_index * 8);
    if (!l3_entry.valid) return null;

    return .{
        .phys_addr = l3_entry.descriptor.block_page.output_address << 12,
    };
}

fn ensureTable(table_phys: u64, index: u64) !u64 {
    const entry: *Entry = @ptrFromInt(boot.hhdm_base + table_phys + index * 8);

    if (entry.valid) {
        if (entry.not_a_block) {
            return entry.descriptor.table.next_level_table << 12;
        } else {
            // overwritten a block with a table
        }
    }

    const new_table = try phys.allocPage(true);

    entry.* = Entry{
        .valid = true,
        .not_a_block = true,
        .descriptor = .{
            .table = .{
                .next_level_table = @truncate(new_table >> 12),
            },
        },
    };

    return new_table;
}

fn pruneAndGetEntry(table_phys: u64, index: u64, level: mem.PageLevel) *Entry {
    const entry: *Entry = @ptrFromInt(boot.hhdm_base + table_phys + index * 8);

    if (entry.valid and entry.not_a_block) {
        if (level == .l1G) {
            freeTable(entry.descriptor.table.next_level_table << 12, 1);
        } else if (level == .l2M) {
            freeTable(entry.descriptor.table.next_level_table << 12, 2);
        }
    }

    return entry;
}

pub fn freeTable(table_phys: u64, level: u8) void {
    _ = table_phys;
    _ = level;

    // TODO ...
}

fn buildDescriptor(physical_address: u64, flags: vmm.Paging.Flags) BlockPageDescriptor {
    var descriptor = BlockPageDescriptor{
        .attr_index = switch (flags.type) {
            .device => .device,
            .non_cacheable => .non_cacheable,
            .writeback => .writeback,
            .writethrough => .writethrough,
        },
        .output_address = @truncate(physical_address >> 12),
        .access_flag = true,
        .shareability = switch (flags.shareability) {
            .strong => .outer_shareable,
            .balanced => .inner_shareable,
            .local => .non_shareable,
        },
        .not_global = flags.user,
    };

    var permission_indirection = false;
    const idmm3 = ark.armv8.registers.ID_AA64MMFR3_EL1.load();
    if (idmm3.s1pie == .supported) {
        const tcr2 = ark.armv8.registers.TCR2_EL1.load();
        if (tcr2.pie) {
            permission_indirection = true;
        }
    }

    if (!permission_indirection) {
        if (!flags.executable) {
            descriptor.b53.pxn = true;
            descriptor.b54.uxn = true;
        }

        if (flags.user) {
            if (flags.writable) {
                descriptor.permissions.direct = .priv_rw_unp_rw;
            } else {
                descriptor.permissions.direct = .priv_rw_unp_ro;
            }
        } else {
            descriptor.b54.uxn = true;

            if (flags.writable) {
                descriptor.permissions.direct = .priv_rw;
            } else {
                descriptor.permissions.direct = .priv_ro;
            }
        }
    } else {
        @panic("mapPage: permission indirection is not supported.");
    }

    return descriptor;
}
