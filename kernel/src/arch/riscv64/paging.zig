// Copyright (c) 2024-2026 YiraSan
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

// --- imports --- //

const kernel = @import("root");

const arch = kernel.arch;

const mem = kernel.mem;
const paging = mem.paging;

comptime {
    std.debug.assert(paging.page_size == 4 * 1024);
}

// --- arch/riscv64/paging.zig --- //

const Pbmt = enum(u2) {
    pma = 0b00,
    nc = 0b01,
    io = 0b10,
};

inline fn applyAttributes(pte: *PteView, attrs: paging.Attributes) void {
    pte.readable = true;
    pte.writable = attrs.permissions.writable;
    pte.executable = attrs.permissions.executable;
    pte.user = attrs.permissions.user;
    pte.global = attrs.permissions.global;

    pte.accessed = true;
    pte.dirty = attrs.permissions.writable;

    pte.pbmt = switch (attrs.mem_type) {
        .writeback => .pma,
        .write_combining => .nc,
        .device => .io,
    };
}

inline fn extractAttributes(pte: PteView) paging.Attributes {
    return .{
        .permissions = .{
            .writable = pte.writable,
            .executable = pte.executable,
            .user = pte.user,
            .global = pte.global,
        },
        .mem_type = switch (pte.pbmt) {
            .pma => .writeback,
            .nc => .write_combining,
            .io => .device,
        },
    };
}

pub fn encode(level: paging.Level, entry: paging.Entry) u64 {
    var pte = ArchEntry.empty;
    const is_base_page = (level == 0);

    switch (entry) {
        .unmapped => {},
        .guard => pte.software.state = .guard,
        .uncommitted => |attrs| {
            std.debug.assert(attrs.mem_type != .device);

            if (is_base_page) {
                pte.pte.valid = true;
                pte.pte.readable = true;
                pte.pte.writable = false;
                pte.pte.executable = attrs.permissions.executable;
                pte.pte.user = attrs.permissions.user;
                pte.pte.global = attrs.permissions.global;
                pte.pte.accessed = true;
                pte.pte.dirty = false;
                pte.pte.pbmt = .pma;
                pte.pte.ppn = @truncate(kernel.mem.zero_page_pa >> paging.offset_bits);

                pte.rsw.uncommitted = true;
                pte.rsw.real_writable = attrs.permissions.writable;
            } else {
                pte.software.state = .uncommitted;
                pte.software.writable = attrs.permissions.writable;
                pte.software.executable = attrs.permissions.executable;
                pte.software.user = attrs.permissions.user;
                pte.software.global = attrs.permissions.global;
                pte.software.mem_type = switch (attrs.mem_type) {
                    .writeback => .writeback,
                    .write_combining => .write_combining,
                    .device => .device,
                };
            }
        },
        .table => |pa| {
            std.debug.assert(pa >> 56 == 0);
            pte.pte.valid = true;
            pte.pte.ppn = @truncate(pa >> paging.offset_bits);
        },
        .leaf => |leaf| {
            std.debug.assert(leaf.physical_address >> 56 == 0);
            pte.pte.valid = true;
            applyAttributes(&pte.pte, leaf.attributes);
            pte.pte.ppn = @truncate(leaf.physical_address >> paging.offset_bits);
        },
    }

    return pte.raw;
}

pub fn decode(level: paging.Level, raw: u64) paging.Entry {
    const pte: ArchEntry = .{ .raw = raw };

    if (!pte.pte.valid) {
        const sw = pte.software;
        return switch (sw.state) {
            .none => .unmapped,
            .guard => .guard,
            .uncommitted => .{ .uncommitted = .{
                .permissions = .{
                    .writable = sw.writable,
                    .executable = sw.executable,
                    .user = sw.user,
                    .global = sw.global,
                },
                .mem_type = switch (sw.mem_type) {
                    .writeback => .writeback,
                    .write_combining => .write_combining,
                    .device => .device,
                },
            } },
        };
    }

    const is_base_page = (level == 0);

    if (is_base_page and pte.rsw.uncommitted) {
        var attrs = extractAttributes(pte.pte);
        attrs.permissions.writable = pte.rsw.real_writable;
        return .{ .uncommitted = attrs };
    }

    const pa = @as(u64, pte.pte.ppn) << paging.offset_bits;

    const is_leaf_pte = pte.pte.readable or pte.pte.writable or pte.pte.executable;
    if (is_leaf_pte) {
        return .{ .leaf = .{ .physical_address = pa, .attributes = extractAttributes(pte.pte) } };
    } else {
        return .{ .table = pa };
    }
}

