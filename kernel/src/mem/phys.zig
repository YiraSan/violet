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

const Whba = @import("whba");

// --- imports --- //

const kernel = @import("root");

const boot = kernel.boot;
const mem = kernel.mem;

const PAGE_SIZE = 0x1000;

// --- mem/phys.zig --- //

var whba: Whba = undefined;
var lock: mem.RwLock = .{};

// -- public api -- //

pub const Local = struct {
    primary_4k_cache: [128]u64,
    primary_4k_cache_pos: usize,

    recycle_4k_cache: [128]u64,
    recycle_4k_cache_num: usize,

    pub fn get() *@This() {
        return &kernel.arch.Cpu.get().phys_local;
    }
};

pub fn initCpu() Whba.Error!void {
    const local = Local.get();

    local.primary_4k_cache_pos = 128;
    local.recycle_4k_cache_num = 0;

    try refillPrimary(local);
}

fn refillPrimary(local: *Local) Whba.Error!void {
    const lock_flags = lock.lockExclusive();
    defer lock.unlockExclusive(lock_flags);

    try whba.allocNonContiguous(&local.primary_4k_cache);
    local.primary_4k_cache_pos = 0;
}

pub fn allocPage(reset: bool) Whba.Error!u64 {
    const local = Local.get();
    var address: u64 = undefined;

    if (local.recycle_4k_cache_num > 0) {
        local.recycle_4k_cache_num -= 1;
        address = local.recycle_4k_cache[local.recycle_4k_cache_num];
    } else if (local.primary_4k_cache_pos < 128) {
        address = local.primary_4k_cache[local.primary_4k_cache_pos];
        local.primary_4k_cache_pos += 1;
    } else {
        try refillPrimary(local);
        address = local.primary_4k_cache[0];
        local.primary_4k_cache_pos = 1;
    }

    if (reset) {
        @memset(@as([*]u8, @ptrFromInt(kernel.boot.hhdm_base + address))[0..PAGE_SIZE], 0);
    }

    return address;
}

pub fn freePage(address: u64) void {
    const local = Local.get();

    if (local.recycle_4k_cache_num < 128) {
        local.recycle_4k_cache[local.recycle_4k_cache_num] = address;
        local.recycle_4k_cache_num += 1;
        return;
    }

    if (local.primary_4k_cache_pos == 128) {
        @memcpy(&local.primary_4k_cache, &local.recycle_4k_cache);

        local.primary_4k_cache_pos = 0;
        local.recycle_4k_cache_num = 0;

        local.recycle_4k_cache[0] = address;
        local.recycle_4k_cache_num = 1;
        return;
    }

    {
        const lock_flags = lock.lockExclusive();
        defer lock.unlockExclusive(lock_flags);

        whba.freeNonContiguous(&local.recycle_4k_cache) catch {
            @panic("PMM: Failed to flush local cache to global");
        };
    }

    local.recycle_4k_cache_num = 0;
    local.recycle_4k_cache[0] = address;
    local.recycle_4k_cache_num = 1;
}

pub fn allocContiguous(count: usize, reset: bool) Whba.Error!u64 {
    const address = blk: {
        const lock_flags = lock.lockExclusive();
        defer lock.unlockExclusive(lock_flags);
        break :blk try whba.allocContiguous(count);
    };

    if (reset) {
        const ptr = @as([*]u8, @ptrFromInt(kernel.boot.hhdm_base + address));
        const byte_size = PAGE_SIZE * count;
        @memset(ptr[0..byte_size], 0);
    }

    return address;
}

pub fn freeContiguous(address: u64, count: usize) void {
    const lock_flags = lock.lockExclusive();
    defer lock.unlockExclusive(lock_flags);

    whba.freeContiguous(address, count) catch {
        @panic("PMM: Failed to free contiguous block");
    };
}

// -- init -- //

const BumpAllocator = struct {
    ptr: usize,

    fn alloc(self: *@This(), comptime T: type, count: u64) []T {
        const size = count * @sizeOf(T);
        const alignment = @alignOf(T);
        const aligned_start = std.mem.alignForward(usize, self.ptr, alignment);
        const new_ptr = aligned_start + size;
        self.ptr = new_ptr;
        return @as([*]T, @ptrFromInt(aligned_start))[0..count];
    }
};

pub fn init() !void {
    var max_physical_address: u64 = 0;
    var scanner = boot.UnusedMemoryIterator{};
    while (scanner.next()) |entry| {
        const end = entry.physical_base + (entry.number_of_pages * PAGE_SIZE);
        if (end > max_physical_address) max_physical_address = end;
    }

    whba.limit_page_index = max_physical_address / PAGE_SIZE;

    const metadata_sizes = whba.metadataSizes();
    const metadata_total_size = std.mem.alignForward(usize, metadata_sizes.l0_size + metadata_sizes.l1_size + metadata_sizes.l2_size + PAGE_SIZE, PAGE_SIZE);
    const metadata_pages_count = metadata_total_size / PAGE_SIZE;

    var finder = boot.UnusedMemoryIterator{};
    var metadata_phys_start: u64 = 0;
    var found_spot = false;
    while (finder.next()) |entry| {
        if (entry.number_of_pages >= metadata_pages_count) {
            metadata_phys_start = entry.physical_base;
            found_spot = true;
            break;
        }
    }

    if (!found_spot) @panic("WHBA: not enough contiguous RAM for metadata!");

    var allocator = BumpAllocator{ .ptr = @intCast(boot.hhdm_base + metadata_phys_start) };

    whba.level0.bitmaps = allocator.alloc(u64, metadata_sizes.l0_count);
    whba.level0.lcrs = allocator.alloc(Whba.Lcr, metadata_sizes.l0_count);

    whba.level1.bitmaps = allocator.alloc(u64, metadata_sizes.l1_count);
    whba.level1.leaf_free = allocator.alloc(u32, metadata_sizes.l1_count);

    whba.level2.bitmaps = allocator.alloc(u64, metadata_sizes.l2_count);
    whba.level2.leaf_free = allocator.alloc(u32, metadata_sizes.l2_count);

    whba.reset();

    var applier = boot.UnusedMemoryIterator{};
    while (applier.next()) |entry| {
        whba.unmark(entry.physical_base, entry.number_of_pages) catch @panic("WHBA: failed unmarking");
    }

    whba.mark(metadata_phys_start, metadata_pages_count) catch @panic("WHBA: failed marking");
}
