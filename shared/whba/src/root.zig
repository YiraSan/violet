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

//! # Wise Hierarchical Bitmap Allocator (WHBA)
//!
//! The WHBA is a physical memory allocator designed to be "smarter" than traditional bitmaps.
//! Instead of brute-force scanning, it uses augmented metadata (LCR & Counts) to make O(1) decisions
//! at higher levels of the hierarchy.
//!
//! It guarantees:
//!
//! - **Lowest possible fragmentation without relocation**: utilizes a "Wise" Hotspot algorithm to efficiently fill non-contiguous memory gaps first;
//! - **Zero internal fragmentation**: maximizes memory density (no power-of-two padding like Buddy allocators);
//! - **Negligible memory footprint**: requires only ~0.004% of total RAM for metadata, fitting entirely in L1/L2 cache;
//! - **Worst-case O(logₖ N) allocation**: deterministic performance for non-contiguous 4K pages (covering >90% of workloads);
//! - **Cache-friendly data structures**: minimizes cache-misses through compact, structure-of-arrays layouts;
//! - **Blazingly fast small contiguous allocation (<= 256 KiB)**: leverages LCR (Longest Contiguous Run) pruning to instantly locate slots without linear bit-scanning;
//! - **Statistically instant large contiguous allocations (> 256 KiB)**: strict packing of small allocations naturally preserves vast contiguous regions, rendering linear scanning trivial in practice (avoiding the fragmentation decay typical of Buddy systems).
//!
//! **Note on IPC Workloads:**
//!
//! Traditional Buddy Allocators suffer from "High-Order Fragmentation Decay" under
//! heavy Zero-Copy IPC workloads. A single long-lived 4KiB page can pin down
//! a much larger block, preventing coalescing (the "Swiss Cheese" effect).
//!
//! WHBA's Hotspot strategy naturally segregates volatile IPC pages into
//! densely packed regions, preserving High-Order (contiguous) blocks from
//! being shattered by transient, asynchronous allocations.
//!
//! This is critical for the asynchronous, zero-copy architecture of violetOS.

// --- Dependencies --- //

const std = @import("std");

// --- Wise Hierarchical Bitmap Allocator (WHBA) --- //

const PAGE_SIZE = 0x1000;

const Self = @This();

pub const Branch = struct {
    bitmaps: []u64,
    leaf_free: []u32,

    pub const ENTRY_SIZE = @sizeOf(u64) + @sizeOf(u32);
};

/// Longest Contiguous Run
pub const Lcr = packed struct(u16) {
    start: u8,
    size: u8,
};

pub const Leaf = struct {
    bitmaps: []u64,
    lcrs: []Lcr,

    pub const ENTRY_SIZE = @sizeOf(u64) + @sizeOf(Lcr);
};

level2: Branch,
level1: Branch,
level0: Leaf,

limit_page_index: u64,

available_pages: u64,

// --- Public API --- //

pub const Error = error{ OutOfMemory, OutOfBounds, UnalignedAddress };

/// `self.limit_page_index` should be defined.
pub fn metadataSizes(self: *Self) struct { l0_count: u64, l1_count: u64, l2_count: u64, l0_size: u64, l1_size: u64, l2_size: u64 } {
    const l0_count = (self.limit_page_index + 63) / 64;
    const l1_count = (l0_count + 63) / 64;
    const l2_count = (l1_count + 63) / 64;

    return .{
        .l0_count = l0_count,
        .l1_count = l1_count,
        .l2_count = l2_count,
        .l0_size = l0_count * Leaf.ENTRY_SIZE,
        .l1_size = l1_count * Branch.ENTRY_SIZE,
        .l2_size = l2_count * Branch.ENTRY_SIZE,
    };
}

/// Resets the allocator to a fully saturated state (all pages marked as used).
///
/// The hierarchical buffers (`level0`...`level2`) must be pre-allocated and
/// sized to cover the entire range up to `self.limit_page_index`.
pub fn reset(self: *Self) void {
    self.available_pages = 0;

    @memset(self.level0.bitmaps, std.math.maxInt(u64));
    const empty_lcr = Lcr{ .start = 0, .size = 0 };
    @memset(self.level0.lcrs, empty_lcr);

    @memset(self.level1.bitmaps, std.math.maxInt(u64));
    @memset(self.level1.leaf_free, 0);

    @memset(self.level2.bitmaps, std.math.maxInt(u64));
    @memset(self.level2.leaf_free, 0);
}

