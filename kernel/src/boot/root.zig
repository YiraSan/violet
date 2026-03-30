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
const build_options = @import("build_options");
const limine = @import("limine");

// --- imports --- //

const kernel = @import("root");

const drivers = kernel.drivers;

// --- boot/root.zig --- //

export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

export var base_revision: limine.BaseRevision linksection(".limine_requests") = .init(4);
export var framebuffer_request: limine.FramebufferRequest linksection(".limine_requests") = .{};
export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};
export var memmap_request: limine.MemoryMapRequest linksection(".limine_requests") = .{};
export var rsdp_request: limine.RsdpRequest linksection(".limine_requests") = .{};

pub var hhdm_base: u64 = undefined;
pub var hhdm_limit: u64 = undefined;

pub var memmap: *limine.MemoryMapResponse = undefined;
pub var xsdt: *drivers.acpi.Xsdt = undefined;

fn hcf() noreturn {
    while (true) {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile ("hlt"),
            .aarch64, .riscv64 => asm volatile ("wfi"),
            .loongarch64 => asm volatile ("idle 0"),
            else => unreachable,
        }
    }
}

export fn kernel_entry() noreturn {
    if (!base_revision.isSupported()) {
        while (true) {}
    }

    if (builtin.cpu.arch == .aarch64) {
        var mair_el1 = ark.armv8.registers.MAIR_EL1.load();
        mair_el1.attr2 = ark.armv8.registers.MAIR_EL1.DEVICE_nGnRnE;
        mair_el1.attr3 = ark.armv8.registers.MAIR_EL1.NORMAL_NONCACHEABLE;
        mair_el1.attr4 = ark.armv8.registers.MAIR_EL1.NORMAL_WRITETHROUGH_NONTRANSIENT;
        mair_el1.store();

        asm volatile (
            \\ dsb ish
            \\ dsb sy
            \\ isb
        );
    }

    if (hhdm_request.response) |hhdm_response| {
        hhdm_base = hhdm_response.offset;
    }

    if (memmap_request.response) |memmap_response| {
        memmap = memmap_response;
    }

    hhdm_limit = 0xFFFF_F000_0000_0000;
    for (memmap.getEntries()) |entry| {
        switch (entry.type) {
            .usable,
            .bootloader_reclaimable,
            .executable_and_modules,
            .framebuffer,
            .acpi_tables,
            .acpi_nvs,
            .acpi_reclaimable => {
                const limit = hhdm_base + entry.base + entry.length;

                if (hhdm_limit < limit) {
                    hhdm_limit = limit;
                }
            },
            else => {},
        }
    }

    hhdm_limit = std.mem.alignForward(u64, hhdm_limit, 0x40000000);

    if (rsdp_request.response) |rsdp_response| {
        @setRuntimeSafety(false);
        const rsdp: *drivers.acpi.Rsdp = @ptrCast(rsdp_response.address);
        xsdt = @ptrFromInt(hhdm_base + rsdp.xsdt_addr);
    }

    kernel.stage0() catch unreachable;
    kernel.stage1() catch unreachable;

    hcf();
}

pub fn hint() void {
    if (framebuffer_request.response) |framebuffer_response| {
        const framebuffer = framebuffer_response.getFramebuffers()[0];
        for (0..100) |i| {
            const fb_ptr: [*]volatile u32 = @ptrCast(@alignCast(framebuffer.address));
            fb_ptr[i * (framebuffer.pitch / 4) + i] = 0xffffff;
        }
    }
}

const PAGE_SIZE = 0x1000;

/// Everything has to be page-aligned.
pub const MemoryEntry = struct {
    physical_base: u64,
    number_of_pages: u64,
};

pub const UnusedMemoryIterator = struct {
    index: usize = 0,

    pub fn next(self: *@This()) ?MemoryEntry {
        while (true) {
            if (self.index >= memmap.entry_count) return null;
            const current_entry: *limine.MemoryMapEntry = memmap.getEntries()[self.index];
            self.index += 1;

            const is_usable = current_entry.type == .usable;

            if (!is_usable) {
                continue;
            }

            return MemoryEntry{
                .physical_base = current_entry.base,
                .number_of_pages = current_entry.length / 0x1000,
            };
        }
    }
};
