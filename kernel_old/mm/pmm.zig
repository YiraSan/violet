const std = @import("std");
const log = std.log.scoped(.pmm);

const limine = @import("../limine.zig");
const Spinlock = @import("../arch.zig").Spinlock;
const Bitmap = @import("../util/bitmap.zig");

var bitmap: Bitmap = undefined;
var lock = Spinlock {};

var available_pages: usize = 0;
var used_pages: usize = 0;
var reserved_pages: usize = 0;

var highest_page_index: usize = 0;
var last_used_index: usize = 0;

pub fn init() !void {

    const entries = limine.memmap.entries();

    // debug
    log.debug("memory map:", .{});
    // determine highest_memory
    var highest_memory: usize = 0;
    for (entries) |entry| {
        log.debug("- base=0x{x:0>16}, length=0x{x:0>16}, kind={s}", .{ entry.base, entry.length, @tagName(entry.kind) });
        if (entry.kind == .usable or entry.kind == .bootloader_reclaimable) {
            const top = entry.base + entry.length;
            if (top > highest_memory) {
                highest_memory = top;
            }
        } else {
            reserved_pages += entry.length;
        }
    }
    reserved_pages = (reserved_pages + (std.mem.page_size - 1)) / std.mem.page_size;

    // calculate the needed size for the bitmap in bytes rounded up and align it to page size.
    highest_page_index = (highest_memory + (std.mem.page_size - 1)) / std.mem.page_size;
    available_pages = highest_page_index;
    bitmap.size = std.mem.alignForward(usize, highest_page_index / 8, std.mem.page_size);

    // find a hole
    for (entries) |entry| {

        if (entry.kind != .usable) {
            continue;
        }

        if (entry.length >= bitmap.size) {
            bitmap.bits = @ptrFromInt(entry.base + limine.hhdm.offset);
            
            @memset(bitmap.bits[0..bitmap.size], 0xff);

            entry.length -= bitmap.size;
            entry.base += bitmap.size;

            break;
        }
        
    }

    for (entries) |entry| {
        if (entry.kind != .usable and entry.kind != .bootloader_reclaimable) { continue; }

        var i: usize = 0;
        while (i < entry.length) {
            bitmap.unset((entry.base + i) / std.mem.page_size);
            i += std.mem.page_size;
        }
    }

    const available_memory = available_pages * std.mem.page_size / 1024 / 1024;

    log.debug("bitmap size: {} KiB", .{bitmap.size / 1024});
    log.debug("available memory: {} MiB", .{available_memory});
    log.debug("reserved memory: {} MiB", .{reserved_pages * std.mem.page_size / 1024 / 1024});

    if (available_memory < 128) {
        @panic("memory should be at least 128 MiB");
    }

}


fn inner_alloc(count: usize, limit: usize) ?[*]u8 {
    var p: usize = 0;
    while (last_used_index < limit) {
        if (!bitmap.check(last_used_index)) {
            last_used_index += 1;
            p += 1;

            if (p == count) {
                const page = last_used_index - count;

                var i: usize = 0;
                while (i < last_used_index) : (i += 1)
                    bitmap.set(i);

                return @as([*]u8, @ptrFromInt(page * std.mem.page_size));
            }
        } else {
            last_used_index += 1;
            p = 0;
        }
    }

    return null;
}

pub fn allocNz(count: usize) ?[*]u8 {
    lock.lock();
    defer lock.unlock();

    const last = last_used_index;
    var ret = inner_alloc(count, highest_page_index);

    if (ret == null) {
        last_used_index = 0;
        ret = inner_alloc(count, last);
        if (ret == null) {
            @panic("allocated memory is null");
        }
    }

    used_pages += count;
    return ret;
}

pub fn alloc(count: usize) ?[*]u8 {
    const ret = allocNz(count);
    var ptr = @as([*]u8, @ptrFromInt(@intFromPtr(ret.?) + limine.hhdm.offset));

    var i: usize = 0;
    while (i < (count * std.mem.page_size) / 8) : (i += 1)
        ptr[i] = 0;

    return ret;
}

pub fn free(buf: ?[*]u8, count: usize) void {
    lock.lock();
    defer lock.unlock();

    const page = @intFromPtr(buf.?) / std.mem.page_size;

    var i: usize = 0;
    while (i < page + count) : (i += 1)
        bitmap.unset(i);

    used_pages -= count;
}
