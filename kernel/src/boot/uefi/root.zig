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

const ark = @import("ark");
const std = @import("std");
const builtin = @import("builtin");

const uefi = std.os.uefi;

const log = std.log.scoped(.boot);

// --- imports --- //

const kernel = @import("root");

const arch = kernel.arch;
const boot = kernel.boot;
const drivers = kernel.drivers;

const PAGE_SIZE = kernel.mem.PageLevel.l4K.size();

// --- boot/uefi/root.zig --- //

const BootConfig = extern struct {
    memory_map_ptr: u64,
    memory_map_size: u64,
    memory_map_descriptor_size: u64,

    configuration_tables_ptr: u64,
    configuration_tables_len: u64,

    genesis_file_ptr: u64,
    genesis_file_size: u64,
};

var memory_map: MemoryMap = undefined;
var configuration_tables: []uefi.tables.ConfigurationTable = undefined;
var xsdt: *drivers.acpi.Xsdt = undefined;

export fn kernel_entry(
    hhdm_base: u64,
    hhdm_limit: u64,
    boot_config_ptr: u64,
) callconv(switch (builtin.cpu.arch) {
    .aarch64 => .{ .aarch64_aapcs = .{} },
    .riscv64 => .{ .riscv64_lp64 = .{} },
    else => unreachable,
}) noreturn {
    boot.hhdm_base = hhdm_base;
    boot.hhdm_limit = hhdm_limit;

    const boot_config: *BootConfig = @ptrFromInt(boot.hhdm_base + boot_config_ptr);

    memory_map = .{
        .map = @ptrFromInt(boot.hhdm_base + boot_config.memory_map_ptr),
        .map_size = boot_config.memory_map_size,
        .descriptor_size = boot_config.memory_map_descriptor_size,
    };

    configuration_tables = @as([*]uefi.tables.ConfigurationTable, @ptrFromInt(boot.hhdm_base + boot_config.configuration_tables_ptr))[0..boot_config.configuration_tables_len];

    var xsdt_found = false;
    for (configuration_tables) |*entry| {
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid)) {
            @setRuntimeSafety(false);
            const rsdp: *drivers.acpi.Rsdp = @ptrFromInt(hhdm_base + @intFromPtr(entry.vendor_table));
            xsdt = @ptrFromInt(hhdm_base + rsdp.xsdt_addr);
            xsdt_found = true;
        }
    }
    if (!xsdt_found) unreachable;

    // TODO temp
    boot.xsdt = xsdt;

    boot.genesis_file = @as([*]align(8) const u8, @ptrFromInt(boot_config.genesis_file_ptr))[0..boot_config.genesis_file_size];

    kernel.stage0() catch |err| {
        log.err("kernel stage-0 returned with an error: {}", .{err});
        ark.cpu.halt();
    };

    kernel.stage1() catch |err| {
        log.err("kernel stage-1 returned with an error: {}", .{err});
        ark.cpu.halt();
    };

    kernel.stage2() catch |err| {
        log.err("kernel stage-2 returned with an error: {}", .{err});
        ark.cpu.halt();
    };

    ark.cpu.halt();
}

const MemoryMap = struct {
    map: [*]uefi.tables.MemoryDescriptor,
    map_size: usize,
    descriptor_size: usize,

    pub fn get(self: MemoryMap, index: usize) ?*uefi.tables.MemoryDescriptor {
        const i = self.descriptor_size * index;
        if (i > (self.map_size - self.descriptor_size)) return null;
        return @ptrFromInt(@intFromPtr(self.map) + i);
    }
};

// --- boot implementation --- //

pub const UnusedMemoryIterator = struct {
    index: usize = 0,

    pub fn next(self: *@This()) ?boot.MemoryEntry {
        while (true) {
            const current_entry = memory_map.get(self.index) orelse return null;
            self.index += 1;

            const is_usable = switch (current_entry.type) {
                .conventional_memory,
                .loader_code,
                .boot_services_code,
                .boot_services_data,
                => true,
                else => false,
            };

            if (!is_usable) {
                continue;
            }

            const raw_start = current_entry.physical_start;
            const aligned_start = std.mem.alignForward(usize, raw_start, PAGE_SIZE);
            var valid_pages = current_entry.number_of_pages;

            if (aligned_start > raw_start) {
                if (valid_pages > 0) {
                    valid_pages -= 1;
                }
            }

            if (valid_pages == 0) {
                continue;
            }

            return boot.MemoryEntry{
                .physical_base = aligned_start,
                .number_of_pages = valid_pages,
            };
        }
    }
};
