// --- dependencies --- //

const std = @import("std");

// --- imports --- //

const kernel = @import("root");

const boot = kernel.boot;
const mem = kernel.mem;
const PageLevel = mem.PageLevel;

// --- mem/phys.zig --- //

var bitmap_4k: []u64 = undefined;
var bitmap_2m: []u64 = undefined;
var bitmap_1g: []u64 = undefined;

var counter_2m: []u16 = undefined;
var counter_1g: []u16 = undefined;
var counter_1g_4k: []u32 = undefined;

var page_count_4k: u64 = 0;
var page_count_2m: u64 = 0;
var page_count_1g: u64 = 0;

var base_usable_address: u64 = 0;
var max_usable_address: u64 = 0;

var total_pages: u64 = 0;
var available_pages: u64 = 0;
var used_pages: u64 = 0;

inline fn get_bitmap(level: PageLevel) []u64 {
    return switch (level) {
        .l4K => bitmap_4k,
        .l2M => bitmap_2m,
        .l1G => bitmap_1g,
    };
}

inline fn read_bitmap(page_index: u64, level: PageLevel) bool {
    const bitmap = get_bitmap(level);
    const bit_index = page_index % 64;
    const word_index = page_index / 64;
    const word = bitmap[word_index];
    const mask: u64 = @as(u64, 1) << @as(u6, @intCast(bit_index));
    return (word & mask) != 0;
}

inline fn write_bitmap(page_index: u64, level: PageLevel, value: bool) void {
    const bitmap = get_bitmap(level);
    const bit_index = page_index % 64;
    const word_index = page_index / 64;

    const mask: u64 = @as(u64, 1) << @as(u6, @intCast(bit_index));
    if (value) {
        bitmap[word_index] |= mask;
    } else {
        bitmap[word_index] &= ~mask;
    }
}

pub inline fn available_memory() u64 {
    return available_pages << PageLevel.l4K.shift();
}

pub inline fn used_memory() u64 {
    return used_pages << PageLevel.l4K.shift();
}

inline fn is_page_used(page_index: u64, level: PageLevel) bool {
    return switch (level) {
        .l1G => read_bitmap(page_index, .l1G),
        .l2M => read_bitmap(page_index, .l2M) or
            (read_bitmap(page_index >> 9, .l1G) and counter_1g[page_index >> 9] == 0),
        .l4K => read_bitmap(page_index, .l4K) or
            (read_bitmap(page_index >> 9, .l2M) and counter_2m[page_index >> 9] == 0) or
            (read_bitmap(page_index >> 18, .l1G) and counter_1g[page_index >> 18] == 0),
    };
}

inline fn is_page_available(index: u64, level: PageLevel) bool {
    return !is_page_used(index, level);
}

inline fn is_page_primary(page_index: u64, level: PageLevel) bool {
    return switch (level) {
        .l1G => read_bitmap(page_index, .l1G) and counter_1g[page_index] == 0,
        .l2M => read_bitmap(page_index, .l2M) and counter_2m[page_index] == 0,
        .l4K => read_bitmap(page_index, .l4K),
    };
}

inline fn is_page_secondary(page_index: u64, level: PageLevel) bool {
    return is_page_used(page_index, level) and !is_page_primary(page_index, level);
}

inline fn is_page_sub_available(page_index: u64, level: PageLevel) bool {
    return is_page_available(page_index, level) or is_page_secondary(page_index, level);
}

inline fn mark_page(page_index: u64, level: PageLevel) void {
    if (is_page_used(page_index, level)) return;

    const num_4k = level.size() >> 12;
    available_pages -= num_4k;
    used_pages += num_4k;

    var current_level = level;
    var index = page_index;
    while (true) {
        write_bitmap(index, current_level, true);

        const parent_index = index >> 9;

        switch (current_level) {
            .l4K => {
                counter_2m[parent_index] += 1;
                counter_1g_4k[parent_index >> 9] += 1;
                if (counter_2m[parent_index] == 1) {
                    current_level = .l2M;
                    index = parent_index;
                    continue;
                }
            },
            .l2M => {
                counter_1g[parent_index] += 1;
                if (counter_1g[parent_index] == 1) {
                    current_level = .l1G;
                    index = parent_index;
                    continue;
                }
            },
            .l1G => {},
        }

        break;
    }
}