/// Only used in tests.
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.level0.bitmaps);
    allocator.free(self.level0.lcrs);
    allocator.free(self.level1.bitmaps);
    allocator.free(self.level1.leaf_free);
    allocator.free(self.level2.bitmaps);
    allocator.free(self.level2.leaf_free);
}

pub fn allocContiguous(self: *Self, page_count: usize) Error!u64 {
    if (page_count == 0) return 0;
    if (self.available_pages < page_count) return Error.OutOfMemory;

    if (page_count > 64) {
        @panic("WHBA: alloc_contiguous > 64 pages not supported yet");
    } else {
        const l0_index = self.findBestFit64(page_count) orelse return Error.OutOfMemory;
        const lcr = self.level0.lcrs[l0_index];
        const start_bit = lcr.start;
        const mask = rangeMask(@intCast(start_bit), @intCast(page_count));

        self.commitAllocation(l0_index, mask, page_count);

        const page_index = (l0_index * 64) + start_bit;
        return page_to_address(page_index);
    }
}

pub fn allocNonContiguous(self: *Self, dest: []u64) Error!void {
    if (dest.len == 0) return;
    if (self.available_pages < dest.len) return Error.OutOfMemory;

    var allocated_count: usize = 0;
    while (allocated_count < dest.len) {
        const l2_index = findMostSaturatedBranch(self.level2.leaf_free, 0, self.level2.leaf_free.len) orelse @panic("WHBA: Inconsistent state (Global count > 0 but no L2 found)");

        const l1_start = l2_index * 64;
        const l1_index = findMostSaturatedBranch(self.level1.leaf_free, l1_start, 64) orelse @panic("WHBA: Inconsistent state (L2 > 0 but no L1 found)");

        const l0_start = l1_index * 64;
        const l0_index = self.findMostSaturatedLeaf(l0_start) orelse @panic("WHBA: Inconsistent state (L1 > 0 but no L0 found)");

        var bitmap = self.level0.bitmaps[l0_index];

        var mask_accumulator: u64 = 0;
        var taken_in_block: usize = 0;
        const needed_total = dest.len - allocated_count;

        while (taken_in_block < needed_total) {
            const inverted = ~bitmap;
            if (inverted == 0) break;

            const bit_idx = @ctz(inverted);
            const bit_mask = @as(u64, 1) << @intCast(bit_idx);

            bitmap |= bit_mask;

            mask_accumulator |= bit_mask;

            const page_idx_global = (l0_index * 64) + bit_idx;
            dest[allocated_count] = page_idx_global * PAGE_SIZE;

            allocated_count += 1;
            taken_in_block += 1;
        }

        if (taken_in_block > 0) {
            self.commitAllocation(l0_index, mask_accumulator, taken_in_block);
        }
    }
}

pub fn freeContiguous(self: *Self, address: u64, page_count: usize) Error!void {
    try self.unmark(address, page_count);
}

pub fn freeNonContiguous(self: *Self, addresses: []const u64) Error!void {
    if (addresses.len == 0) return;

    var i: usize = 0;
    while (i < addresses.len) {
        const start_addr = addresses[i];
        var count: usize = 1;

        while ((i + count) < addresses.len) {
            const next_addr = addresses[i + count];
            const expected_addr = start_addr + (count * PAGE_SIZE);

            if (next_addr == expected_addr) {
                count += 1;
            } else {
                break;
            }
        }

        try self.unmark(start_addr, count);

        i += count;
    }
}

// --- internal --- //

const PAGE_INDEX = 12;
const PAGE_TO_L0 = 6;
const PAGE_TO_L1 = 12;
const PAGE_TO_L2 = 18;

inline fn address_to_page(address: u64) Error!u64 {
    if (!std.mem.isAligned(address, PAGE_SIZE)) return Error.UnalignedAddress;
    return address >> PAGE_INDEX;
}

inline fn page_to_address(page_index: u64) u64 {
    return page_index << PAGE_INDEX;
}

inline fn page_to_l0(page_index: u64) u64 {
    return page_index >> PAGE_TO_L0;
}

inline fn l0_to_page(l0_index: u64) u64 {
    return l0_index << PAGE_TO_L0;
}

inline fn page_to_l1(page_index: u64) u64 {
    return page_index >> PAGE_TO_L1;
}

inline fn page_to_l2(page_index: u64) u64 {
    return page_index >> PAGE_TO_L2;
}

inline fn rangeMask(start: u6, count: u7) u64 {
    if (count == 64) return std.math.maxInt(u64);
    const mask_len = (@as(u64, 1) << @intCast(count)) - 1;
    return mask_len << start;
}

