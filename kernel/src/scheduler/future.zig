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

const Process = scheduler.Process;
const Task = scheduler.Task;

// --- scheduler/future.zig --- //

const Future = @This();
const FutureMap = heap.SlotMap(Future);
pub const Id = FutureMap.Key;

var futures_map: FutureMap = .init();
var futures_map_lock: mem.RwLock = .{};

id: Id,
ref_count: std.atomic.Value(usize),

type: basalt.sync.Future.Type,

/// `null` means that the future is served by the kernel.
///
/// the kernel doesn't use a strong reference to the future though,
/// which allows the future to be released by the only willing of the consumer.
producer_id: ?Process.Id,
prev_producer_future: ?*Future,
next_producer_future: ?*Future,

consumer_id: Process.Id,
consumer_priority: std.atomic.Value(basalt.task.Priority),
prev_consumer_future: ?*Future,
next_consumer_future: ?*Future,

lock: mem.RwLock,

status: Status,
payload: u64,

waiter: ?Task.Id,
waiter_generation: u64,
waiter_index: u8,

pub fn create(
    producer_id: ?Process.Id,
    consumer_id: Process.Id,
    consumer_priority: basalt.task.Priority,
    future_type: basalt.sync.Future.Type,
) !Id {
    const consumer = Process.acquire(consumer_id) orelse return Error.InvalidProcess;
    defer consumer.release();

    const producer = if (producer_id) |pid| Process.acquire(pid) orelse return Error.InvalidProcess else null;
    defer if (producer) |prod| prod.release();

    var future: Future = undefined;

    future.ref_count = if (producer_id == null) .init(1) else .init(2);

    future.type = future_type;

    future.producer_id = producer_id;

    future.consumer_id = consumer_id;

    future.lock = .{};

    future.status = .pending;
    future.payload = 0;

    future.waiter = null;
    future.waiter_generation = 0;
    future.waiter_index = 0;

    future.consumer_priority = .init(consumer_priority);

    const lock_flags = futures_map_lock.lockExclusive();
    defer futures_map_lock.unlockExclusive(lock_flags);

    const slot_key = try futures_map.insert(future);
    const future_ptr = futures_map.get(slot_key) orelse unreachable;
    future_ptr.id = slot_key;

    future_ptr.prev_consumer_future = null;
    if (consumer.consumed_future_head) |future_head| {
        future_head.prev_consumer_future = future_ptr;
    }
    future_ptr.next_consumer_future = consumer.consumed_future_head;
    consumer.consumed_future_head = future_ptr;

    if (producer) |prod| {
        future_ptr.prev_producer_future = null;
        if (prod.produced_future_head) |future_head| {
            future_head.prev_producer_future = future_ptr;
        }
        future_ptr.next_producer_future = prod.produced_future_head;
        prod.produced_future_head = future_ptr;
    }

    return slot_key;
}

fn destroy(self: *Future) void {
    const lock_flags = futures_map_lock.lockExclusive();
    defer futures_map_lock.unlockExclusive(lock_flags);

    if (self.ref_count.load(.acquire) > 0) {
        return;
    }

    futures_map.remove(self.id);
}

pub fn acquire(id: Id) ?*Future {
    const lock_flags = futures_map_lock.lockShared();
    defer futures_map_lock.unlockShared(lock_flags);

    const future: *Future = futures_map.get(id) orelse return null;

    _ = future.ref_count.fetchAdd(1, .acq_rel);

    return future;
}

pub fn release(self: *Future) void {
    if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
        self.destroy();
    }
}

// ---- //

