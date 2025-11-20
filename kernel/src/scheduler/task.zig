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
const basalt = @import("basalt");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const scheduler = kernel.scheduler;

const Process = scheduler.Process;

// --- scheduler/task.zig --- //

const Task = @This();

pub const STACK_PAGE_COUNT = 16; // 64 KiB
pub const STACK_SIZE = STACK_PAGE_COUNT * mem.PageLevel.l4K.size();

var tasks_map: mem.SlotMap(Task) = .{};
var tasks_map_lock: mem.RwLock = .{};

id: mem.SlotKey,
process: *scheduler.Process,

timer_precision: basalt.timer.Precision,

reference_counter: std.atomic.Value(usize),
state: std.atomic.Value(State),
waiting_future: ?mem.SlotKey,

priority: basalt.task.Priority,
quantum: basalt.task.Quantum,
quantum_elapsed_ns: usize,

context: kernel.arch.TaskContext,
stack_pointer: u64,

previous_task: ?mem.SlotKey,
next_task: ?mem.SlotKey,

pub fn create(process_id: mem.SlotKey, options: Options) !mem.SlotKey {
    const process = Process.acquire(process_id) orelse return Error.InvalidProcess;
    errdefer process.release();

    var task: Task = undefined;
    task.process = process;

    task.timer_precision = options.timer_precision;

    task.reference_counter = .init(0);
    task.state = .init(.ready);
    task.waiting_future = null;

    task.priority = options.priority;
    task.quantum = options.quantum;
    task.quantum_elapsed_ns = 0;

    task.stack_pointer = mem.heap.alloc(
        task.process.virtualSpace(),
        .l4K,
        STACK_PAGE_COUNT,
        .{
            .user = !task.process.isPriviledged(),
            .writable = true,
        },
        true,
    );
    errdefer mem.heap.free(task.process.virtualSpace(), task.stack_pointer);

    task.context = .init();
    task.context.setExecutionAddress(options.entry_point);
    task.context.setStackPointer(task.stack_pointer);
    task.context.setExecutionLevel(task.process.execution_level);

    const lock_flags = tasks_map_lock.lockExclusive();
    defer tasks_map_lock.unlockExclusive(lock_flags);

    const slot_key = try tasks_map.insert(task);
    task.id = slot_key;

    _ = task.process.task_count.fetchAdd(1, .acq_rel);

    // const last_task_key = task.process.last_task;
    // if (last_task_key) |key| {
    //     const last_task = task.acquire()
    // }

    task.process.last_task = slot_key;

    return slot_key;
}

pub fn kill(self: *Task) void {
    defer self.release();

    self.state.store(.dying, .release);
}

fn destroy(self: *Task) void {
    const process = self.process;
    defer process.release();

    const lock_flags = tasks_map_lock.lockExclusive();
    defer tasks_map_lock.unlockExclusive(lock_flags);

    if (self.reference_counter.load(.acquire) > 0) {
        // could happen if someone legitimately acquired because of the rollback of someone else.
        return;
    }

    defer tasks_map.remove(self.id);

    mem.heap.free(self.process.virtualSpace(), self.stack_pointer);
}

pub fn acquire(id: mem.SlotKey) ?*Task {
    const lock_flags = tasks_map_lock.lockShared();
    defer tasks_map_lock.unlockShared(lock_flags);

    const task: *Task = tasks_map.get(id) orelse return null;

    if (task.reference_counter.fetchAdd(1, .acq_rel) == 0) {
        _ = task.reference_counter.fetchSub(1, .acq_rel);
        // no need to call .destroy() since if it was at 0 someone is already inside .destroy() waiting for processes_map to be unlocked.
        return null;
    }

    // this case is possible if someone fetchAdd on 0 right before we tried to also fetchAdd
    if (task.state.load(.acquire) == .dying) {
        _ = task.reference_counter.fetchSub(1, .acq_rel);
        return null;
    }

    return task;
}

/// Invalidate Process pointer.
pub fn release(self: *Task) void {
    if (self.reference_counter.fetchSub(1, .acq_rel) == 1) {
        self.destroy();
    }
}

pub fn isDying(self: *Task) bool {
    return self.state.load(.acquire) == .dying;
}

// ---- //

pub const Options = struct {
    entry_point: u64,
    priority: basalt.task.Priority = .normal,
    quantum: basalt.task.Quantum = .moderate,
    timer_precision: basalt.timer.Precision = .disabled,
};

pub const State = enum(u8) {
    ready,
    dying,
    waiting,
};

pub const Error = error{
    InvalidProcess,
};
