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
const builtin = @import("builtin");
const ark = @import("ark");

const Entry = ark.armv8.stage1_pagging.Entry;
const TableDescriptor = ark.armv8.stage1_pagging.TableDescriptor;
const BlockPageDescriptor = ark.armv8.stage1_pagging.BlockPageDescriptor;

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const phys = mem.phys;
const virt = mem.virt;

// --- mem/virt.zig --- //

pub fn init() !void {
    virt.kernel_space = .init(.higher, switch (builtin.cpu.arch) {
        .aarch64 => ark.armv8.registers.loadTtbr1El1(),
        else => unreachable,
    });

    virt.kernel_space.last_addr = kernel.boot.hhdm_limit;
}

pub fn applySpace(space: *virt.Space) void {
    ark.armv8.registers.storeTtbr0El1(space.l0_table);
    // TODO check if TTBR0 is enabled, if not, enable it in TCR
    flushAll();
}

pub fn flush(virt_addr: u64, page_level: mem.PageLevel) void {
    switch (page_level) {
        .l4K => {
            const va = virt_addr >> mem.PageLevel.l4K.shift();

            asm volatile (
                \\ tlbi vae1is, %[va]
                \\ dsb ish
                \\ isb
                :
                : [va] "r" (va),
                : "memory"
            );
        },
        .l2M => {
            const va = virt_addr >> mem.PageLevel.l2M.shift();

            asm volatile (
                \\ tlbi vale1is, %[va]
                \\ dsb ish
                \\ isb
                :
                : [va] "r" (va),
                : "memory"
            );
        },
        .l1G => {
            const va = virt_addr >> mem.PageLevel.l1G.shift();

            asm volatile (
                \\ tlbi vale1is, %[va]
                \\ dsb ish
                \\ isb
                :
                : [va] "r" (va),
                : "memory"
            );
        },
    }
}

pub fn flushAll() void {
    asm volatile (
        \\ dsb ish
        \\ tlbi vmalle1
        \\ dsb ish
        \\ isb
        ::: "memory");
}

pub fn mapPage(
    space: *virt.Space,
    virt_addr: u64,
    phys_addr: u64,
    page_level: mem.PageLevel,
    flags: virt.MemoryFlags,
    hint: virt.MappingHint,
) void {
    const l0 = (virt_addr >> 39) & 0x1FF;
    const l1 = (virt_addr >> 30) & 0x1FF;
    const l2 = (virt_addr >> 21) & 0x1FF;
    const l3 = (virt_addr >> 12) & 0x1FF;

    const bpd = BlockPageDescriptor.build(phys_addr, flags, @intFromEnum(hint));

    var tp = space.l0_table;
    tp = ensure_table(tp, l0);

    switch (page_level) {
        .l1G => {
            const p: *Entry = @ptrFromInt(kernel.boot.hhdm_base + tp + l1 * 8);
            if (p.valid and p.not_a_block) {
                free_table_recursive(p.descriptor.table.next_level_table << 12, 1);
            }

            p.* = .{
                .valid = true,
                .not_a_block = false,
                .descriptor = .{
                    .block_page = bpd,
                },
            };
        },
        .l2M => {
            tp = ensure_table(tp, l1);
            const p: *Entry = @ptrFromInt(kernel.boot.hhdm_base + tp + l2 * 8);
            if (p.valid and p.not_a_block) {
                free_table_recursive(p.descriptor.table.next_level_table << 12, 2);
            }

            p.* = .{
                .valid = true,
                .not_a_block = false,
                .descriptor = .{
                    .block_page = bpd,
                },
            };
        },
        .l4K => {
            tp = ensure_table(tp, l1);
            tp = ensure_table(tp, l2);
            const p: *Entry = @ptrFromInt(kernel.boot.hhdm_base + tp + l3 * 8);

            p.* = .{
                .valid = true,
                .not_a_block = true,
                .descriptor = .{
                    .block_page = bpd,
                },
            };
        },
    }

    asm volatile (
        \\ dsb sy
        \\ isb
    );
}

/// Returns current state of a page, `null` if there's no mapping.
pub fn getPage(
    space: *virt.Space,
    virt_addr: u64,
) ?virt.Mapping {
    const l0_index = (virt_addr >> 39) & 0x1FF;
    const l1_index = (virt_addr >> 30) & 0x1FF;
    const l2_index = (virt_addr >> 21) & 0x1FF;
    const l3_index = (virt_addr >> 12) & 0x1FF;

    const l0_entry: *Entry = @ptrFromInt(kernel.boot.hhdm_base + space.l0_table + l0_index * 8);
    if (!l0_entry.valid) return null;
    if (!l0_entry.not_a_block) unreachable; // should not be possible since 512 GiB allocation is not permitted.

    const l1_table: u64 = l0_entry.descriptor.table.next_level_table << 12;
    const l1_entry: *Entry = @ptrFromInt(kernel.boot.hhdm_base + l1_table + l1_index * 8);
    if (!l1_entry.valid) return null;

    // 1 GiB page
    if (!l1_entry.not_a_block) {
        var mapping = getPageMapping(l1_entry);
        mapping.level = .l1G;
        return mapping;
    }

    const l2_table: u64 = l1_entry.descriptor.table.next_level_table << 12;
    const l2_entry: *Entry = @ptrFromInt(kernel.boot.hhdm_base + l2_table + l2_index * 8);
    if (!l2_entry.valid) return null;

    // 2 MiB page
    if (!l2_entry.not_a_block) {
        var mapping = getPageMapping(l2_entry);
        mapping.level = .l2M;
        return mapping;
    }

    // 4 KiB page
    const l3_table: u64 = l2_entry.descriptor.table.next_level_table << 12;
    const l3_entry: *Entry = @ptrFromInt(kernel.boot.hhdm_base + l3_table + l3_index * 8);
    if (!l3_entry.valid) return null;

    var mapping = getPageMapping(l3_entry);
    mapping.level = .l4K;
    return mapping;
}

