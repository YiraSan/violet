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

const builtin = @import("builtin");
const basalt = @import("basalt");
const std = @import("std");

const log = std.log.scoped(.loader);

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const scheduler = kernel.scheduler;

const vmm = mem.vmm;

const Process = scheduler.Process;
const Task = scheduler.Task;

// --- loader/root.zig --- //

pub fn loadELF(process_id: Process.Id, elf_file: []align(8) const u8, options: Task.Options) !*Task {
    const elf_header = try std.elf.Header.parse(@ptrCast(elf_file));
    var fbs = std.io.fixedBufferStream(elf_file);

    if (!elf_header.is_64) {
        return Error.InvalidELF;
    }

    if (elf_header.endian != builtin.cpu.arch.endian()) {
        return Error.InvalidELF;
    }

    if (switch (builtin.cpu.arch) {
        .aarch64 => elf_header.machine != .AARCH64,
        .riscv64 => elf_header.machine != .RISCV,
        .x86_64 => elf_header.machine != .X86_64,
        else => unreachable,
    }) {
        return Error.InvalidELF;
    }

    const process = Process.acquire(process_id) orelse return Error.InvalidProcess;
    defer process.release();

    const target_space = process.virtualSpace();

    var is_pie = false;
    switch (elf_header.type) {
        .EXEC => {
            if (process.isPrivileged()) return Error.InvalidELF;
        },
        .DYN => {
            is_pie = true;
        },
        else => return Error.InvalidELF,
    }

    var min_vaddr: u64 = std.math.maxInt(u64);
    var max_vaddr: u64 = 0;

    var iter_bounds = elf_header.program_header_iterator(&fbs);
    while (try iter_bounds.next()) |phdr| {
        if (phdr.p_type != std.elf.PT_LOAD) continue;
        if (phdr.p_memsz == 0) continue;

        if (phdr.p_vaddr < min_vaddr) min_vaddr = phdr.p_vaddr;
        const end = phdr.p_vaddr + phdr.p_memsz;
        if (end > max_vaddr) max_vaddr = end;
    }

    const aligned_min_vaddr = std.mem.alignBackward(u64, min_vaddr, mem.PageLevel.l4K.size());
    const aligned_max_vaddr = std.mem.alignForward(u64, max_vaddr, mem.PageLevel.l4K.size());

    const total_size = aligned_max_vaddr - aligned_min_vaddr;

    var load_base: u64 = undefined;

    if (is_pie) {
        load_base = try target_space.allocator.alloc(total_size, 0, null, 0, null, true);
    } else {
        load_base = aligned_min_vaddr;
        try target_space.allocator.allocAt(aligned_min_vaddr, total_size, null, 0, null, true);
    }

    var program_header_iter = elf_header.program_header_iterator(&fbs);

    while (try program_header_iter.next()) |phdr| {
        if (phdr.p_type != std.elf.PT_LOAD) continue;

        const offset_in_image = phdr.p_vaddr - aligned_min_vaddr;
        const target_vaddr = load_base + offset_in_image;

        const page_start = std.mem.alignBackward(u64, target_vaddr, mem.PageLevel.l4K.size());
        const page_end = std.mem.alignForward(u64, target_vaddr + phdr.p_memsz, mem.PageLevel.l4K.size());
        const map_size = page_end - page_start;

        const object = try vmm.Object.create(phdr.p_memsz, .{
            .writable = (phdr.p_flags & std.elf.PF_W) != 0,
            .executable = (phdr.p_flags & std.elf.PF_X) != 0,
        });

        const kmap_addr = try vmm.kernel_space.map(object, map_size, 0, 0, .{ .writable = true }, true);
        const kmap_ptr: [*]u8 = @ptrFromInt(kmap_addr);
        defer vmm.kernel_space.unmap(kmap_addr, false) catch {};

        const page_offset = target_vaddr - page_start;

        const dest = kmap_ptr[page_offset .. page_offset + phdr.p_filesz];
        const src = elf_file[phdr.p_offset .. phdr.p_offset + phdr.p_filesz];
        @memcpy(dest, src);

        try target_space.allocator.splitAndAssign(page_start, map_size, object, 0, null);
    }

    var task_options = options;

    const entry_offset = elf_header.entry - aligned_min_vaddr;
    task_options.entry_point = load_base + entry_offset;

    return Task.create(process_id, task_options);
}

pub const Error = error{
    InvalidProcess,
    InvalidELF,
};
