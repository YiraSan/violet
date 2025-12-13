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
const basalt = @import("basalt");
const ark = @import("ark");

const log = std.log.scoped(.scheduler);

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const syscall = kernel.syscall;

const heap = mem.heap;
const vmm = mem.vmm;

pub const Facet = @import("facet.zig");
pub const Future = @import("future.zig");
pub const Prism = @import("prism.zig");
pub const Process = @import("process.zig");
pub const Task = @import("task.zig");

// --- scheduler/root.zig --- //

pub fn init() !void {
    idle_process_id = try Process.create(.{
        .execution_level = .system,
    });

    try initCpu();

    kernel.drivers.Timer.callback = @ptrCast(&timerCallback);

    syscall.register(.process_terminate, &process_terminate);

    syscall.register(.task_terminate, &task_terminate);
    syscall.register(.task_yield, &task_yield);

    syscall.register(.future_create, &future_create);
    syscall.register(.future_resolve, &future_resolve);
    syscall.register(.future_await, &future_await);
}

pub fn initCpu() !void {
    const local = Local.get();

    const idle_task_id = try Task.create(idle_process_id, .{
        .entry_point = @intFromPtr(&idle_task),
    });

    local.idle_task = Task.acquire(idle_task_id) orelse unreachable;
    local.idle_task.quantum = @enumFromInt(std.time.ns_per_s);

    local.ready_queue = .init();
    local.ready_queue_lock = .{};

    local.current_task = null;
    local.current_space_id = null;
}

pub fn register(task_id: Task.Id) !void {
    try newbie_queue.append(task_id);
}

fn future_create(frame: *kernel.arch.GeneralFrame) !void {
    const local = Local.get();

    if (local.current_task) |task| {
        const future_id_ptr_raw = frame.getArg(1);
        if (!syscall.pin(task, future_id_ptr_raw, Future.Id, 1, true)) return try syscall.fail(frame, .invalid_pointer);
        defer syscall.unpin(task, future_id_ptr_raw);
        const future_id_ptr: *Future.Id = @ptrFromInt(future_id_ptr_raw);

        const future_type_raw = frame.getArg(2);
        if (future_type_raw != @intFromEnum(basalt.sync.Future.Type.one_shot) and future_type_raw != @intFromEnum(basalt.sync.Future.Type.multi_shot)) return try syscall.fail(frame, .invalid_argument);
        const future_type: basalt.sync.Future.Type = @enumFromInt(future_type_raw);

        const future = Future.create(task.process.id, task.process.id, task.priority, future_type) catch return try syscall.fail(frame, .internal_failure);

        future_id_ptr.* = future;

        return syscall.success(frame, .{});
    } else {
        return try syscall.fail(frame, .unknown_syscall);
    }
}

fn future_resolve(frame: *kernel.arch.GeneralFrame) !void {
    const local = Local.get();

    if (local.current_task) |task| {
        const status_raw = frame.getArg(2);
        if (status_raw != @intFromEnum(basalt.sync.Future.Status.canceled) and status_raw != @intFromEnum(basalt.sync.Future.Status.resolved)) return try syscall.fail(frame, .invalid_argument);
        const status: basalt.sync.Future.Status = @enumFromInt(status_raw);

        const future_id: Future.Id = @bitCast(frame.getArg(1));

        const future = Future.acquire(future_id) orelse return try syscall.fail(frame, .invalid_future);
        defer future.release();

        if (future.producer_id != task.process.id and (future.consumer_id != task.process.id or status != .canceled)) return try syscall.fail(frame, .invalid_future);

        if (status == .canceled) {
            if (!future.cancel()) return try syscall.fail(frame, .invalid_future);
        } else {
            const payload = frame.getArg(3);

            if (future.type == .multi_shot and payload == 0) { // ignores 0
                syscall.success(frame, .{});
                return error._;
            }

            if (!future.resolve(payload)) return try syscall.fail(frame, .invalid_future);
        }

        if (future.type == .one_shot or status == .canceled) future.release(); // release the producer or consumer if cancellation.

        return syscall.success(frame, .{});
    } else {
        return try syscall.fail(frame, .unknown_syscall);
    }
}

