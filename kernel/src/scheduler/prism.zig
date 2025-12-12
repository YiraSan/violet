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

const Facet = scheduler.Facet;
const Future = scheduler.Future;
const Process = scheduler.Process;
const Task = scheduler.Task;

// --- scheduler/prism.zig --- //

const Prism = @This();
const PrismMap = heap.SlotMap(Prism);
pub const Id = PrismMap.Key;

var prisms_map: PrismMap = .init();
var prisms_map_lock: mem.RwLock = .{};

id: Id,
owner_id: Process.Id,

ref_count: std.atomic.Value(usize),
next_prism: ?*Prism,

// queue_listener_lock: mem.RwLock,

// listeners_head: ?*Task,
// listeners_tail: ?*Task,
// /// if `true` : a listener has already being dispatched to swap the queue.
// listener_dispatched: bool,

// queue_mode: basalt.sync.Prism.QueueMode,
// /// if `true` : second two is the write queue.
// queue_is2: bool,
// queue_cursor: usize,

// queue_kernel1: []Invocation,
// queue_kernel2: []Invocation,

// queue_user1: u64,
// queue_user2: u64,

pub fn create(owner_id: Process.Id, options: basalt.sync.Prism.Options) !Id {
    if (options.queue_size == 0 or options.queue_size > 32) return Error.InvalidOptions;
    if (options.queue_mode != .backpressure and options.queue_mode != .overwrite) return Error.InvalidOptions;

    const owner = Process.acquire(owner_id) orelse return Error.InvalidProcess;
    defer owner.release();

    var prism: Prism = undefined;

    prism.owner_id = owner_id;

    prism.ref_count = .init(1);

    const lock_flags = prisms_map_lock.lockExclusive();
    defer prisms_map_lock.unlockExclusive(lock_flags);

    const slot_key = try prisms_map.insert(prism);
    var prism_ptr = prisms_map.get(slot_key) orelse unreachable;
    prism_ptr.id = slot_key;

    prism_ptr.next_prism = owner.prism_head;
    owner.prism_head = prism_ptr;

    return slot_key;
}

fn destroy(self: *Prism) void {
    const lock_flags = prisms_map_lock.lockExclusive();
    defer prisms_map_lock.unlockExclusive(lock_flags);

    if (self.ref_count.load(.acquire) > 0) {
        return;
    }

    defer prisms_map.remove(self.id);

    // TODO release queue buffers.
}

pub fn acquire(id: Id) ?*Prism {
    const lock_flags = prisms_map_lock.lockShared();
    defer prisms_map_lock.unlockShared(lock_flags);

    const prism: *Prism = prisms_map.get(id) orelse return null;

    _ = prism.ref_count.fetchAdd(1, .acq_rel);

    return prism;
}

pub fn release(self: *Prism) void {
    if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
        self.destroy();
    }
}

// ---- //

const INVOCATIONS_PER_PAGE = mem.PageLevel.l4K.size() / @sizeOf(Invocation); // 128

pub const Invocation = packed struct(u256) {
    facet: Facet.Id,
    future: Future.Id,
    arg0: u64,
    arg1: u64,
};

pub const Error = error{
    InvalidProcess,
    InvalidOptions,
};
