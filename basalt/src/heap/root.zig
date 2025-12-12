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

// --- imports --- //

const basalt = @import("basalt");

const module = basalt.module;
const syscall = basalt.syscall;

// --- heap/root.zig --- //

pub const PAGE_SIZE = 0x1000;

/// Maps virtual memory.
///
/// The memory is strictly initialized with **Read-Write** permissions.
///
/// violetOS prohibits creating Read-Only or Executable memory directly to enforce
/// a secure lifecycle: write data/code first, then seal the region.
pub fn map(page_count: usize, alignment: std.mem.Alignment) ![]u8 {
    var ptr: [*]u8 = undefined;

    _ = try syscall.syscall3(
        .mem_map,
        @intFromPtr(&ptr),
        page_count,
        alignment.toByteUnits(),
    );

    const size = page_count * PAGE_SIZE;
    return ptr[0..size];
}

/// Unmaps and releases a previously mapped memory region.
///
/// The provided address must be the **exact base address** returned by `map`.
/// Partial unmapping or providing an offset pointer within a region is invalid
/// and will result in an `InvalidAddress` error.
pub fn unmap(address: [*]u8) !void {
    _ = try syscall.syscall1(.mem_unmap, @intFromPtr(address));
}

pub const page_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &PageAllocator.vtable,
};

const PageAllocator = struct {
    pub const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const aligned_count = std.mem.alignForward(usize, len, PAGE_SIZE) / PAGE_SIZE;

        if (aligned_count == 0) return null;

        const buffer = map(aligned_count, alignment) catch return null;
        return buffer.ptr;
    }

    fn resize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        const current_capacity = std.mem.alignForward(usize, buf.len, PAGE_SIZE);
        const new_capacity = std.mem.alignForward(usize, new_len, PAGE_SIZE);

        if (new_capacity > current_capacity) return false;

        return true;
    }

    fn remap(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        if (resize(undefined, buf, alignment, new_len, ret_addr)) {
            return buf.ptr;
        }

        return null;
    }

    fn free(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
        unmap(buf.ptr) catch {};
    }
};
