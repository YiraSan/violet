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
const builtin = @import("builtin");
const limine = @import("limine");
const build_options = @import("build_options");

// --- imports --- //

const kernel = @import("root");

const arch = kernel.arch;
const cpu = arch.cpu;

const mem = kernel.mem;
const phys = mem.phys;

const drivers = kernel.drivers;
const acpi = drivers.acpi;

// --- boot/main.zig --- //

export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

export var base_revision: limine.BaseRevision linksection(".limine_requests") = .init(6);
export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};
export var memmap_request: limine.MemoryMapRequest linksection(".limine_requests") = .{};
export var rsdp_request: limine.RsdpRequest linksection(".limine_requests") = .{};

const requested_mode: limine.PagingMode = switch (builtin.cpu.arch) {
    .aarch64 => switch (build_options.page_levels) {
        3, 4 => .@"4lvl",
        5 => .@"5lvl",
        else => @panic("this level is unsupported on aarch64"),
    },
    .riscv64 => switch (build_options.page_levels) {
        3 => .sv39,
        4 => .sv48,
        5 => .sv57,
        else => @panic("this level is unsupported on riscv64"),
    },
    .x86_64 => switch (build_options.page_levels) {
        4 => .@"4lvl",
        5 => .@"5lvl",
        else => @panic("this level is unsupported on x86_64"),
    },
    else => @panic("arch unsupported"),
};

export var pagingmode_request: limine.PagingModeRequest linksection(".limine_requests") = .{ .mode = requested_mode, .max_mode = requested_mode, .min_mode = requested_mode };

export var framebuffer_request: limine.FramebufferRequest linksection(".limine_requests") = .{};

export fn kernel_entry() noreturn {
    if (!base_revision.isSupported()) {
        cpu.halt();
    }

    const pagingmode_response: *limine.PagingModeResponse = pagingmode_request.response.?;
    if (pagingmode_response.mode != requested_mode) unreachable;

    mem.hhdm_offset = hhdm_request.response.?.offset;

    const rsdp: *acpi.Rsdp = @ptrCast(@alignCast(rsdp_request.response.?.address));
    if (!rsdp.isValid()) unreachable;

    const xsdt = mem.toHhdm(acpi.Xsdt, rsdp.xsdt_address);
    if (!xsdt.isValid()) unreachable;

    kernel.serial.init();

    drivers.runStage(xsdt, .stage0);

    const memmap_entries: []*limine.MemoryMapEntry = memmap_request.response.?.getEntries();
    phys.init(memmap_entries);

    drivers.runStage(xsdt, .stage1);

    if (builtin.mode == .Debug) {
        if (framebuffer_request.response) |fb_response| {
            if (fb_response.framebuffer_count > 0) {
                const framebuffer = fb_response.getFramebuffers()[0];
                for (0..100) |i| {
                    const fb_ptr: [*]volatile u32 = @ptrCast(@alignCast(framebuffer.address));
                    fb_ptr[i * (framebuffer.pitch / 4) + i] = 0xffffff;
                }
            }
        }
    }

    kernel.serial.clear(null);
    std.log.info("version {s}", .{build_options.version});

    const available_mib = mem.phys.availablePages() * mem.paging.page_size / 1024 / 1024;
    if (available_mib < 384) std.debug.panic("available memory: {} MiB is under 384 MiB requirement", .{available_mib});
    std.log.info("available memory: {} MiB", .{available_mib});

    cpu.halt();
}