inline fn unmark_page(page_index: u64, level: PageLevel) void {
    if (!is_page_used(page_index, level)) return;
    if (!is_page_primary(page_index, level)) return;

    const num_4k = level.size() >> 12;
    available_pages += num_4k;
    used_pages -= num_4k;

    var current_level = level;
    var index = page_index;
    while (true) {
        write_bitmap(index, current_level, false);

        const parent_index = index >> 9;

        switch (current_level) {
            .l4K => {
                counter_2m[parent_index] -= 1;
                counter_1g_4k[parent_index >> 9] -= 1;
                if (counter_2m[parent_index] == 0) {
                    current_level = .l2M;
                    index = parent_index;
                    continue;
                }
            },
            .l2M => {
                counter_1g[parent_index] -= 1;
                if (counter_1g[parent_index] == 0) {
                    current_level = .l1G;
                    index = parent_index;
                    continue;
                }
            },
            .l1G => {},
        }

        break;
    }
}

pub const AllocError = error{
    OutOfMemory,
    OutOfContiguousMemory,
    InvalidAlignment,
};

inline fn check_memory_availability(length: usize, level: PageLevel) AllocError!void {
    const length_4k = switch (level) {
        .l4K => length,
        .l2M => length << 9,
        .l1G => length << 18,
    };

    if (length_4k > available_pages) {
        return AllocError.OutOfMemory;
    }
}

inline fn check_alignment(address: u64, level: PageLevel) AllocError!void {
    if (!std.mem.isAligned(address, level.size())) {
        return AllocError.InvalidAlignment;
    }
}

fn alloc_page(level: PageLevel, reset: bool) AllocError!u64 {
    var pages: [1]u64 = undefined;
    try alloc_noncontiguous_pages(&pages, level, reset);
    return pages[0];
}

fn free_page(address: u64, level: PageLevel) void {
    unmark_page(address >> level.shift(), level);
}