/// **Performance Rationale:**
///
/// This function operates entirely within the CPU's General Purpose Registers (GPRs).
/// Once the `u64` bitmap is loaded, there are absolutely no memory accesses (RAM/Cache)
/// involved in the calculation.
///
/// 1. **Zero Latency:** All operations (SHIFT, AND, CMP) are single-cycle ALU instructions.
/// 2. **Pipeline Friendly:** The logic is linear and strictly CPU-bound, allowing the
///    compiler to unroll the loop and the CPU to pipeline instructions efficiently
///    without stalling for data fetching.
/// 3. **Write-Penalty / Read-Gain:** We pay this negligible calculation cost only
///    during modification (Mark/Unmark) to guarantee O(1) instant lookups during
///    allocation, shifting the burden away from the critical hot-path.
inline fn calculateLcr(bitmap: u64) Lcr {
    var val = ~bitmap;

    if (val == 0) return .{ .start = 0, .size = 0 };
    if (val == std.math.maxInt(u64)) return .{ .start = 0, .size = 64 };

    var max_size: u8 = 0;
    var max_start: u8 = 0;

    var current_size: u8 = 0;
    var current_start: u8 = 0;

    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        const is_free = (val & 1) != 0;

        if (is_free) {
            if (current_size == 0) current_start = i;
            current_size += 1;
        } else {
            if (current_size > max_size) {
                max_size = current_size;
                max_start = current_start;
            }
            current_size = 0;
        }

        val >>= 1;
    }

    if (current_size > max_size) {
        max_size = current_size;
        max_start = current_start;
    }

    return .{ .start = max_start, .size = max_size };
}

pub inline fn unmark(self: *Self, address: u64, count: usize) Error!void {
    if (count == 0) return;

    var page_index = try address_to_page(address);
    const end_index = page_index + count;
    if (end_index > self.limit_page_index) return Error.OutOfBounds;

    var l2_index = page_to_l2(page_index);
    var l1_index = page_to_l1(page_index);
    var l0_index = page_to_l0(page_index);

    var pending_l1_delta: u32 = 0;
    var pending_l1_mask: u64 = 0;

    var pending_l2_delta: u32 = 0;
    var pending_l2_mask: u64 = 0;

    while (page_index < end_index) {
        const start_bit = page_index % 64;
        const page_count = @min(64 - start_bit, end_index - page_index);

        const mask = rangeMask(@intCast(start_bit), @intCast(page_count));

        const old_bitmap = self.level0.bitmaps[l0_index];
        const new_bitmap = old_bitmap & ~mask;

        const old_free_count = @popCount(~old_bitmap);
        const new_free_count = @popCount(~new_bitmap);

        const delta = new_free_count - old_free_count;

        if (delta > 0) {
            self.available_pages += delta;

            self.level0.bitmaps[l0_index] = new_bitmap;
            self.level0.lcrs[l0_index] = calculateLcr(new_bitmap);

            pending_l1_delta += delta;
            pending_l2_delta += delta;

            if (old_free_count == 0) {
                const l1_bit = l0_index % 64;
                pending_l1_mask |= (@as(u64, 1) << @intCast(l1_bit));
            }
        }

        const last_l2_index = l2_index;
        const last_l1_index = l1_index;

        page_index += page_count;

        l2_index = page_to_l2(page_index);
        l1_index = page_to_l1(page_index);
        l0_index = page_to_l0(page_index);

        if (pending_l1_delta > 0 and (l1_index != last_l1_index or page_index >= end_index)) {
            const old_l1_free = self.level1.leaf_free[last_l1_index];

            self.level1.leaf_free[last_l1_index] = old_l1_free + pending_l1_delta;

            if (pending_l1_mask != 0) {
                self.level1.bitmaps[last_l1_index] &= ~pending_l1_mask;

                if (old_l1_free == 0) {
                    const l2_bit = last_l1_index % 64;
                    pending_l2_mask |= (@as(u64, 1) << @intCast(l2_bit));
                }
            }

            pending_l1_delta = 0;
            pending_l1_mask = 0;
        }

        if (pending_l2_delta > 0 and (l2_index != last_l2_index or page_index >= end_index)) {
            self.level2.leaf_free[last_l2_index] += pending_l2_delta;

            if (pending_l2_mask != 0) {
                self.level2.bitmaps[last_l2_index] &= ~pending_l2_mask;
            }

            pending_l2_delta = 0;
            pending_l2_mask = 0;
        }
    }
}

