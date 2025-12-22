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
const vmm = mem.vmm;

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
options: basalt.sync.Prism.Options,

owner_id: Process.Id,
binded_task_id: std.atomic.Value(Task.Id),

ref_count: std.atomic.Value(usize),
state: std.atomic.Value(State),

next_prism: ?*Prism,
prev_prism: ?*Prism,

facet_head: ?*Facet,

lock: mem.RwLock,

backpressure_head: ?*Task,
backpressure_tail: ?*Task,

queue_is_second: bool,
queue_cursor: usize,
queue_count: usize,

queue_kernel1: []basalt.sync.Prism.Invocation,
queue_kernel2: []basalt.sync.Prism.Invocation,

queue_user1: u64,
queue_user2: u64,

consumer: ?*Task,

pub fn create(binded_task_id: Task.Id, options: basalt.sync.Prism.Options) !Id {
    if (options.queue_size == 0 or options.queue_size > 32) return Error.InvalidOptions;
    if (options.queue_mode != .backpressure and options.queue_mode != .overwrite) return Error.InvalidOptions;
    if (options.notify_on_drop != .disabled and options.notify_on_drop != .overwrite and options.notify_on_drop != .sidelist) return Error.InvalidOptions;
    if (!options.arg_formats.isValid()) return Error.InvalidOptions;

    const binded_task = Task.acquire(binded_task_id) orelse return Error.InvalidTask;
    defer binded_task.release();

    if (!binded_task.process.isPrivileged() and options.arg_formats.trustedModulesOnly()) return Error.InvalidOptions;

    var prism: Prism = undefined;

    prism.options = options;

    prism.owner_id = binded_task.process.id;
    prism.binded_task_id = .init(binded_task_id);

    prism.ref_count = .init(1); // process reference
    prism.state = .init(.alive);

    prism.facet_head = null;

    prism.lock = .{};

    prism.backpressure_head = null;
    prism.backpressure_tail = null;

    prism.queue_is_second = false;
    prism.queue_cursor = 0;
    prism.queue_count = 0;

    const queue_count = options.queue_size * INVOCATIONS_PER_PAGE;

    const buffer_size = queue_count * @sizeOf(basalt.sync.Prism.Invocation);
    const double_buffer_size = buffer_size * 2;

    const queue_object = try vmm.Object.create(double_buffer_size, .{});

    prism.queue_kernel1.ptr = @ptrFromInt(try vmm.kernel_space.map(queue_object, double_buffer_size, 0, 0, .{ .writable = true }, true));
    errdefer vmm.kernel_space.unmap(@intFromPtr(prism.queue_kernel1.ptr), false) catch {};
    prism.queue_kernel2.ptr = @ptrFromInt(@intFromPtr(prism.queue_kernel1.ptr) + buffer_size);

    prism.queue_kernel1.len = queue_count;
    prism.queue_kernel2.len = queue_count;

    prism.queue_user1 = try binded_task.process.virtualSpace().map(queue_object, double_buffer_size, 0, 0, .{}, true);
    errdefer binded_task.process.virtualSpace().unmap(prism.queue_user1, false) catch {};
    prism.queue_user2 = prism.queue_user1 + buffer_size;

    prism.consumer = null;

    const lock_flags = prisms_map_lock.lockExclusive();
    defer prisms_map_lock.unlockExclusive(lock_flags);

    const slot_key = try prisms_map.insert(prism);
    var prism_ptr = prisms_map.get(slot_key) orelse unreachable;
    prism_ptr.id = slot_key;

    prism_ptr.next_prism = binded_task.process.prism_head;
    prism_ptr.prev_prism = null;

    if (binded_task.process.prism_head) |last_head| {
        last_head.prev_prism = prism_ptr;
    }

    binded_task.process.prism_head = prism_ptr;

    return slot_key;
}

fn destroy(self: *Prism) void {
    const lock_flags = prisms_map_lock.lockExclusive();
    defer prisms_map_lock.unlockExclusive(lock_flags);

    if (self.ref_count.load(.acquire) > 0) {
        return;
    }

    if (Process.acquire(self.owner_id)) |process| {
        defer process.release();

        if (self.next_prism) |next| {
            next.prev_prism = self.prev_prism;
        }

        if (self.prev_prism) |prev| {
            prev.next_prism = self.next_prism;
        } else {
            process.prism_head = self.next_prism;
        }
    }

    if (Task.acquire(self.binded_task_id.load(.acquire))) |binded_task| {
        defer binded_task.release();

        binded_task.process.virtualSpace().unmap(self.queue_user1, false) catch {};
    }

    vmm.kernel_space.unmap(@intFromPtr(self.queue_kernel1.ptr), false) catch {};

    // TODO wakeup backpressured tasks.

    prisms_map.remove(self.id);
}

pub fn kill(self: *Prism) void {
    if (self.state.cmpxchgStrong(.alive, .dying, .acq_rel, .monotonic) == null) {
        defer self.release(); // process reference
    }
}

pub fn acquire(id: Id) ?*Prism {
    const lock_flags = prisms_map_lock.lockShared();
    defer prisms_map_lock.unlockShared(lock_flags);

    const prism: *Prism = prisms_map.get(id) orelse return null;
    if (prism.state.load(.acquire) == .dying) return null;

    _ = prism.ref_count.fetchAdd(1, .acq_rel);

    return prism;
}

pub fn release(self: *Prism) void {
    if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
        self.destroy();
    }
}

// ---- //

const INVOCATIONS_PER_PAGE = mem.PageLevel.l4K.size() / @sizeOf(basalt.sync.Prism.Invocation); // 128 invocations per page

pub const Error = error{
    InvalidTask,
    InvalidOptions,
};

pub const State = enum(u8) {
    dying,
    alive,
};