fn alloc_noncontiguous_pages(pages: []u64, level: PageLevel, reset: bool) AllocError!void {
    if (pages.len == 0) return;

    try check_memory_availability(pages.len, level);

    var i: usize = 0;

    switch (level) {
        .l1G => {
            for (0..page_count_1g) |page_index| {
                if (is_page_available(page_index, level)) {
                    mark_page(page_index, level);
                    pages[i] = page_index << level.shift();
                    if (reset) @memset(@as([*]u8, @ptrFromInt(kernel.boot.hhdm_base + pages[i]))[0..level.size()], 0);
                    i += 1;
                    if (i == pages.len) return;
                }
            }
        },
        .l2M => {
            while (i < pages.len) {
                var hotspot_max: u64 = 0;
                var hotspot_index: u64 = 0;
                var hotspot_set = false;

                for (0..page_count_1g) |page_index| {
                    const count_2m = counter_1g[page_index];
                    if (is_page_sub_available(page_index, .l1G) and count_2m < 512 and (count_2m > hotspot_max or !hotspot_set)) {
                        hotspot_index = page_index;
                        hotspot_max = count_2m;
                        hotspot_set = true;
                    }
                }

                if (!hotspot_set) break;

                for (0..512) |idx| {
                    const page_index = (hotspot_index << 9) | idx;
                    if (is_page_available(page_index, level)) {
                        mark_page(page_index, level);
                        pages[i] = page_index << level.shift();
                        if (reset) @memset(@as([*]u8, @ptrFromInt(kernel.boot.hhdm_base + pages[i]))[0..level.size()], 0);
                        i += 1;
                        if (i == pages.len) return;
                    }
                }
            }
        },
        .l4K => {
            while (i < pages.len) {
                var hotspot_max_1g: u64 = 0;
                var hotspot_index_1g: u64 = 0;
                var hotspot_set_1g = false;

                for (0..page_count_1g) |idx| {
                    const count_1g_4k = counter_1g_4k[idx];
                    if (is_page_sub_available(idx, .l1G) and count_1g_4k < 512 * 512 and (count_1g_4k > hotspot_max_1g or !hotspot_set_1g)) {
                        hotspot_max_1g = count_1g_4k;
                        hotspot_index_1g = idx;
                        hotspot_set_1g = true;
                    }
                }

                if (!hotspot_set_1g) break;

                while (i < pages.len) {
                    var hotspot_max_2m: u64 = 0;
                    var hotspot_index_2m: u64 = 0;
                    var hotspot_set_2m = false;

                    for (0..512) |idx| {
                        const page_index = (hotspot_index_1g << 9) | idx;
                        if (is_page_sub_available(page_index, .l2M) and counter_2m[page_index] < 512 and (counter_2m[page_index] > hotspot_max_2m or !hotspot_set_2m)) {
                            hotspot_max_2m = counter_2m[page_index];
                            hotspot_index_2m = page_index;
                            hotspot_set_2m = true;
                        }
                    }

                    if (!hotspot_set_2m) break;

                    for (0..512) |idx| {
                        const page_index = (hotspot_index_2m << 9) | idx;
                        if (is_page_available(page_index, level)) {
                            mark_page(page_index, level);
                            pages[i] = page_index << level.shift();
                            if (reset) @memset(@as([*]u8, @ptrFromInt(kernel.boot.hhdm_base + pages[i]))[0..level.size()], 0);
                            i += 1;
                            if (i == pages.len) return;
                        }
                    }
                }
            }
        },
    }

    free_noncontiguous_pages(pages[0..i], level);

    return AllocError.OutOfContiguousMemory;
}

fn free_noncontiguous_pages(pages: []u64, level: PageLevel) void {
    for (pages) |page_addr| {
        unmark_page(page_addr >> level.shift(), level);
    }
}

pub fn allocContiguousPages(length: usize, level: PageLevel, length_align: bool) AllocError!u64 {
    phys_lock.lock();
    defer phys_lock.unlock();

    if (length == 0) return 0;

    try check_memory_availability(length, level);

    if (length > 1) {
        // TODO this version is highly unoptimized, doesn't use the counters..

        const page_count = switch (level) {
            .l1G => page_count_1g,
            .l2M => page_count_2m,
            .l4K => page_count_4k,
        };

        var i: usize = 0;
        while (i < page_count) : (i += 1) {
            if (length_align and (i % length != 0)) continue;

            var run: usize = 0;

            while (i + run < page_count and is_page_available(i + run, level)) {
                run += 1;
                if (run == length) {
                    for (0..length) |j| {
                        mark_page(i + j, level);
                    }
                    return i << level.shift();
                }
            }

            i += run;
        }

        return AllocError.OutOfContiguousMemory;
    } else if (length == 1) {
        return alloc_page(level, false);
    }

    return 0;
}

pub fn freeContiguousPages(address: u64, length: usize, level: PageLevel) void {
    phys_lock.lock();
    defer phys_lock.unlock();

    const addr = address >> level.shift();
    var offset: usize = 0;
    while (offset < length) : (offset += 1) {
        unmark_page(addr + offset, level);
    }
}