// I would thank all Zig maintainers, `defer` is such a nice feature omg, this code would be garbage-like & unmaintainable in any other langage.

fn future_await(frame: *kernel.arch.GeneralFrame) !void {
    const local = Local.get();

    if (local.current_task) |task| {
        const len_raw = frame.getArg(4);
        if (len_raw == 0) return syscall.success(frame, .{ .success0 = std.math.maxInt(u16) });
        if (len_raw > 128) return try syscall.fail(frame, .invalid_argument);
        task.futures_userland_len = len_raw;

        const futures_ptr_raw = frame.getArg(1);
        if (!syscall.pin(task, futures_ptr_raw, Future.Id, len_raw, false)) return try syscall.fail(frame, .invalid_pointer);
        defer syscall.unpin(task, futures_ptr_raw);
        const futures = @as([*]Future.Id, @ptrFromInt(futures_ptr_raw))[0..len_raw];

        const payloads_ptr_raw = frame.getArg(2);
        if (!syscall.pin(task, payloads_ptr_raw, u64, len_raw, true)) return try syscall.fail(frame, .invalid_pointer);
        errdefer syscall.unpin(task, payloads_ptr_raw);
        const payloads = @as([*]u64, @ptrFromInt(payloads_ptr_raw))[0..len_raw];
        task.futures_userland_payloads_ptr = payloads_ptr_raw;

        const statuses_ptr_raw = frame.getArg(3);
        if (!syscall.pin(task, statuses_ptr_raw, basalt.sync.Future.Status, len_raw, true)) return try syscall.fail(frame, .invalid_pointer);
        errdefer syscall.unpin(task, statuses_ptr_raw);
        const statuses = @as([*]basalt.sync.Future.Status, @ptrFromInt(statuses_ptr_raw))[0..len_raw];
        task.futures_userland_statuses_ptr = statuses_ptr_raw;

        var waitmode: basalt.sync.Future.WaitMode = @bitCast(frame.getArg(5));

        const suspend_behavior: basalt.syscall.SuspendBehavior = switch (frame.getArg(6)) {
            @intFromEnum(basalt.syscall.SuspendBehavior.no_suspend) => .no_suspend,
            @intFromEnum(basalt.syscall.SuspendBehavior.wait) => .wait,
            else => if (task.priority == .realtime) .no_suspend else .wait,
        };

        const lock_flags = task.futures_lock.lockExclusive();
        defer task.futures_lock.unlockExclusive(lock_flags);

        task.futures_generation +%= 1;

        errdefer {
            task.futures_generation +%= 1;
            @memcpy(payloads[0..len_raw], task.futures_payloads[0..len_raw]);
            @memcpy(statuses[0..len_raw], task.futures_statuses[0..len_raw]);
        }

        task.futures_pending = @intCast(len_raw);
        task.futures_resolved = 0;
        task.futures_canceled = 0;

        task.futures_failfast_index = null;

        @memcpy(task.futures_payloads[0..len_raw], payloads[0..len_raw]);
        for (0.., statuses) |i, status| {
            task.futures_statuses[i] = status;
            if (status != .pending) {
                task.futures_pending -= 1;
                if (status == .resolved) {
                    task.futures_resolved += 1;
                } else if (status == .canceled) {
                    task.futures_canceled += 1;
                }
            }
        }

        if (waitmode.resolve_threshold == 0) waitmode.resolve_threshold = task.futures_pending;
        if (waitmode.resolve_threshold > task.futures_pending) return try syscall.fail(frame, .invalid_argument);

        task.futures_waitmode = waitmode;

        for (0.., futures) |i, future_id| {
            if (task.futures_statuses[i] == .pending) {
                const future = Future.acquire(future_id) orelse {
                    task.futures_pending -= 1;
                    task.futures_canceled += 1;

                    task.futures_statuses[i] = .invalid;

                    if (task.futures_waitmode.fail_fast) {
                        statuses[i] = .invalid;
                        syscall.success(frame, .{ .success0 = @intCast(i) });
                        return error._;
                    }

                    continue;
                };
                defer future.release();

                const saved_flags = future.lock.lockExclusive();
                defer future.lock.unlockExclusive(saved_flags);

                if (future.waiter != null) {
                    task.futures_pending -= 1;
                    task.futures_canceled += 1;

                    task.futures_statuses[i] = .invalid;

                    if (task.futures_waitmode.fail_fast) {
                        statuses[i] = .invalid;
                        syscall.success(frame, .{ .success0 = @intCast(i) });
                        return error._;
                    }
                }

                switch (future.status) {
                    .resolved => {
                        switch (future.type) {
                            .one_shot => {
                                task.futures_payloads[i] = future.payload;
                                task.futures_statuses[i] = .resolved;
                                task.futures_pending -= 1;
                                task.futures_resolved += 1;
                            },
                            .multi_shot => {
                                const delta = future.payload -% task.futures_payloads[i];
                                if (delta > 0) {
                                    task.futures_payloads[i] = delta;
                                    task.futures_statuses[i] = .resolved;
                                    task.futures_pending -= 1;
                                    task.futures_resolved += 1;
                                } else {
                                    future.waiter_generation = task.futures_generation;
                                    future.waiter_index = @intCast(i);
                                    future.waiter = task.id;

                                    future.status = .pending;
                                    task.futures_statuses[i] = .pending;

                                    future.consumer_priority.store(task.priority, .release);
                                }
                            },
                        }
                    },
                    .canceled => {
                        task.futures_pending -= 1;
                        task.futures_canceled += 1;

                        task.futures_statuses[i] = .canceled;

                        if (task.futures_waitmode.fail_fast) {
                            syscall.success(frame, .{ .success0 = @intCast(i) });
                            return error._;
                        }
                    },
                    .pending => {
                        future.waiter_generation = task.futures_generation;
                        future.waiter_index = @intCast(i);
                        future.waiter = task.id;
                        future.consumer_priority.store(task.priority, .release);
                    },
                }

                if (task.futures_resolved >= task.futures_waitmode.resolve_threshold) {
                    syscall.success(frame, .{ .success0 = std.math.maxInt(u16) });
                    return error._;
                }

                if (task.futures_waitmode.resolve_threshold > (task.futures_resolved + task.futures_pending)) {
                    return try syscall.fail(frame, .insolvent);
                }

                if (suspend_behavior == .wait) {
                    suspendForWait();
                } else {
                    return try syscall.fail(frame, .would_suspend);
                }
            }
        }
    } else {
        return try syscall.fail(frame, .unknown_syscall);
    }
}

