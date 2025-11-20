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

const Process = scheduler.Process;

// --- scheduler/task.zig --- //

const Task = @This();
const TaskMap = mem.SlotMap(Task);
pub const ID = TaskMap.Key;

pub const STACK_PAGE_COUNT = 16; // 64 KiB
pub const STACK_SIZE = STACK_PAGE_COUNT * mem.PageLevel.l4K.size();

var tasks_map: TaskMap = .{};
var tasks_map_lock: mem.RwLock = .{};

id: ID,
process: *scheduler.Process,

timer_precision: basalt.timer.Precision,

reference_counter: std.atomic.Value(usize),
state: std.atomic.Value(State),
waiting_future: ?void,

priority: basalt.task.Priority,
quantum: basalt.task.Quantum,
quantum_elapsed_ns: usize,

context: kernel.arch.TaskContext,
stack_pointer: u64,

pub fn create(process_id: Process.ID, options: Options) !ID {
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
    const task_ptr = tasks_map.get(slot_key) orelse unreachable;
    task_ptr.id = slot_key;

    _ = task_ptr.process.task_count.fetchAdd(1, .acq_rel);

    return slot_key;
}

pub fn kill(self: *Task) void {
    self.state.store(.dying, .release);
}

fn destroy(self: *Task) void {
    const lock_flags = tasks_map_lock.lockExclusive();
    defer tasks_map_lock.unlockExclusive(lock_flags);

    if (self.reference_counter.load(.acquire) > 0) {
        return;
    }

    const process = self.process;
    defer process.release();

    defer tasks_map.remove(self.id);

    std.log.debug("destroying task {}:{}", .{ self.process.id.index, self.id.index });

    mem.heap.free(self.process.virtualSpace(), self.stack_pointer);
}

pub fn acquire(id: ID) ?*Task {
    const lock_flags = tasks_map_lock.lockShared();
    defer tasks_map_lock.unlockShared(lock_flags);

    const task: *Task = tasks_map.get(id) orelse return null;
    if (task.state.load(.acquire) == .dying) return null;

    _ = task.reference_counter.fetchAdd(1, .acq_rel);

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