pub fn init() !void {
    var memory_iter = boot.UsableMemoryIterator{};

    var is_base_set = false;
    while (memory_iter.next()) |entry| {
        const original_base = entry.physical_base.*;
        entry.physical_base.* = std.mem.alignForward(u64, entry.physical_base.*, PageLevel.l4K.size());
        var entry_length = entry.number_of_pages.* << PageLevel.l4K.shift();
        entry_length = entry_length - (entry.physical_base.* - original_base);
        entry_length = std.mem.alignBackward(u64, entry_length, PageLevel.l4K.size());
        entry.number_of_pages.* = entry_length >> PageLevel.l4K.shift();

        if (is_base_set) {
            if (entry.physical_base.* < base_usable_address) {
                base_usable_address = entry.physical_base.*;
            }
        } else {
            is_base_set = true;
            base_usable_address = entry.physical_base.*;
        }

        const end_addr = entry.physical_base.* + entry_length;
        if (end_addr > max_usable_address) {
            max_usable_address = end_addr;
        }
    }

    max_usable_address = std.mem.alignForward(u64, max_usable_address, PageLevel.l1G.size());

    page_count_4k = max_usable_address >> PageLevel.l4K.shift();
    page_count_2m = max_usable_address >> PageLevel.l2M.shift();
    page_count_1g = max_usable_address >> PageLevel.l1G.shift();

    const len_4k = (page_count_4k + 63) / 64;
    const len_2m = (page_count_2m + 63) / 64;
    const len_1g = (page_count_1g + 63) / 64;

    const maps_page_count = std.mem.alignForward(
        u64,
        len_4k * @sizeOf(u64) +
            len_2m * @sizeOf(u64) +
            len_1g * @sizeOf(u64) +
            page_count_2m * @sizeOf(u16) +
            page_count_1g * @sizeOf(u16) +
            page_count_1g * @sizeOf(u32) +
            @sizeOf(u128) * 6, // headroom for alignment
        PageLevel.l4K.size(),
    ) >> PageLevel.l4K.shift();

    memory_iter = .{};
    while (memory_iter.next()) |entry| {
        if (entry.number_of_pages.* > maps_page_count) {
            var alloc_base = boot.hhdm_base + entry.physical_base.*;

            bitmap_4k.ptr = @ptrFromInt(std.mem.alignForward(usize, alloc_base, @alignOf(u128)));
            bitmap_4k.len = len_4k;
            @memset(bitmap_4k, 0xffff_ffff_ffff_ffff);

            alloc_base = @intFromPtr(bitmap_4k.ptr) + bitmap_4k.len * @sizeOf(u64);

            bitmap_2m.ptr = @ptrFromInt(std.mem.alignForward(usize, alloc_base, @alignOf(u128)));
            bitmap_2m.len = len_2m;
            @memset(bitmap_2m, 0);

            alloc_base = @intFromPtr(bitmap_2m.ptr) + bitmap_2m.len * @sizeOf(u64);

            bitmap_1g.ptr = @ptrFromInt(std.mem.alignForward(usize, alloc_base, @alignOf(u128)));
            bitmap_1g.len = len_1g;
            @memset(bitmap_1g, 0);

            alloc_base = @intFromPtr(bitmap_1g.ptr) + bitmap_1g.len * @sizeOf(u64);

            counter_2m.ptr = @ptrFromInt(std.mem.alignForward(usize, alloc_base, @alignOf(u128)));
            counter_2m.len = page_count_2m;
            @memset(counter_2m, 0);

            alloc_base = @intFromPtr(counter_2m.ptr) + counter_2m.len * @sizeOf(u16);

            counter_1g.ptr = @ptrFromInt(std.mem.alignForward(usize, alloc_base, @alignOf(u128)));
            counter_1g.len = page_count_1g;
            @memset(counter_1g, 0);

            alloc_base = @intFromPtr(counter_1g.ptr) + counter_1g.len * @sizeOf(u16);

            counter_1g_4k.ptr = @ptrFromInt(std.mem.alignForward(usize, alloc_base, @alignOf(u128)));
            counter_1g_4k.len = page_count_1g;
            @memset(counter_1g_4k, 0);

            alloc_base = @intFromPtr(counter_1g_4k.ptr) + counter_1g_4k.len * @sizeOf(u32);

            const new_base = std.mem.alignForward(usize, alloc_base - boot.hhdm_base, PageLevel.l4K.size());
            if (entry.physical_base.* == base_usable_address) {
                base_usable_address = new_base;
            }
            entry.number_of_pages.* -= (std.mem.alignForward(u64, (new_base - entry.physical_base.*), 0x1000) >> PageLevel.l4K.shift());
            entry.physical_base.* = new_base;

            break;
        }
    }

    // configure bitmap_4k
    memory_iter = .{};
    while (memory_iter.next()) |entry| {
        var page_index = entry.physical_base.* >> PageLevel.l4K.shift();
        const page_end = page_index + entry.number_of_pages.*;
        while (page_index < page_end) : (page_index += 1) {
            write_bitmap(page_index, .l4K, false);
            total_pages += 1;
        }
    }

    available_pages = total_pages;

    // configure counter_2m & bitmap_2m
    for (0..page_count_2m) |page_index_2m| {
        const page_index_1g = page_index_2m >> 9;
        for (0..512) |idx| {
            const page_index_4k = (page_index_2m << 9) | idx;
            const page_used_4k = read_bitmap(page_index_4k, .l4K);
            if (page_used_4k) {
                counter_2m[page_index_2m] += 1;
                counter_1g_4k[page_index_1g] += 1;
            }
        }
        if (counter_2m[page_index_2m] > 0) write_bitmap(page_index_2m, .l2M, true);
    }

    // configure counter_1g & bitmap_1g
    for (0..page_count_1g) |page_index_1g| {
        for (0..512) |idx| {
            const page_index_2m = (page_index_1g << 9) | idx;
            const page_used_2m = read_bitmap(page_index_2m, .l2M);
            if (page_used_2m) counter_1g[page_index_1g] += 1;
        }
        if (counter_1g[page_index_1g] > 0) write_bitmap(page_index_1g, .l1G, true);
    }
}