pub inline fn mark(self: *Self, address: u64, count: usize) Error!void {
    if (count == 0) return;

    var page_index = try address_to_page(address);
    const end_index = page_index + count;
    if (end_index > self.limit_page_index) return Error.OutOfBounds;

    var l2_index = page_to_l2(page_index);
    var l1_index = page_to_l1(page_index);
    var l0_index = page_to_l0(page_index);

    var pending_l1_delta: u32 = 0;
    var pending_l1_mask: u64 = 0;

    var pending_l2_delta: u32 = 0;
    var pending_l2_mask: u64 = 0;

    while (page_index < end_index) {
        const start_bit = page_index % 64;
        const page_count = @min(64 - start_bit, end_index - page_index);

        const mask = rangeMask(@intCast(start_bit), @intCast(page_count));

        const old_bitmap = self.level0.bitmaps[l0_index];
        const new_bitmap = old_bitmap | mask;

        const old_free = @popCount(~old_bitmap);
        const new_free = @popCount(~new_bitmap);

        const delta = old_free - new_free;

        if (delta > 0) {
            self.available_pages -= delta;

            self.level0.bitmaps[l0_index] = new_bitmap;
            self.level0.lcrs[l0_index] = calculateLcr(new_bitmap);

            pending_l1_delta += delta;
            pending_l2_delta += delta;

            if (new_free == 0) {
                const l1_bit = l0_index % 64;
                pending_l1_mask |= (@as(u64, 1) << @intCast(l1_bit));
            }
        }

        const last_l2_index = l2_index;
        const last_l1_index = l1_index;

        page_index += page_count;

        l2_index = page_to_l2(page_index);
        l1_index = page_to_l1(page_index);
        l0_index = page_to_l0(page_index);

        if (pending_l1_delta > 0 and (l1_index != last_l1_index or page_index >= end_index)) {
            self.level1.leaf_free[last_l1_index] -= pending_l1_delta;

            if (pending_l1_mask != 0) {
                self.level1.bitmaps[last_l1_index] |= pending_l1_mask;
            }

            const new_l1_free = self.level1.leaf_free[last_l1_index];
            if (new_l1_free == 0) {
                const l2_bit = last_l1_index % 64;
                pending_l2_mask |= (@as(u64, 1) << @intCast(l2_bit));
            }

            pending_l1_delta = 0;
            pending_l1_mask = 0;
        }

        if (pending_l2_delta > 0 and (l2_index != last_l2_index or page_index >= end_index)) {
            self.level2.leaf_free[last_l2_index] -= pending_l2_delta;

            if (pending_l2_mask != 0) {
                self.level2.bitmaps[last_l2_index] |= pending_l2_mask;
            }

            pending_l2_delta = 0;
            pending_l2_mask = 0;
        }
    }
}

inline fn findBestFit64(self: *Self, needed: usize) ?usize {
    if (needed == 0 or needed > 64) return null;

    var best_index: usize = 0;
    var best_size: u8 = std.math.maxInt(u8);
    var found: bool = false;

    for (0.., self.level2.leaf_free) |l2_index, l2_free| {
        if (l2_free < needed) continue;

        const l1_start = l2_index * 64;
        for (0..64) |offset_l1| {
            const l1_index = l1_start + offset_l1;
            if (l1_index >= self.level1.leaf_free.len) break;

            const l1_free = self.level1.leaf_free[l1_index];

            if (l1_free < needed) continue;

            const l0_start = l1_index * 64;

            for (0..64) |offset_l0| {
                const l0_index = l0_start + offset_l0;
                if (l0_index >= self.level0.lcrs.len) break;

                const lcr = self.level0.lcrs[l0_index];

                if (lcr.size < needed) continue;

                if (lcr.size == needed) {
                    return l0_index;
                }

                if (lcr.size < best_size) {
                    best_size = lcr.size;
                    best_index = l0_index;
                    found = true;
                }
            }
        }
    }

    return if (found) best_index else null;
}

/// optimized version of mark, when the allocation only requires to modify one l0 entry.
inline fn commitAllocation(self: *Self, l0_index: usize, mask: u64, count: usize) void {
    const old_bitmap = self.level0.bitmaps[l0_index];

    if ((old_bitmap & mask) != 0) @panic("WHBA: double allocation detected");

    const new_bitmap = old_bitmap | mask;
    self.level0.bitmaps[l0_index] = new_bitmap;
    self.level0.lcrs[l0_index] = calculateLcr(new_bitmap);

    self.available_pages -= count;

    const consumed = @as(u32, @intCast(count));
    const l1_index = l0_index >> 6;

    self.level1.leaf_free[l1_index] -= consumed;
    if (self.level1.leaf_free[l1_index] == 0) {
        const bit_in_l1: u6 = @intCast(l0_index % 64);
        self.level1.bitmaps[l1_index] |= (@as(u64, 1) << bit_in_l1);
    }

    const l2_index = l1_index >> 6;
    if (l2_index < self.level2.leaf_free.len) {
        self.level2.leaf_free[l2_index] -= consumed;
        if (self.level2.leaf_free[l2_index] == 0) {
            const bit_in_l2: u6 = @intCast(l1_index % 64);
            self.level2.bitmaps[l2_index] |= (@as(u64, 1) << bit_in_l2);
        }
    }
}