pub fn canMapAt(level: paging.Level) bool {
    _ = level;
    return true;
}

const SatpMode = arch.registers.Satp.Mode;

const satp_mode: SatpMode = switch (paging.page_levels) {
    3 => .sv39,
    4 => .sv48,
    5 => .sv57,
    else => @compileError("riscv64: unsupported page_levels for satp encoding"),
};

pub fn activate(low_half_root: ?u64, high_half_root: u64) void {
    const root_entries = paging.entries_per_table;
    const half = root_entries / 2;

    const high_table = mem.toHhdm([paging.entries_per_table]u64, high_half_root);

    if (std.debug.runtime_safety) {
        for (high_table[0..half]) |entry| {
            std.debug.assert(entry == 0);
        }
    }

    const final_root = if (low_half_root) |lhr| blk: {
        const low_table = mem.toHhdm([paging.entries_per_table]u64, lhr);

        @memcpy(low_table[half..root_entries], high_table[half..root_entries]);

        arch.cpu.syncStores();
        break :blk lhr;
    } else high_half_root;

    arch.registers.Satp.store(.{
        .ppn = @truncate(final_root >> paging.offset_bits),
        .asid = 0,
        .mode = satp_mode,
    });

    asm volatile ("sfence.vma zero, zero" ::: .{ .memory = true });
}

pub fn flush(scope: paging.FlushScope) void {
    switch (scope) {
        .all => {
            asm volatile ("sfence.vma zero, zero" ::: .{ .memory = true });
        },
        .address => |addr| {
            if (addr.global) {
                asm volatile ("sfence.vma %[va], zero"
                    :
                    : [va] "r" (addr.va),
                    : .{ .memory = true });
            } else {
                asm volatile ("sfence.vma %[va], zero"
                    :
                    : [va] "r" (addr.va),
                    : .{ .memory = true });
            }
        },
    }
}

pub const low_half_max: u64 = (@as(u64, 1) << @intCast(paging.va_bits - 1)) - 1;
pub const high_half_min: u64 = ~low_half_max;

pub fn isCanonical(va: u64) bool {
    return va <= low_half_max or va >= high_half_min;
}

pub fn configure() !void {}

pub fn getBootTable() u64 {
    var satp: u64 = undefined;
    asm volatile ("csrr %[satp], satp"
        : [satp] "=r" (satp),
    );

    return (satp & 0x0000_0fff_ffff_ffff) << 12;
}

const ArchEntry = packed union {
    pub const empty: ArchEntry = .{ .raw = 0 };

    raw: u64,
    pte: PteView,
    rsw: RswView,
    software: SoftwareView,
};

const PteView = packed struct(u64) {
    valid: bool = false, // bit 0
    readable: bool = false, // bit 1
    writable: bool = false, // bit 2
    executable: bool = false, // bit 3
    user: bool = false, // bit 4
    global: bool = false, // bit 5
    accessed: bool = false, // bit 6
    dirty: bool = false, // bit 7

    _rsw: u2 = 0, // bits 8-9

    ppn: u44 = 0, // bits 10-53
    _reserved: u7 = 0, // bits 54-60
    pbmt: Pbmt = .pma, // bits 61-62
    napot: bool = false, // bit 63
};

const RswView = packed struct(u64) {
    _low: u8 = 0, // bits 0-7
    uncommitted: bool = false, // bit 8
    real_writable: bool = false, // bit 9
    _high: u54 = 0, // bits 10-63
};

const SoftwareView = packed struct(u64) {
    valid: bool = false, // bit 0
    state: enum(u2) { // bits 1-2
        none = 0,
        uncommitted = 1,
        guard = 2,
    } = .none,
    writable: bool = false, // bit 3
    executable: bool = false, // bit 4
    user: bool = false, // bit 5
    global: bool = false, // bit 6
    mem_type: enum(u2) { // bits 7-8
        writeback = 0,
        write_combining = 1,
        device = 2,
    } = .writeback,
    _ignored: u55 = 0, // bits 9-63
};
