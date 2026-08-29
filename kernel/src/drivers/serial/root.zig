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

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const utils = mem.utils;

// --- drivers/serial/root.zig --- //

pub const SerialImpl = struct {
    name: []const u8,
    context: *anyopaque,
    vtable: VTable,

    pub const VTable = struct {
        write: *const fn (context: *anyopaque, bytes: []const u8) void,
        read: ?*const fn (context: *anyopaque, buffer: []u8) void,
    };
};

const MAX_SERIALS = 8;
const NULL_INDEX: u32 = std.math.maxInt(u32);

const DefaultSlot = packed struct(u64) {
    index: u32 = NULL_INDEX,
    priority: u32 = 0,
};

var registered: [MAX_SERIALS]SerialImpl = @splat(undefined);
var write_locks: [MAX_SERIALS]utils.RwLock = @splat(undefined);
var read_locks: [MAX_SERIALS]utils.RwLock = @splat(undefined);
var impl_count: std.atomic.Value(usize) = undefined;
var default_slot: std.atomic.Value(u64) = undefined;

pub fn init() void {
    impl_count = .init(0);
    default_slot = .init(@bitCast(DefaultSlot{}));
}

pub fn register(impl: SerialImpl, priority: usize) void {
    const idx = impl_count.fetchAdd(1, .acq_rel);

    if (idx >= MAX_SERIALS) {
        impl_count.store(MAX_SERIALS, .release);
        return;
    }

    registered[idx] = impl;
    write_locks[idx] = .{};
    if (impl.vtable.read != null) read_locks[idx] = .{};

    const prio32: u32 = @intCast(@min(priority, std.math.maxInt(u32)));
    const next_slot = DefaultSlot{ .index = @intCast(idx), .priority = prio32 };
    const next_raw: u64 = @bitCast(next_slot);

    var current_raw = default_slot.load(.acquire);
    while (true) {
        const current: DefaultSlot = @bitCast(current_raw);
        if (current.index != NULL_INDEX and current.priority >= prio32) break;

        if (default_slot.cmpxchgWeak(current_raw, next_raw, .acq_rel, .acquire)) |old_raw| {
            current_raw = old_raw;
        } else {
            break;
        }
    }
}

pub fn getDefault() ?usize {
    const slot: DefaultSlot = @bitCast(default_slot.load(.acquire));
    return if (slot.index == NULL_INDEX) null else slot.index;
}

pub fn getImplCount() usize {
    return impl_count.load(.acquire);
}

pub fn getImplName(impl_index: usize) ?[]const u8 {
    if (impl_index >= impl_count.load(.acquire)) return null;
    return registered[impl_index].name;
}

pub const Style = enum {
    debug,
    info,
    warn,
    err,
};

const SerialWriter = struct {
    interface: std.Io.Writer,
    impl: *const SerialImpl,
    line_buf: [128]u8,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn init(self: *SerialWriter, impl: *const SerialImpl) void {
        self.interface = .{ .vtable = &vtable, .buffer = &self.line_buf };
        self.impl = impl;
    }

    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *SerialWriter = @fieldParentPtr("interface", io_w);

        const buffered = io_w.buffer[0..io_w.end];
        if (buffered.len != 0) {
            self.impl.vtable.write(self.impl.context, buffered);
            io_w.end = 0;
        }

        if (data.len == 0) return 0;

        var written: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            if (slice.len == 0) continue;
            self.impl.vtable.write(self.impl.context, slice);
            written += slice.len;
        }

        const last = data[data.len - 1];
        if (last.len == 0 or splat == 0) return written;

        if (splat == 1) {
            self.impl.vtable.write(self.impl.context, last);
            return written + last.len;
        }

        var scratch: [64]u8 = undefined;
        const per_chunk = scratch.len / last.len;

        if (per_chunk == 0) {
            var i: usize = 0;
            while (i < splat) : (i += 1) self.impl.vtable.write(self.impl.context, last);
            return written + last.len * splat;
        }

        var remaining = splat;
        while (remaining > 0) {
            const chunk_count = @min(remaining, per_chunk);
            var off: usize = 0;
            for (0..chunk_count) |_| {
                @memcpy(scratch[off..][0..last.len], last);
                off += last.len;
            }
            self.impl.vtable.write(self.impl.context, scratch[0..off]);
            remaining -= chunk_count;
        }

        return written + last.len * splat;
    }
};

fn getValidIndex(impl_index: ?usize) ?usize {
    const idx = impl_index orelse getDefault() orelse return null;
    return if (idx >= impl_count.load(.acquire)) null else idx;
}

/// impl_index: null means default.
pub fn print(impl_index: ?usize, comptime message_level: std.log.Level, scope: []const u8, comptime format: []const u8, args: anytype) void {
    const idx = getValidIndex(impl_index) orelse return;

    const impl = &registered[idx];
    const lock = &write_locks[idx];

    var writer: SerialWriter = undefined;
    writer.init(impl);

    const level_prefix = switch (message_level) {
        .err => "\x1b[31merror",
        .warn => "\x1b[33mwarn",
        .info => "\x1b[36minfo",
        .debug => "\x1b[90mdebug",
    };

    const int_state = lock.acquire(.write, 0);
    defer lock.release(.write, int_state);

    writer.interface.print(
        "\x1b[35m[{s}] {s}: \x1b[0m" ++ format ++ "\n",
        .{ scope, level_prefix } ++ args,
    ) catch return;

    writer.interface.flush() catch return;
}

pub fn clear(impl_index: ?usize) void {
    const idx = getValidIndex(impl_index) orelse return;

    const impl = &registered[idx];
    const lock = &write_locks[idx];
    const int_state = lock.acquire(.write, 0);
    defer lock.release(.write, int_state);

    impl.vtable.write(impl.context, "\x1b[2J\x1b[H");
}