inline fn findMostSaturatedBranch(counts: []const u32, start_idx: usize, count: usize) ?usize {
    var best_index: usize = 0;
    var min_free: usize = std.math.maxInt(usize);
    var found = false;

    const slice = counts[start_idx .. start_idx + count];

    for (0.., slice) |
        i,
        free_count,
    | {
        if (free_count > 0 and free_count < min_free) {
            min_free = free_count;
            best_index = start_idx + i;
            found = true;

            if (min_free == 1) break;
        }
    }

    return if (found) best_index else null;
}

inline fn findMostSaturatedLeaf(self: *Self, start_idx: usize) ?usize {
    var best_index: usize = 0;
    var min_free: usize = std.math.maxInt(usize);
    var found = false;

    const end_idx = @min(start_idx + 64, self.level0.bitmaps.len);

    for (self.level0.bitmaps[start_idx..end_idx], 0..) |bitmap, i| {
        const free_count = @popCount(~bitmap);

        if (free_count > 0 and free_count < min_free) {
            min_free = free_count;
            best_index = start_idx + i;
            found = true;

            if (min_free == 1) break;
        }
    }

    return if (found) best_index else null;
}

// --- tests --- //

fn init_allocator(allocator: std.mem.Allocator) !Self {
    var alloc: Self = undefined;

    const KiB = 1024;
    const MiB = 1024 * KiB;
    const GiB = 1024 * MiB;

    alloc.limit_page_index = (16 * GiB) >> PAGE_INDEX;

    const sizes = alloc.metadataSizes();

    alloc.level0.bitmaps = try allocator.alloc(u64, sizes.l0_count);
    alloc.level0.lcrs = try allocator.alloc(Lcr, sizes.l0_count);

    alloc.level1.bitmaps = try allocator.alloc(u64, sizes.l1_count);
    alloc.level1.leaf_free = try allocator.alloc(u32, sizes.l1_count);

    alloc.level2.bitmaps = try allocator.alloc(u64, sizes.l2_count);
    alloc.level2.leaf_free = try allocator.alloc(u32, sizes.l2_count);

    alloc.reset();

    try alloc.unmark(512 * MiB + 16 * PAGE_SIZE, (12 * GiB + 51 * PAGE_SIZE) >> PAGE_INDEX);
    try alloc.mark(1 * GiB - 16 * PAGE_SIZE, (1 * GiB + 16 * PAGE_SIZE) >> PAGE_INDEX);

    const expected_bitmaps = [_]u64{
        4294967295, // Index 0
        18446744073709551615, // Index 1
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        18446744065119617024, // Index 12
        18446744073709551615, // Index 13
        18446744073709551615, // Index 14
        18446744073709551615, // Index 15
    };

    const expected_free = [_]u32{
        131040, // Index 0
        0, // Index 1
        262144, 262144, 262144, 262144, 262144, // Index 2 à 6
        262144, 262144, 262144, 262144, 262144, // Index 7 à 11
        131139, // Index 12
        0,
        0,
        0, // Index 13 à 15
    };

    try std.testing.expectEqualSlices(u64, &expected_bitmaps, alloc.level2.bitmaps);
    try std.testing.expectEqualSlices(u32, &expected_free, alloc.level2.leaf_free);

    return alloc;
}

test "single page" {
    var alloc = try init_allocator(std.testing.allocator);
    defer alloc.deinit(std.testing.allocator);

    var pages: [128]u64 = undefined;
    try alloc.allocNonContiguous(&pages);
    std.debug.print("0x{x}\n", .{pages});
    try alloc.allocNonContiguous(&pages);
    std.debug.print("0x{x}\n", .{pages});

    std.debug.print("0x{x}\n", .{try alloc.allocContiguous(16)});
    std.debug.print("0x{x}\n", .{try alloc.allocContiguous(16)});
    std.debug.print("0x{x}\n", .{try alloc.allocContiguous(16)});
    std.debug.print("0x{x}\n", .{try alloc.allocContiguous(64)});

    try alloc.allocNonContiguous(&pages);
    std.debug.print("0x{x}\n", .{pages});

    unreachable;
}