fn suspendForWait() void {
    const local = Local.get();
    if (local.current_task == null) @panic("corrupted suspendForWait call");
    var suspended_task = local.current_task;

    if (suspended_task.?.state.cmpxchgStrong(.ready, .waiting, .acq_rel, .monotonic) != null) {
        suspended_task.?.release();
        suspended_task = null;
    }

    local.current_task = null;

    chooseTask();

    if (local.current_task == null) {
        local.current_task = local.idle_task;
    }

    storeAndLoad(suspended_task, true);
}

// --- scheduler entrypoints --- //

fn timerCallback() void {
    const local = Local.get();

    if (local.current_task) |task| {
        if (task.isDying() or task.process.isDying()) {
            task.release();
            local.current_task = null;
        }
    }

    const last_task = local.current_task;

    if (local.current_task) |task| {
        if (task.process.id == idle_process_id) {
            local.current_task = null;
        }
    }

    if (local.current_task) |current_task| {
        if (getElapsed(current_task) >= current_task.quantum.nanoseconds()) {
            local.current_task = null;
        }
    }

    const timer_local = kernel.drivers.Timer.Local.get();
    while (timer_local.event_queue.peek()) |event| {
        var timer_event = event;

        if (timer_event.deadline <= kernel.drivers.Timer.getUptime()) {
            _ = timer_local.event_queue.pop();

            const future = Future.acquire(timer_event.future_id) orelse continue;
            defer future.release();

            switch (future.type) {
                .one_shot => {
                    _ = future.resolve(0);
                },
                .multi_shot => {
                    const new_tick_count = (timer_event.deadline - timer_event.start_uptime) / timer_event.virtual_tick;
                    const delta = new_tick_count - timer_event.tick_count;
                    timer_event.tick_count = new_tick_count;

                    _ = future.resolve(delta);

                    const physical_tick = @max(timer_event.virtual_tick, future.consumer_priority.load(.acquire).minResolution());

                    timer_event.deadline += physical_tick;

                    timer_local.event_queue.add(timer_event) catch @panic("event-queue failed in timerCallback for sequential");
                },
            }
        } else {
            break;
        }
    }

    chooseTask();

    storeAndLoad(last_task, false);
}