var phys_lock: mem.SpinLock = .{};

pub fn initCpu() AllocError!void {
    try reloadCache();
}

fn reloadCache() AllocError!void {
    const cpu = kernel.arch.Cpu.get();

    {
        phys_lock.lock();
        defer phys_lock.unlock();
        try alloc_noncontiguous_pages(&cpu.primary_4k_cache, .l4K, true);
    }

    cpu.primary_4k_cache_pos = 0;
}

pub fn allocPage(level: PageLevel, reset: bool) AllocError!u64 {
    const cpu = kernel.arch.Cpu.get();

    switch (level) {
        .l4K => {
            if (cpu.recycle_4k_cache_num > 0) {
                cpu.recycle_4k_cache_num -= 1;
                return cpu.recycle_4k_cache[cpu.recycle_4k_cache_num];
            }

            if (cpu.primary_4k_cache_pos >= 128) try reloadCache();
            defer cpu.primary_4k_cache_pos += 1;
            return cpu.primary_4k_cache[cpu.primary_4k_cache_pos];
        },
        .l2M, .l1G => {
            phys_lock.lock();
            defer phys_lock.unlock();

            return alloc_page(level, reset);
        },
    }
}

pub fn freePage(address: u64, level: PageLevel) void {
    @memset(@as([*]u8, @ptrFromInt(kernel.boot.hhdm_base + address))[0..level.size()], 0);

    const cpu = kernel.arch.Cpu.get();

    switch (level) {
        .l4K => {
            cpu.recycle_4k_cache[cpu.recycle_4k_cache_num] = address;
            cpu.recycle_4k_cache_num += 1;

            if (cpu.recycle_4k_cache_num >= 128) {
                cpu.recycle_4k_cache_num = 0;

                phys_lock.lock();
                defer phys_lock.unlock();

                free_noncontiguous_pages(&cpu.recycle_4k_cache, .l4K);
            }
        },
        .l2M, .l1G => {
            phys_lock.lock();
            defer phys_lock.unlock();

            return free_page(address, level);
        },
    }
}
