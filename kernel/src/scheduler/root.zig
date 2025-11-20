// Copyright (c) 2025 The violetOS authors
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
const virt = mem.virt;

pub const Process = @import("process.zig");
pub const Task = @import("task.zig");

// --- scheduler/root.zig --- //

pub fn init() !void {
    const idle_process_id = try Process.create(.{
        .execution_level = .kernel,
        .kernel_space_only = true,
    });

    idle_process = Process.acquire(idle_process_id) orelse unreachable;

    try initCpu();

    kernel.drivers.Timer.callback = @ptrCast(&timerCallback);

    kernel.syscall.register(.process_terminate, &terminateProcess);

    kernel.syscall.register(.task_terminate, &terminateTask);
    kernel.syscall.register(.task_yield, &yieldTask);
}

pub fn initCpu() !void {
    const local = Local.get();

    local.current_task = null;
    local.queue_tasks = .{};
    local.cycle_done = 0;

    local.idle_task = try idle_process.createTask(.{
        .entry_point = @intFromPtr(&idle_task),
        .quantum = .ultra_heavy,
        .timer_precision = .disabled,
    });
}

pub fn register(task: *Task) !void {
    const lock_flags = incomming_tasks_lock.lockExclusive();
    defer incomming_tasks_lock.unlockExclusive(lock_flags);

    try incomming_tasks.append(task);
}

// --- scheduler entrypoints --- //

fn timerCallback(ctx: *kernel.arch.ExceptionContext) callconv(basalt.task.call_conv) void {
    const local = Local.get();

    // ignore terminated tasks
    if (local.current_task) |task| {
        if (task.isTerminated() or task.process.isTerminated()) {
            task.destroy();
            local.current_task = null;
        }
    }

    // TODO TIMER EVENT

    const last_task = local.current_task;

    if (local.current_task) |task| {
        if (task.process.id == local.idle_task.process.id) {
            local.current_task = null;
        }
    }

    if (local.current_task) |current_task| {
        current_task.quantum_elapsed_ns += getTimerPrecision(current_task).nanoseconds();

        if (current_task.quantum_elapsed_ns >= current_task.quantum.toDelay().nanoseconds()) {
            local.current_task = null;
        }
    }

    chooseTask();

    storeAndLoad(ctx, last_task);
}

fn terminateProcess(ctx: *kernel.arch.ExceptionContext) callconv(basalt.task.call_conv) void {
    const local = Local.get();

    if (local.current_task) |current_task| {
        current_task.process.terminate();
        current_task.destroy();
        local.current_task = null;
    }

    chooseTask();

    storeAndLoad(ctx, null);
}

fn terminateTask(ctx: *kernel.arch.ExceptionContext) callconv(basalt.task.call_conv) void {
    const local = Local.get();

    if (local.current_task) |current_task| {
        current_task.terminate();
        current_task.destroy();
        local.current_task = null;
    }

    chooseTask();

    storeAndLoad(ctx, null);
}

fn yieldTask(ctx: *kernel.arch.ExceptionContext) callconv(basalt.task.call_conv) void {
    const local = Local.get();

    const last = local.current_task;
    local.current_task = null;

    chooseTask();

    storeAndLoad(ctx, last);
}

// --- internal logic --- //

pub const Local = struct {
    current_task: ?*kernel.scheduler.Task,

    idle_task: *kernel.scheduler.Task,

    queue_tasks: mem.Queue(*kernel.scheduler.Task),
    cycle_done: usize,

    pub fn get() *@This() {
        return &kernel.arch.Cpu.get().scheduler_local;
    }
};

var incomming_tasks: mem.Queue(*Task) = .{};
var incomming_tasks_lock: mem.RwLock = .{};

var idle_process: *Process = undefined;
fn idle_task(_: *[0x1000]u8) callconv(basalt.task.call_conv) noreturn {
    ark.cpu.halt();
}

inline fn chooseTask() void {
    const local = Local.get();

    local.cycle_done += 1;

    if (local.current_task == null) {
        const local_task_ready = local.queue_tasks.count() > 0;

        if (local.cycle_done >= (local.queue_tasks.count() / 15 + 1) or !local_task_ready) {
            local.cycle_done = 0;

            const lock_flags = incomming_tasks_lock.lockExclusive();
            defer incomming_tasks_lock.unlockExclusive(lock_flags);

            if (incomming_tasks.count() > 0) {
                local.current_task = incomming_tasks.pop();
            }
        }

        if (local_task_ready and local.current_task == null) {
            local.current_task = local.queue_tasks.pop();
        }
    }
}

inline fn storeAndLoad(ctx: *kernel.arch.ExceptionContext, last_task: ?*Task) void {
    const local = Local.get();

    if (local.current_task) |current_task| {
        if (last_task) |last| {
            if (current_task.process.id == last.process.id and current_task.id == last.id) {
                log.warn("scheduler choosed to reschedule the same task, shouldn't happen.", .{});
                kernel.drivers.Timer.arm(getTimerPrecision(current_task));
                return;
            } else {
                last.state.store(.ready, .seq_cst);
                if (last.process.id != idle_process.id) {
                    kernel.arch.Context.store(last, ctx);
                    local.queue_tasks.append(last) catch @panic("scheduler.storeAndLoad ran out of memory");
                }
            }
        }
    } else {
        if (last_task) |last| {
            local.current_task = last;
            kernel.drivers.Timer.arm(getTimerPrecision(last));
            return;
        } else {
            local.current_task = local.idle_task;
        }
    }

    const task = local.current_task.?;

    task.state.store(.running, .seq_cst);
    local.current_task = task;
    kernel.arch.Context.load(task, ctx);
    kernel.drivers.Timer.arm(getTimerPrecision(task));

    if (!task.process.isPriviledged()) {
        task.process.virtual_space.apply();
    }

    log.debug("cpu{} switched to task {}:{}", .{ kernel.arch.Cpu.id(), task.process.id, task.id });
}

inline fn getTimerPrecision(task: *Task) basalt.timer.Delay {
    const quantum = task.quantum.toDelay();

    if (task.timer_precision == .disabled) return quantum;

    const timer_precision = task.timer_precision.toDelay();

    if (@intFromEnum(quantum) < @intFromEnum(timer_precision)) {
        return quantum;
    } else {
        return timer_precision;
    }
}
