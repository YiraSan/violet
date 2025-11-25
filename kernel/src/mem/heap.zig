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

// --- imports --- //

const kernel = @import("root");

const boot = kernel.boot;
const mem = kernel.mem;

const phys = mem.phys;

// --- mem/heap.zig --- //

pub fn allocPage() ![*]u8 {
    return @ptrFromInt(boot.hhdm_base + try phys.allocPage(true));
}

pub fn freePage(address: [*]u8) void {
    phys.freePage(@intFromPtr(address) - boot.hhdm_base);
}

pub fn allocContiguous(count: usize) ![*]u8 {
    return @ptrFromInt(boot.hhdm_base + try phys.allocContiguous(count, true));
}

pub fn freeContiguous(address: [*]u8, count: usize) void {
    phys.freeContiguous(@intFromPtr(address) - boot.hhdm_base, count);
}

pub fn resizeContiguous(old_address: [*]u8, old_count: usize, new_count: usize) ![*]u8 {
    if (old_count > new_count) unreachable;
    if (old_count == new_count) return old_address;

    const new_address = try allocContiguous(new_count);

    const byte_size = old_count << mem.PageLevel.l4K.shift();

    @memcpy(new_address[0..byte_size], old_address[0..byte_size]);

    freeContiguous(old_address, old_count);

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
                var i: usize = 0;
                while (i < self.directory_len) : (i += 1) {
                    freePage(@ptrCast(self.directory[i]));
                }

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

        pub fn ensureTotalCapacity(self: *@This(), total_items: u64) !void {
            while (self.capacity() < total_items) {
                try self.grow();
            }
        }

        pub fn capacity(self: *@This()) u32 {
            return @intCast(self.directory_len * ITEM_PER_PAGE);
        }

        pub inline fn get(self: *@This(), index: u32) *T {
            if (builtin.mode == .Debug) {
                if (index >= self.capacity()) @panic("List: index out of bounds");
            }

            const page_index = index / ITEM_PER_PAGE;
            const item_index = index % ITEM_PER_PAGE;

            return &self.directory[page_index][item_index];
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

                generation = slot.generation +% 1;

                self.free_head = slot.content.next_free;

                slot.generation = generation;
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

            if (slot.generation % 2 != 0) return;
            if (slot.generation != key.generation) return;

            slot.generation +%= 1;
            slot.content = .{ .next_free = self.free_head };
            self.free_head = key.index;
            self.count -= 1;
        }

        pub fn get(self: *@This(), key: Key) ?*T {
            if (key.index >= self.len) return null;
            const slot = self.list.get(key.index);

            if (slot.generation % 2 != 0) return null;
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

pub fn RedBlackTree(comptime K: type, comptime V: type, comptime compareFn: anytype) type {
    return struct {
        const Self = @This();

        const Color = enum { red, black };

        const Node = struct {
            value: V,

            parent: ?Id = null,
            left: ?Id = null,
            right: ?Id = null,
            color: Color = .red,
        };

        const NodeMap = SlotMap(Node);
        pub const Id = NodeMap.Key;

        nodes: NodeMap,
        root: ?Id,

        pub fn init() Self {
            return .{
                .nodes = .init(),
                .root = null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.nodes.deinit();
        }

        pub fn insert(self: *Self, key: K, value: V) !Id {
            const id = try self.nodes.insert(Node{ .value = value });
            self.insert_node(key, id);
            return id;
        }

        pub fn get(self: *Self, id: Id) ?*V {
            if (self.nodes.get(id)) |node| {
                return &node.value;
            }
            return null;
        }

        pub fn find(self: *Self, key: K) ?Id {
            var current = self.root;

            while (current) |id| {
                const node = self.node_ptr(id);
                const order = compareFn(key, node.value);

                switch (order) {
                    .eq => return id,
                    .lt => current = node.left,
                    else => current = node.right,
                }
            }

            return null;
        }

        pub fn first(self: *Self) ?Id {
            var current = self.root;
            var last: ?Id = null;
            while (current) |id| {
                last = id;
                current = self.node_ptr(id).left;
            }
            return last;
        }

        pub fn next(self: *Self, current_id: Id) ?Id {
            const node = self.node_ptr(current_id);

            if (node.right) |right_id| {
                return self.tree_minimum(right_id);
            }

            var x_id = current_id;
            var p_id_opt = node.parent;

            while (p_id_opt) |p_id| {
                const p_node = self.node_ptr(p_id);
                if (x_id == p_node.left) {
                    return p_id;
                }
                x_id = p_id;
                p_id_opt = p_node.parent;
            }

            return null;
        }

        inline fn node_ptr(self: *Self, id: Id) *Node {
            return self.nodes.get(id) orelse @panic("RedBlackTree: tried to get the ptr of an inexistant index.");
        }

        inline fn insert_node(self: *Self, key: K, z_id: Id) void {
            var y_id: ?Id = null;
            var x_id = self.root;

            while (x_id) |curr_id| {
                y_id = curr_id;
                const curr_node = self.node_ptr(curr_id);

                const order = compareFn(key, curr_node.value);
                switch (order) {
                    .lt => x_id = curr_node.left,
                    else => x_id = curr_node.right,
                }
            }

            const z_node = self.node_ptr(z_id);
            z_node.parent = y_id;

            if (y_id == null) {
                self.root = z_id;
            } else {
                const y_node = self.node_ptr(y_id.?);
                const order = compareFn(key, y_node.value);
                if (order == .lt) {
                    y_node.left = z_id;
                } else {
                    y_node.right = z_id;
                }
            }

            z_node.left = null;
            z_node.right = null;
            z_node.color = .red;

            self.insert_fixup(z_id);
        }

        fn insert_fixup(self: *Self, start_node: Id) void {
            var z_id = start_node;

            while (self.node_ptr(z_id).parent) |p_id| {
                const p_node = self.node_ptr(p_id);
                if (p_node.color == .black) break;

                const g_id = p_node.parent orelse unreachable;
                const g_node = self.node_ptr(g_id);

                if (p_id == g_node.left) {
                    const u_id = g_node.right;
                    const u_is_red = if (u_id) |u| self.node_ptr(u).color == .red else false;

                    if (u_is_red) {
                        p_node.color = .black;
                        self.node_ptr(u_id.?).color = .black;
                        g_node.color = .red;
                        z_id = g_id;
                    } else {
                        if (z_id == p_node.right) {
                            z_id = p_id;
                            self.rotate_left(z_id);
                        }

                        const new_p_id = self.node_ptr(z_id).parent.?;
                        self.node_ptr(new_p_id).color = .black;
                        g_node.color = .red;
                        self.rotate_right(g_id);
                    }
                } else {
                    const u_id = g_node.left;
                    const u_is_red = if (u_id) |u| self.node_ptr(u).color == .red else false;

                    if (u_is_red) {
                        p_node.color = .black;
                        self.node_ptr(u_id.?).color = .black;
                        g_node.color = .red;
                        z_id = g_id;
                    } else {
                        if (z_id == p_node.left) {
                            z_id = p_id;
                            self.rotate_right(z_id);
                        }

                        const new_p_id = self.node_ptr(z_id).parent.?;
                        self.node_ptr(new_p_id).color = .black;
                        g_node.color = .red;
                        self.rotate_left(g_id);
                    }
                }
            }

            if (self.root) |root_id| {
                self.node_ptr(root_id).color = .black;
            }
        }

        fn rotate_left(self: *Self, x_id: Id) void {
            const x = self.node_ptr(x_id);
            const y_id = x.right orelse return; // should be impossible
            const y = self.node_ptr(y_id);

            x.right = y.left;
            if (y.left) |beta| {
                self.node_ptr(beta).parent = x_id;
            }

            y.parent = x.parent;
            if (x.parent == null) {
                self.root = y_id;
            } else {
                const p = self.node_ptr(x.parent.?);
                if (x_id == p.left) {
                    p.left = y_id;
                } else {
                    p.right = y_id;
                }
            }

            y.left = x_id;
            x.parent = y_id;
        }

        fn rotate_right(self: *Self, x_id: Id) void {
            const x = self.node_ptr(x_id);
            const y_id = x.left orelse return; // should be impossible
            const y = self.node_ptr(y_id);

            x.left = y.right;
            if (y.right) |beta| {
                self.node_ptr(beta).parent = x_id;
            }

            y.parent = x.parent;
            if (x.parent == null) {
                self.root = y_id;
            } else {
                const p = self.node_ptr(x.parent.?);
                if (x_id == p.left) {
                    p.left = y_id;
                } else {
                    p.right = y_id;
                }
            }

            y.right = x_id;
            x.parent = y_id;
        }

        pub fn remove(self: *Self, z_id: Id) ?V {
            const z_node = self.nodes.get(z_id) orelse return null;
            const z_value = z_node.value;

            var y_id = z_id;
            var y_original_color = z_node.color;
            var x_id: ?Id = null;
            var x_parent_id: ?Id = null;

            if (z_node.left == null) {
                x_id = z_node.right;
                x_parent_id = z_node.parent;
                self.transplant(z_id, z_node.right);
            } else if (z_node.right == null) {
                x_id = z_node.left;
                x_parent_id = z_node.parent;
                self.transplant(z_id, z_node.left);
            } else {
                y_id = self.tree_minimum(z_node.right.?);
                const y_node = self.node_ptr(y_id);
                y_original_color = y_node.color;

                x_id = y_node.right;

                if (y_node.parent == z_id) {
                    x_parent_id = y_id;
                } else {
                    x_parent_id = y_node.parent;
                    self.transplant(y_id, y_node.right);
                    y_node.right = z_node.right;
                    self.node_ptr(y_node.right.?).parent = y_id;
                }

                self.transplant(z_id, y_id);
                y_node.left = z_node.left;
                self.node_ptr(y_node.left.?).parent = y_id;
                y_node.color = z_node.color;
            }

            if (y_original_color == .black) {
                self.remove_fixup(x_id, x_parent_id);
            }

            self.nodes.remove(z_id);

            return z_value;
        }

        fn transplant(self: *Self, u_id: Id, v_id: ?Id) void {
            const u_parent = self.node_ptr(u_id).parent;

            if (u_parent == null) {
                self.root = v_id;
            } else {
                const p_node = self.node_ptr(u_parent.?);
                if (u_id == p_node.left) {
                    p_node.left = v_id;
                } else {
                    p_node.right = v_id;
                }
            }

            if (v_id) |v| {
                self.node_ptr(v).parent = u_parent;
            }
        }

        fn tree_minimum(self: *Self, start_id: Id) Id {
            var current = start_id;
            while (self.node_ptr(current).left) |left| {
                current = left;
            }
            return current;
        }

        fn remove_fixup(self: *Self, start_x: ?Id, start_parent: ?Id) void {
            var x = start_x;
            var p_id = start_parent;

            while (x != self.root and self.color_of(x) == .black) {
                if (p_id == null) break; // shouldn't happen
                const p_node = self.node_ptr(p_id.?);

                if (x == p_node.left) {
                    var w_id = p_node.right orelse unreachable;
                    var w_node = self.node_ptr(w_id);

                    if (w_node.color == .red) {
                        w_node.color = .black;
                        p_node.color = .red;
                        self.rotate_left(p_id.?);

                        w_id = p_node.right.?;
                        w_node = self.node_ptr(w_id);
                    }

                    if (self.color_of(w_node.left) == .black and self.color_of(w_node.right) == .black) {
                        w_node.color = .red;
                        x = p_id;
                        p_id = self.node_ptr(x.?).parent;
                    } else {
                        if (self.color_of(w_node.right) == .black) {
                            if (w_node.left) |wl| self.node_ptr(wl).color = .black;
                            w_node.color = .red;
                            self.rotate_right(w_id);
                            w_id = p_node.right.?;
                            w_node = self.node_ptr(w_id);
                        }

                        w_node.color = p_node.color;
                        p_node.color = .black;
                        if (w_node.right) |wr| self.node_ptr(wr).color = .black;
                        self.rotate_left(p_id.?);
                        x = self.root;
                        break;
                    }
                } else {
                    var w_id = p_node.left orelse unreachable;
                    var w_node = self.node_ptr(w_id);

                    if (w_node.color == .red) {
                        w_node.color = .black;
                        p_node.color = .red;
                        self.rotate_right(p_id.?);
                        w_id = p_node.left.?;
                        w_node = self.node_ptr(w_id);
                    }

                    if (self.color_of(w_node.right) == .black and self.color_of(w_node.left) == .black) {
                        w_node.color = .red;
                        x = p_id;
                        p_id = self.node_ptr(x.?).parent;
                    } else {
                        if (self.color_of(w_node.left) == .black) {
                            if (w_node.right) |wr| self.node_ptr(wr).color = .black;
                            w_node.color = .red;
                            self.rotate_left(w_id);
                            w_id = p_node.left.?;
                            w_node = self.node_ptr(w_id);
                        }

                        w_node.color = p_node.color;
                        p_node.color = .black;
                        if (w_node.left) |wl| self.node_ptr(wl).color = .black;
                        self.rotate_right(p_id.?);
                        x = self.root;
                        break;
                    }
                }
            }

            if (x) |x_valid| {
                self.node_ptr(x_valid).color = .black;
            }
        }

        inline fn color_of(self: *Self, id: ?Id) Color {
            if (id) |i| {
                return self.node_ptr(i).color;
            }
            return .black;
        }
    };
}

// ---- //

comptime {
    _ = List;
    _ = SlotMap;
    _ = Queue;
}
