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
const basalt = @import("basalt");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const scheduler = kernel.scheduler;

const heap = mem.heap;

const Future = scheduler.Future;
const Prism = scheduler.Prism;
const Process = scheduler.Process;

// --- scheduler/facet.zig --- //

const Facet = @This();
const FacetMap = heap.SlotMap(Facet);
pub const Id = FacetMap.Key;

var facets_map: FacetMap = .init();
var facets_map_lock: mem.RwLock = .{};

id: Id,
ref_count: std.atomic.Value(usize),
dropped: std.atomic.Value(bool),

sequence: std.atomic.Value(u64),

prism_id: Prism.Id,
caller_id: Process.Id,

next_facet: ?*Facet,
prev_facet: ?*Facet,

next_dropped: ?*Facet,

pub fn create(syscaller_id: Process.Id, prism_id: Prism.Id, caller_id: Process.Id) !Id {
    const prism = Prism.acquire(prism_id) orelse return Error.InvalidPrism;
    defer prism.release();

    if (syscaller_id != prism.owner_id) return Error.InvalidPrism;

    const caller = Process.acquire(caller_id) orelse return Error.InvalidProcess;
    defer caller.release();

    var facet: Facet = undefined;

    facet.ref_count = .init(1); // life reference (can either be dropped by the prism or the caller, with facet_drop)
    facet.dropped = .init(false); // to avoid a race condition that creates memory leak.

    facet.sequence = .init(0);

    facet.prism_id = prism_id;
    facet.caller_id = caller_id;

    facet.next_dropped = null;

    const saved_flags = facets_map_lock.lockExclusive();
    defer facets_map_lock.unlockExclusive(saved_flags);

    const slot_key = try facets_map.insert(facet);
    var facet_ptr = facets_map.get(slot_key) orelse unreachable;
    facet_ptr.id = slot_key;

    facet_ptr.next_facet = caller.facet_head;
    facet_ptr.prev_facet = null;

    if (caller.facet_head) |last_head| {
        last_head.prev_facet = facet_ptr;
    }

    caller.facet_head = facet_ptr;

    return slot_key;
}

fn destroy(self: *Facet) void {
    const saved_flags = facets_map_lock.lockExclusive();
    defer facets_map_lock.unlockExclusive(saved_flags);

    if (self.ref_count.load(.acquire) > 0) {
        return;
    }

    if (Process.acquire(self.caller_id)) |process| {
        defer process.release();

        if (self.next_facet) |next| {
            next.prev_facet = self.prev_facet;
        }

        if (self.prev_facet) |prev| {
            prev.prev_facet = self.next_facet;
        } else {
            process.facet_head = self.next_facet;
        }
    }

    facets_map.remove(self.id);
}

pub fn acquire(id: Id) ?*Facet {
    const saved_flags = facets_map_lock.lockShared();
    defer facets_map_lock.unlockShared(saved_flags);

    const facet: *Facet = facets_map.get(id) orelse return null;
    if (facet.dropped.load(.acquire)) return null;

    _ = facet.ref_count.fetchAdd(1, .acq_rel);

    return facet;
}

pub fn drop(self: *Facet, notify: bool) !void {
    var has_dropped = false;
    if (self.dropped.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null) {
        has_dropped = true;
    }

    defer if (has_dropped) self.release();

    const prism = Prism.acquire(self.prism_id) orelse return;
    defer prism.release();

    if (has_dropped and notify and prism.options.notify_on_drop != .disabled) {
        const saved_flags = prism.lock.lockExclusive();
        defer prism.lock.unlockExclusive(saved_flags);

        const current_queue = if (prism.queue_is_second) prism.queue_kernel2 else prism.queue_kernel1;
        const overflowed = prism.queue_count == current_queue.len;

        const defer_drop = switch (prism.options.notify_on_drop) {
            .defer_on_overflow => overflowed,
            .always_defer => true,
            .overwrite => false,
            .disabled => unreachable,
        };

        if (defer_drop) {
            has_dropped = false;

            self.next_dropped = null;

            if (prism.dropped_tail) |tail| {
                tail.next_dropped = self;
            } else {
                prism.dropped_head = self;
            }

            prism.dropped_tail = self;
        } else {
            prism.forcePush(.{
                .facet_id = @bitCast(self.id),
                .future = .null,
                .arg = .{ .pair64 = .{ .arg0 = 0, .arg1 = 0 } },
            });
        }
    }
}

pub fn release(self: *Facet) void {
    if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
        self.destroy();
    }
}

// ---- //

pub const Error = error{
    InvalidPrism,
    InvalidProcess,
};