fn process_terminate(_: *kernel.arch.GeneralFrame) !void {
    const local = Local.get();

    if (local.current_task) |current_task| {
        current_task.process.kill();
        current_task.kill();
        current_task.release();
        local.current_task = null;
    }

    chooseTask();

    storeAndLoad(null, false);
}

pub fn task_terminate(_: *kernel.arch.GeneralFrame) anyerror!void {
    const local = Local.get();

    if (local.current_task) |current_task| {
        current_task.release();
        local.current_task = null;
    }

    chooseTask();

    storeAndLoad(null, false);
}

fn task_yield(frame: *kernel.arch.GeneralFrame) !void {
    kernel.syscall.success(frame, .{});

    const local = Local.get();

    const last = local.current_task;
    local.current_task = null;

    chooseTask();

    storeAndLoad(last, false);
}

// --- internal logic --- //

pub const ScheduledItem = struct {
    task: *Task,
    priority: u64,

    pub fn compare(a: ScheduledItem, b: ScheduledItem) std.math.Order {
        return std.math.order(a.priority, b.priority);
    }
};

pub const Local = struct {
    idle_task: *Task,

    ready_queue: heap.PriorityQueue(ScheduledItem, ScheduledItem.compare),
    ready_queue_lock: mem.RwLock,

    current_task: ?*Task,
    current_space_id: ?Process.Id,

    pub fn get() *@This() {
        return &kernel.arch.Cpu.get().scheduler_local;
    }
};

const NewbieQueue = struct {
    queue: heap.Queue(Task.Id) = .init(),
    lock: mem.RwLock = .{},
    atomic_len: std.atomic.Value(usize) = .init(0),

    pub fn append(self: *@This(), task_id: Task.Id) !void {
        const lock = self.lock.lockExclusive();
        defer self.lock.unlockExclusive(lock);

        try self.queue.append(task_id);

        _ = self.atomic_len.fetchAdd(1, .monotonic);
    }

    pub fn pop(self: *@This()) ?Task.Id {
        if (self.lenHint() == 0) return null;

        const lock = self.lock.lockExclusive();
        defer self.lock.unlockExclusive(lock);

        if (self.queue.len() == 0) {
            return null;
        }

        const item = self.queue.pop();
        if (item) |_| {
            _ = self.atomic_len.fetchSub(1, .monotonic);
        }

        return item;
    }

    inline fn lenHint(self: *@This()) usize {
        return self.atomic_len.load(.monotonic);
    }
};

var newbie_queue: NewbieQueue = .{};

var idle_process_id: Process.Id = undefined;
fn idle_task() callconv(basalt.task.call_conv) noreturn {
    ark.cpu.halt();
}

inline fn chooseTask() void {
    const local = Local.get();

    if (local.current_task == null) {
        const now = kernel.drivers.Timer.getUptime();

        const saved_flags = local.ready_queue_lock.lockExclusive();
        defer local.ready_queue_lock.unlockExclusive(saved_flags);

        while (newbie_queue.pop()) |new_task_id| {
            if (Task.acquire(new_task_id)) |new_task| {
                if (new_task.isDying()) {
                    new_task.release();
                    continue;
                }

                new_task.host_id = kernel.arch.Cpu.id();

                local.ready_queue.add(.{
                    .priority = now + new_task.penalty(),
                    .task = new_task,
                }) catch @panic("ready-queue oom in chooseTask()");
            }
        }

        while (local.ready_queue.pop()) |item| {
            if (item.task.isDying()) {
                item.task.release();
                continue;
            }

            local.current_task = item.task;
            break;
        }

        if (local.current_task == null) {
            // TODO work stealing (ignore realtime task)
        }
    }
}

