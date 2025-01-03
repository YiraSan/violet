//! This is a very very very simple implementation, I will do something more fancy later

const std = @import("std");

const boot = @import("../boot/boot.zig");

var usable: u64 = 0;
var reserved: u64 = 0;
var total: u64 = 0;

pub const PAGE_SIZE = 4 * 1024; // 4 KiB

var bitmap: []u8 = undefined;

inline fn readbit(index: u64) bool {
    const byte_index = index / 8;
    const bit_offset = index % 8;

    const byte = bitmap[byte_index];
    return (byte & (@as(u8, 1) << @intCast(bit_offset))) != 0;
}

inline fn writebit(index: u64, value: bool) void {
    const byte_index = index / 8;
    const bit_offset = index % 8;

    if (value) {
        bitmap[byte_index] |= (@as(u8, 1) << @intCast(bit_offset));
    } else {
        bitmap[byte_index] &= ~(@as(u8, 1) << @intCast(bit_offset));
    }
}

inline fn physicalToIndex(physical: u64) u64 {
    return physical / PAGE_SIZE; // (optimizer change that to >> 12)
}

inline fn pageCount(length: u64) u64 {
    return length / PAGE_SIZE + @intFromBool(length % PAGE_SIZE != 0); 
} 

var size_name: []const u8 = undefined;
var size: u64 = 0;

var mutex: std.Thread.Mutex = undefined;

fn resize(value: u64) void {
    if (value >= 2 * std.math.pow(u64, 1024, 3)) {
        size_name = "GiB";
        size = std.math.pow(u64, 1024, 3);
    } else if (value >= 2 * std.math.pow(u64, 1024, 2)) {
        size_name = "MiB";
        size = std.math.pow(u64, 1024, 2);
    } else if (value >= 2 * std.math.pow(u64, 1024, 1)) {
        size_name = "KiB";
        size = std.math.pow(u64, 1024, 1); 
    } else {
        size_name = "B";
        size = 1;
    }
}

pub fn init() void {
    mutex = .{};

    const entries = boot.memory_map.entries();

    var usable_memory_base: u64 = 0;
    for (entries) |entry| {
        switch (entry.kind) {
            .usable => {
                if (usable_memory_base == 0) {
                    usable_memory_base = entry.base;
                }
                usable += entry.length;
            },
            else => reserved += entry.length,
        }
        total += entry.length;
    }

    const page_number = total / PAGE_SIZE;

    for (entries) |entry| {
        switch (entry.kind) {
            .usable => {
                if (entry.length * 8 >= page_number) {
                    bitmap.ptr = @ptrFromInt(boot.hhdm.offset + entry.base);
                    bitmap.len = page_number / 8 + 1;
                    @memset(bitmap, 0);

                    const bitmap_page_count = pageCount(bitmap.len);
                    const bitmap_index = physicalToIndex(entry.base-usable_memory_base);

                    for (0..bitmap_page_count) |i| {
                        writebit(bitmap_index+i, true);
                        usable -= PAGE_SIZE;
                    }

                    break;
                }
            },
            else => {},
        }
    }

    resize(total);
    std.log.info("total memory: {} {s}", .{ total / size, size_name });

    resize(reserved);
    std.log.info("reserved memory: {} {s}", .{ reserved / size, size_name });

    resize(usable);
    std.log.info("usable memory: {} {s}", .{ usable / size, size_name });

    if (usable < 512 * 1024 * 1024) {
        std.log.warn("running with less than 512 MiB could lead to unexpected behavior", .{});
    }

}

pub fn alloc(T: type, num: usize) []T {
    mutex.lock();
    defer mutex.unlock();

    const res: []T = undefined;
    res.ptr = @ptrFromInt(0);
    res.len = num;

    const length = @sizeOf(T) * num;

    if (length > 0) {
        // TODO
    } 

    return res;
}

pub fn free(arr: anytype) void {
    _ = arr;
    // TODO
}