pub fn resolve(self: *Future, payload: u64) bool {
    var resolved = false;
    {
        const saved_flags = self.lock.lockExclusive();
        defer self.lock.unlockExclusive(saved_flags);

        if (self.status == .canceled or (self.type == .one_shot and self.status == .resolved)) {
            return false;
        }

        switch (self.type) {
            .multi_shot => {
                self.payload +%= payload;
            },
            .one_shot => {
                self.payload = payload;
            },
        }

        if (self.status == .pending) resolved = true;
        self.status = .resolved;
    }

    if (resolved or self.type == .multi_shot) if (self.waiter) |waiter_id| {
        if (Task.acquire(waiter_id)) |waiter| {
            defer waiter.release();

            const lock_flags = waiter.futures_lock.lockExclusive();
            defer waiter.futures_lock.unlockExclusive(lock_flags);

            if (self.waiter_generation == waiter.futures_generation) {
                switch (self.type) {
                    .one_shot => {
                        waiter.futures_statuses[self.waiter_index] = .resolved;
                        waiter.futures_payloads[self.waiter_index] = self.payload;

                        waiter.futures_pending -= 1;
                        waiter.futures_resolved += 1;

                        self.waiter = null;
                    },
                    .multi_shot => {
                        const saved_flags = self.lock.lockExclusive();
                        defer self.lock.unlockExclusive(saved_flags);

                        const delta = @as(i128, @intCast(self.payload)) - waiter.futures_payloads[self.waiter_index];
                        waiter.futures_payloads[self.waiter_index] = self.payload;
                        if (waiter.futures_statuses[self.waiter_index] == .pending) {
                            if (delta > 0) {
                                waiter.futures_statuses[self.waiter_index] = .resolved;

                                waiter.futures_pending -= 1;
                                waiter.futures_resolved += 1;
                            } else {
                                self.status = .pending;
                            }
                        }
                    },
                }

                var wakeup_needed = false;

                if (waiter.futures_resolved >= waiter.futures_waitmode.resolve_threshold) {
                    wakeup_needed = true; // success
                } else if (waiter.futures_waitmode.resolve_threshold > (waiter.futures_resolved + waiter.futures_pending)) {
                    wakeup_needed = true; // insolvent
                }

                if (wakeup_needed) if (waiter.state.cmpxchgStrong(.future_waiting, .future_waiting_queued, .acq_rel, .monotonic) == null) {
                    waiter.updateAffinity();

                    var cpu_sched = &kernel.arch.Cpu.getCpu(waiter.host_id).?.scheduler_local;

                    const saved_flags = cpu_sched.ready_queue_lock.lockExclusive();
                    defer cpu_sched.ready_queue_lock.unlockExclusive(saved_flags);

                    cpu_sched.ready_queue.add(.{
                        .task = waiter,
                        .priority = kernel.drivers.Timer.getUptime() + waiter.penalty(),
                    }) catch @panic("ready-queue oom in future.awake");
                };
            }
        }
    };

    return true;
}

pub fn cancel(self: *Future) bool {
    {
        const saved_flags = self.lock.lockExclusive();
        defer self.lock.unlockExclusive(saved_flags);

        if (self.status == .canceled or (self.type == .one_shot and self.status == .resolved)) {
            return false;
        }

        self.status = .canceled;
    }

    if (self.waiter) |waiter_id| {
        self.waiter = null;

        if (Task.acquire(waiter_id)) |waiter| {
            defer waiter.release();

            const lock_flags = waiter.futures_lock.lockExclusive();
            defer waiter.futures_lock.unlockExclusive(lock_flags);

            if (self.waiter_generation == waiter.futures_generation) {
                waiter.futures_statuses[self.waiter_index] = .canceled;

                waiter.futures_pending -= 1;
                waiter.futures_canceled += 1;

                var wakeup_needed = false;

                if (waiter.futures_waitmode.fail_fast) {
                    wakeup_needed = true; // fail_fast

                    if (waiter.futures_failfast_index == null) {
                        waiter.futures_failfast_index = self.waiter_index;
                    }
                } else if (waiter.futures_waitmode.resolve_threshold > (waiter.futures_resolved + waiter.futures_pending)) {
                    wakeup_needed = true; // insolvent
                }

                if (wakeup_needed) if (waiter.state.cmpxchgStrong(.future_waiting, .future_waiting_queued, .acq_rel, .monotonic) == null) {
                    var cpu_sched = &kernel.arch.Cpu.getCpu(waiter.host_id).?.scheduler_local;

                    const saved_flags = cpu_sched.ready_queue_lock.lockExclusive();
                    defer cpu_sched.ready_queue_lock.unlockExclusive(saved_flags);

                    cpu_sched.ready_queue.add(.{
                        .task = waiter,
                        .priority = kernel.drivers.Timer.getUptime() + waiter.penalty(),
                    }) catch @panic("ready-queue oom in future.awake");
                };
            }
        }
    }

    return true;
}

// ---- //

pub const Status = enum(u8) {
    pending = 0,
    resolved = 1,
    canceled = 2,
};

pub const Error = error{
    InvalidProcess,
};