pub inline fn storeAndLoad(last_task: ?*Task, waiting: bool) void {
    const local = Local.get();

    if (local.current_task) |current_task| {
        if (last_task) |last| {
            if (current_task.id == last.id) {
                kernel.drivers.Timer.arm(getRemainingQuantum(current_task));
                kernel.drivers.Timer.rearmEvent(current_task);
                return;
            } else {
                last.extendFrame();
                last.uptime_suspend = kernel.drivers.Timer.getUptime();
                if (last.process.id != idle_process_id and !waiting) {
                    local.ready_queue.add(.{
                        .priority = last.uptime_suspend + last.penalty(),
                        .task = last,
                    }) catch @panic("ready-queue oom in storeAndLoad()");
                }
            }
        }
    } else {
        if (last_task) |last| {
            local.current_task = last;
        } else {
            local.current_task = local.idle_task;
        }
    }

    const task = local.current_task.?;
    task.uptime_schedule = kernel.drivers.Timer.getUptime();

    if (!task.process.isPrivileged()) {
        if (task.process.id != local.current_space_id) {
            task.process.virtualSpace().apply();
            local.current_space_id = task.process.id;
        }
    }

    const real_value = task.state.cmpxchgStrong(.waiting_queued, .ready, .acq_rel, .monotonic);

    if (real_value == null) {
        const saved_flags = task.futures_lock.lockExclusive();
        defer task.futures_lock.unlockExclusive(saved_flags);

        task.futures_generation +%= 1;

        const payloads = @as([*]u64, @ptrFromInt(task.futures_userland_payloads_ptr))[0..task.futures_userland_len];
        defer syscall.unpin(task, task.futures_userland_payloads_ptr);

        const statuses = @as([*]basalt.sync.Future.Status, @ptrFromInt(task.futures_userland_statuses_ptr))[0..task.futures_userland_len];
        defer syscall.unpin(task, task.futures_userland_statuses_ptr);

        @memcpy(payloads[0..task.futures_userland_len], task.futures_payloads[0..task.futures_userland_len]);
        @memcpy(statuses[0..task.futures_userland_len], task.futures_statuses[0..task.futures_userland_len]);

        const frame = if (task.is_extended) &task.stack_pointer.extended.general_frame else task.stack_pointer.general;

        if (task.futures_resolved >= task.futures_waitmode.resolve_threshold) {
            syscall.success(frame, .{ .success0 = std.math.maxInt(u16) });
        } else if (task.futures_waitmode.resolve_threshold > (task.futures_resolved + task.futures_pending)) {
            syscall.fail(frame, .insolvent) catch {};
        } else if (task.futures_waitmode.fail_fast) {
            if (task.futures_failfast_index) |fidx| {
                syscall.success(frame, .{ .success0 = @intCast(fidx) });
            } else {
                log.err("future spurious wakeup", .{});
            }
        }
    } else if (real_value == .dying) {
        return task_terminate(undefined) catch {};
    }

    kernel.drivers.Timer.arm(task.quantum.nanoseconds());
    kernel.drivers.Timer.rearmEvent(task);

    const should_log = if (last_task) |lt| lt.id != task.id else true;
    if (should_log) {
        if (task.process.id == idle_process_id) {
            log.debug("cpu{} entered idle state", .{kernel.arch.Cpu.id()});
        } else {
            log.debug("cpu{} switched to task {}:{}", .{ kernel.arch.Cpu.id(), task.process.id.index, task.id.index });
        }
    }
}

inline fn getElapsed(task: *Task) usize {
    if (task.uptime_suspend > task.uptime_schedule) {
        return task.uptime_suspend - task.uptime_schedule;
    } else {
        const result, const overflowed = @subWithOverflow(kernel.drivers.Timer.getUptime(), task.uptime_schedule);
        if (overflowed == 1) {
            return 0;
        } else {
            return result;
        }
    }
}

pub inline fn getRemainingQuantum(task: *Task) usize {
    const value, const overflowed = @subWithOverflow(task.quantum.nanoseconds(), getElapsed(task));

    if (overflowed == 0) {
        return value;
    } else {
        return 0;
    }
}
