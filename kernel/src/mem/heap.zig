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

const kernel = @import("root");

const boot = kernel.boot;
const mem = kernel.mem;

const phys = mem.phys;

// --- mem/heap.zig --- //

pub fn allocPage() ![*]u8 {
    return @ptrFromInt(boot.hhdm_base + try phys.allocPage(.l4K, true));
}

pub fn freePage(address: [*]u8) void {
    phys.freePage(@intFromPtr(address) - boot.hhdm_base, .l4K);
}

pub fn allocContiguous(count: usize) ![*]u8 {
    return @ptrFromInt(boot.hhdm_base + try phys.allocContiguousPages(count, .l4K, false, true));
}

pub fn freeContiguous(address: [*]u8, count: usize) void {
    phys.freeContiguousPages(@intFromPtr(address) - boot.hhdm_base, count, .l4K);
}

pub fn resizeContiguous(old_address: [*]u8, old_count: usize, new_count: usize) ![*]u8 {
    if (old_count > new_count) unreachable;
    if (old_count == new_count) return old_address;

    defer freeContiguous(old_address, old_count);

    const new_address = try allocContiguous(new_count);

    const byte_size = old_count << mem.PageLevel.l4K.shift();

    @memcpy(new_address[0..byte_size], old_address[0..byte_size]);

    return new_address;
}

// --- collections --- //

pub fn List(comptime T: type) type {
    // NOTE could be optimized by forcing T alignment on 16 (to avoid a division).

    return struct {
        const PAGE_SIZE = mem.PageLevel.l4K.size();

        const ITEM_PER_PAGE = PAGE_SIZE / @sizeOf(T);
        const PTRS_PER_PAGE = PAGE_SIZE / @sizeOf([*]T);

        directory: [*][*]T = undefined,
        directory_capacity: u32 = 0,
        directory_len: u32 = 0,

        pub fn init() @This() {
            return .{
                .directory = undefined,
                .directory_capacity = 0,
                .directory_len = 0,
            };
        }

        pub fn deinit(self: *@This()) void {
            if (self.directory_capacity != 0) {
                // TODO release all contained pages.

                freeContiguous(@ptrCast(self.directory), self.directory_capacity / PTRS_PER_PAGE);
            }
        }

        fn ensureDirectoryCapacity(self: *@This()) !void {
            if (self.directory_len < self.directory_capacity) return;

            const old_capacity = self.directory_capacity;
            const new_capacity = old_capacity + PTRS_PER_PAGE;

            const old_capacity_pages = old_capacity / PTRS_PER_PAGE;
            const new_capacity_pages = new_capacity / PTRS_PER_PAGE;

            const new_ptr = if (old_capacity == 0)
                try allocContiguous(new_capacity_pages)
            else
                try resizeContiguous(@ptrCast(self.directory), old_capacity_pages, new_capacity_pages);

            self.directory = @ptrCast(@alignCast(new_ptr));
            self.directory_capacity = @intCast(new_capacity);
        }

        pub fn grow(self: *@This()) !void {
            try self.ensureDirectoryCapacity();

            const page = try allocPage();

            self.directory[self.directory_len] = @ptrCast(@alignCast(page));
            self.directory_len += 1;
        }

        pub fn capacity(self: *@This()) u32 {
            return @intCast(self.directory_len * ITEM_PER_PAGE);
        }

        pub inline fn get(self: *@This(), index: u32) *T {
            const page_index = index / ITEM_PER_PAGE;
            const item_index = index % ITEM_PER_PAGE;

            const page = self.directory[page_index];
            return &page[item_index];
        }

        comptime {
            if (@sizeOf(T) > PAGE_SIZE) @compileError("List: T is too large.");
        }
    };
}

pub fn SlotMap(comptime T: type) type {
    return struct {
        pub const Key = packed struct(u64) {
            index: u32,
            generation: u32,
        };

        const Slot = struct {
            generation: u32,
            content: union {
                value: T,
                next_free: ?u32,
            },
        };

        list: List(Slot),
        len: u32,
        free_head: ?u32,
        count: u32,

        pub fn init() @This() {
            return .{
                .list = .init(),
                .len = 0,
                .free_head = null,
                .count = 0,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.list.deinit();
        }

        pub fn insert(self: *@This(), value: T) !Key {
            var slot_index: u32 = 0;
            var generation: u32 = 0;

            if (self.free_head) |head_index| {
                slot_index = head_index;
                const slot = self.list.get(slot_index);

                generation = slot.generation;

                self.free_head = slot.content.next_free;

                slot.content = .{ .value = value };
            } else {
                if (self.len == self.list.capacity()) {
                    try self.list.grow();
                }

                slot_index = @intCast(self.len);
                self.len += 1;

                generation = 0;

                self.list.get(slot_index).* = .{
                    .generation = generation,
                    .content = .{ .value = value },
                };
            }

            self.count += 1;

            return .{
                .index = slot_index,
                .generation = generation,
            };
        }

        pub fn remove(self: *@This(), key: Key) void {
            if (key.index >= self.len) return;

            const slot = self.list.get(key.index);

            if (slot.generation != key.generation) return;

            slot.generation +%= 1;

            slot.content = .{ .next_free = self.free_head };
            self.free_head = key.index;

            self.count -= 1;
        }

        pub fn get(self: *@This(), key: Key) ?*T {
            if (key.index >= self.len) return null;

            const slot = self.list.get(key.index);

            if (slot.generation != key.generation) return null;

            return &slot.content.value;
        }
    };
}

/// First-In First-Out
pub fn Queue(comptime T: type) type {
    return struct {
        list: List(T),
        head: u32,
        tail: u32,

        pub fn init() @This() {
            return .{
                .list = .init(),
                .head = 0,
                .tail = 0,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.list.deinit();
        }

        pub fn append(self: *@This(), item: T) !void {
            if (self.head == self.tail) {
                self.head = 0;
                self.tail = 0;
            }

            if (self.tail >= self.list.capacity()) {
                try self.list.grow();
            }

            const val = self.list.get(self.tail);
            val.* = item;

            self.tail += 1;
        }

        pub fn pop(self: *@This()) ?T {
            if (self.head == self.tail) {
                return null;
            }

            const val = self.list.get(self.head).*;

            self.head += 1;

            return val;
        }

        pub fn peek(self: *@This()) ?*T {
            if (self.head == self.tail) return null;
            return self.list.get(self.head);
        }

        pub fn len(self: *@This()) u32 {
            return self.tail - self.head;
        }

        pub fn isEmpty(self: *@This()) bool {
            return self.head == self.tail;
        }
    };
}

// ---- //

comptime {
    _ = List;
    _ = SlotMap;
    _ = Queue;
}