/// Returns `null` if no modification has been made.
pub fn setPage(
    space: *virt.Space,
    virt_addr: u64,
    mapping: virt.Mapping,
) ?void {
    const l0_index = (virt_addr >> 39) & 0x1FF;
    const l1_index = (virt_addr >> 30) & 0x1FF;
    const l2_index = (virt_addr >> 21) & 0x1FF;
    const l3_index = (virt_addr >> 12) & 0x1FF;

    const l0_entry: *Entry = @ptrFromInt(kernel.boot.hhdm_base + space.l0_table + l0_index * 8);
    if (!l0_entry.valid) return null;
    if (!l0_entry.not_a_block) unreachable; // should not be possible since 512 GiB allocation is not permitted.

    const l1_table: u64 = l0_entry.descriptor.table.next_level_table << 12;
    const l1_entry: *Entry = @ptrFromInt(kernel.boot.hhdm_base + l1_table + l1_index * 8);
    if (!l1_entry.valid) return null;

    // 1 GiB page
    if (!l1_entry.not_a_block) {
        setPageMapping(l1_entry, mapping);
        return;
    }

    const l2_table: u64 = l1_entry.descriptor.table.next_level_table << 12;
    const l2_entry: *Entry = @ptrFromInt(kernel.boot.hhdm_base + l2_table + l2_index * 8);
    if (!l2_entry.valid) return null;

    // 2 MiB page
    if (!l2_entry.not_a_block) {
        setPageMapping(l2_entry, mapping);
        return;
    }

    // 4 KiB page
    const l3_table: u64 = l2_entry.descriptor.table.next_level_table << 12;
    const l3_entry: *Entry = @ptrFromInt(kernel.boot.hhdm_base + l3_table + l3_index * 8);
    if (!l3_entry.valid) return null;
    setPageMapping(l3_entry, mapping);
}

pub fn unmapPage(
    space: *virt.Space,
    virt_addr: u64,
) void {
    const l0_index = (virt_addr >> 39) & 0x1FF;
    const l1_index = (virt_addr >> 30) & 0x1FF;
    const l2_index = (virt_addr >> 21) & 0x1FF;
    const l3_index = (virt_addr >> 12) & 0x1FF;

    const l0_entry: *Entry = @ptrFromInt(kernel.boot.hhdm_base + space.l0_table + l0_index * 8);
    if (!l0_entry.valid) return;
    if (!l0_entry.not_a_block) unreachable; // should not be possible since 512 GiB allocation is not permitted.

    const l1_table: u64 = l0_entry.descriptor.table.next_level_table << 12;
    const l1_entry: *Entry = @ptrFromInt(kernel.boot.hhdm_base + l1_table + l1_index * 8);
    if (!l1_entry.valid) return;

    // 1 GiB page
    if (!l1_entry.not_a_block) {
        l1_entry.valid = false;
        return;
    }

    const l2_table: u64 = l1_entry.descriptor.table.next_level_table << 12;
    const l2_entry: *Entry = @ptrFromInt(kernel.boot.hhdm_base + l2_table + l2_index * 8);
    if (!l2_entry.valid) return;

    // 2 MiB page
    if (!l2_entry.not_a_block) {
        l2_entry.valid = false;
        return;
    }

    // 4 KiB page
    const l3_table: u64 = l2_entry.descriptor.table.next_level_table << 12;
    const l3_entry: *Entry = @ptrFromInt(kernel.boot.hhdm_base + l3_table + l3_index * 8);
    if (!l3_entry.valid) return;
    l3_entry.valid = false;
}

// --- mem/aarch64/virt.zig --- //

pub fn setPageMapping(entry: *Entry, mapping: virt.Mapping) void {
    entry.descriptor.block_page = BlockPageDescriptor.build(
        mapping.phys_addr,
        mapping.flags,
        @intFromEnum(mapping.hint),
    );
}

pub fn getPageMapping(entry: *Entry) virt.Mapping {
    const block_page = entry.descriptor.block_page;
    const phys_addr: u64 = block_page.output_address << 12;

    return virt.Mapping{
        .phys_addr = phys_addr,
        .level = undefined,
        .flags = block_page.getFlags(),
        .hint = @enumFromInt(block_page.software_use),
    };
}

fn get_table(table_addr: u64, index: u64) ?u64 {
    const entry: *Entry = @ptrFromInt(kernel.boot.hhdm_base + table_addr + index * 8);

    if (entry.valid and entry.not_a_block) {
        return entry.descriptor.table.next_level_table << 12;
    }

    return null;
}

fn ensure_table(table_addr: u64, index: u64) u64 {
    const entry: *Entry = @ptrFromInt(kernel.boot.hhdm_base + table_addr + index * 8);

    if (entry.valid and entry.not_a_block) {
        return entry.descriptor.table.next_level_table << 12;
    }

    const new_table = phys.allocPage(.l4K, true) catch @panic("unable to allocate a page_table");

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

pub fn free_table_recursive(table_addr: u64, level: u8) void {
    for (0..512) |i| {
        const e_ptr: *Entry = @ptrFromInt(kernel.boot.hhdm_base + table_addr + i * 8);
        const entry = e_ptr.*;

        if (!entry.valid) continue;

        if (entry.not_a_block and level != 3) {
            free_table_recursive(entry.descriptor.table.next_level_table << 12, level + 1);
        } else {
            phys.freePage(entry.descriptor.block_page.output_address << 12, .l4K);
        }
    }

    phys.freePage(table_addr, .l4K);
}
