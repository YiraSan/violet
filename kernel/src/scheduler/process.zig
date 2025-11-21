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

const Task = scheduler.Task;

// --- scheduler/process.zig --- //

const Process = @This();
const ProcessMap = heap.SlotMap(Process);
pub const Id = ProcessMap.Key;

var processes_map: ProcessMap = .init();
var processes_map_lock: mem.RwLock = .{};

id: Id,
execution_level: basalt.process.ExecutionLevel,
virtual_space: mem.vmm.Space,

ref_count: std.atomic.Value(usize),
state: std.atomic.Value(State),

task_count: std.atomic.Value(usize),

host_id: ?u8,
host_affinity: u8,

pub fn create(options: Options) !Id {
    var process: Process = undefined;
    process.execution_level = options.execution_level;

    if (!process.isPriviledged()) process.virtual_space = try .init(.lower, null, true);
    errdefer if (!process.isPriviledged()) process.virtual_space.deinit();

    process.ref_count = .init(0);
    process.state = .init(.alive);

    process.task_count = .init(0);

    process.host_id = null;
    process.host_affinity = 16;

    const lock_flags = processes_map_lock.lockExclusive();
    defer processes_map_lock.unlockExclusive(lock_flags);

    const slot_key = try processes_map.insert(process);
    const process_ptr = processes_map.get(slot_key) orelse unreachable;
    process_ptr.id = slot_key;
    return slot_key;
}

fn destroy(self: *Process) void {
    const lock_flags = processes_map_lock.lockExclusive();
    defer processes_map_lock.unlockExclusive(lock_flags);

    if (self.ref_count.load(.acquire) > 0) {
        return;
    }

    defer processes_map.remove(self.id);

    std.log.debug("destroying process {}", .{self.id.index});

    if (!self.isPriviledged()) {
        self.virtual_space.deinit();
    }
}

fn _kill(self: *Process) void {
    if (self.state.cmpxchgStrong(.alive, .dying, .acq_rel, .monotonic) == null) {
        // TODO kill waiting tasks
    }
}

/// Invalidate Process pointer.
pub fn kill(self: *Process) void {
    defer self.release();

    self._kill();
}

pub fn acquire(id: Id) ?*Process {
    const lock_flags = processes_map_lock.lockShared();
    defer processes_map_lock.unlockShared(lock_flags);

    const process: *Process = processes_map.get(id) orelse return null;
    if (process.state.load(.acquire) == .dying) return null;

    _ = process.ref_count.fetchAdd(1, .acq_rel);

    return process;
}

/// Invalidate Process pointer.
pub fn release(self: *Process) void {
    if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
        self._kill();
        self.destroy();
    }
}

pub fn virtualSpace(self: *Process) *mem.vmm.Space {
    if (self.isPriviledged()) {
        return &mem.vmm.kernel_space;
    } else {
        return &self.virtual_space;
    }
}

pub fn isPriviledged(self: *Process) bool {
    return self.execution_level == .kernel;
}

pub fn taskCount(self: *Process) usize {
    return self.task_count.load(.acquire);
}

pub fn isDying(self: *Process) bool {
    return self.state.load(.acquire) == .dying;
}

// ---- //

pub const Options = struct {
        execution_level: basalt.process.ExecutionLevel = .user,
};

pub const State = enum(u8) {
    dying,
    alive,
};
