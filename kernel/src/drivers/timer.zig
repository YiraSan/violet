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

const log = std.log.scoped(.timer);

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const scheduler = kernel.scheduler;
const syscall = kernel.syscall;

const heap = mem.heap;

const Future = scheduler.Future;
const Process = scheduler.Process;
const Task = scheduler.Task;

// --- drivers/timer.zig --- //

const generic_timer = @import("../arch/aarch64/generic_timer.zig");

pub var selected_timer: enum { unselected, generic_timer } = .unselected;

pub var callback: ?*const fn () void = null;

pub fn init() !void {
    syscall.register(.timer_single, &timer_single);
    syscall.register(.timer_sequential, &timer_sequential);
}

fn timer_single(frame: *kernel.arch.GeneralFrame) !void {
    const sched_local = scheduler.Local.get();

    if (sched_local.current_task) |task| {
        const virtual_tick = frame.getArg(1);
        if (virtual_tick == 0) return try syscall.fail(frame, .invalid_argument);

        const physical_tick = @max(virtual_tick, task.priority.minResolution());

        const future_id = Future.create(null, task.process.id, task.priority, .one_shot) catch return try syscall.fail(frame, .internal_failure);
        errdefer if (Future.acquire(future_id)) |future| {
            future.release();
            future.release();
        };

        const timer_local = Local.get();

        const now = getUptime();

        try timer_local.event_queue.add(.{
            .future_id = future_id,
            .virtual_tick = virtual_tick,
            .start_uptime = now,
            .deadline = now + physical_tick,
            .tick_count = 0,
        });

        rearmEvent(task);

        syscall.success(frame, .{
            .success2 = @bitCast(future_id),
        });
    } else {
        return try syscall.fail(frame, .unknown_syscall);
    }
}

fn timer_sequential(frame: *kernel.arch.GeneralFrame) !void {
    const sched_local = scheduler.Local.get();

    if (sched_local.current_task) |task| {
        const virtual_tick = frame.getArg(1);
        if (virtual_tick == 0) return try syscall.fail(frame, .invalid_argument);

        const physical_tick = @max(virtual_tick, task.priority.minResolution());

        const future_id = Future.create(null, task.process.id, task.priority, .multi_shot) catch return try syscall.fail(frame, .internal_failure);
        errdefer if (Future.acquire(future_id)) |future| {
            future.release();
            future.release();
        };

        const timer_local = Local.get();

        const now = getUptime();

        try timer_local.event_queue.add(.{
            .future_id = future_id,
            .virtual_tick = virtual_tick,
            .start_uptime = now,
            .deadline = now + physical_tick,
            .tick_count = 0,
        });

        rearmEvent(task);

        syscall.success(frame, .{
            .success2 = @bitCast(future_id),
        });
    } else {
        return try syscall.fail(frame, .unknown_syscall);
    }
}

pub fn initCpu() !void {
    const local = Local.get();

    local.event_queue = .init();
}

pub fn rearmEvent(current_task: *Task) void {
    const local = Local.get();

    if (local.event_queue.peek()) |event| {
        const event_remaining, const overflowed = @subWithOverflow(event.deadline, getUptime());
        // TODO slow-motion backpressure & quantum coallesing
        if (overflowed == 1) {
            arm(0);
        } else if (event_remaining < scheduler.getRemainingQuantum(current_task)) {
            arm(event_remaining);
        }
    }
}

pub fn arm(nanoseconds: u64) void {
    switch (selected_timer) {
        .generic_timer => generic_timer.arm(nanoseconds),
        else => unreachable,
    }
}

pub fn cancel() void {
    switch (selected_timer) {
        .generic_timer => generic_timer.disable(),
        else => unreachable,
    }
}

pub fn getUptime() u64 {
    return switch (selected_timer) {
        .generic_timer => generic_timer.getUptime(),
        else => unreachable,
    };
}

const TimerEvent = struct {
    future_id: Future.Id,
    virtual_tick: u64,
    start_uptime: u64,
    deadline: u64,
    tick_count: u64,

    pub fn compare(a: TimerEvent, b: TimerEvent) std.math.Order {
        return std.math.order(a.deadline, b.deadline);
    }
};

pub const Local = struct {
    event_queue: heap.PriorityQueue(TimerEvent, TimerEvent.compare),

    pub fn get() *@This() {
        return &kernel.arch.Cpu.get().timer_local;
    }
};
