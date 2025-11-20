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
const builtin = @import("builtin");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;

// --- scheduler/process.zig --- //

pub const PROCESS_MAX_COUNT = 32768;
pub const PER_PROCESS_TASK_MAX_COUNT = 1024;

pub const Error = error{
    TooMuchProcess,
    TooMuchTask,
    ProcessTerminated,
};

pub fn init() !void {
    const processes_page_count = std.mem.alignForward(usize, PROCESS_MAX_COUNT * @sizeOf(Process), mem.PageLevel.l4K.size()) >> mem.PageLevel.l4K.shift();
    processes.ptr = @ptrFromInt(mem.heap.alloc(
        &mem.virt.kernel_space,
        .l4K,
        @intCast(processes_page_count),
        .{ .writable = true },
        false,
    ));
    processes.len = PROCESS_MAX_COUNT;

    @memset(&processes_idmap, 0);

    processes_count = 0;
}

var processes: []Process = undefined;
var processes_idmap: [PROCESS_MAX_COUNT / 64 + 1]u64 = undefined;
var processes_count: usize = undefined;
var processes_lock: mem.RwLock = .{};

pub const ProcessOptions = struct {
    execution_level: basalt.process.ExecutionLevel = .user,
    /// If every tasks are terminated, the process won't terminate itself.
    /// Useful for drivers with no devices.
    explicit_termination: bool = false,
};

pub const ProcessState = enum(u8) {
    alive = 0x0,
    terminated = 0x1,
};

pub const Process = struct {
    id: u32,

    execution_level: basalt.process.ExecutionLevel,
    state: std.atomic.Value(ProcessState),
    explicit_termination: bool,

    virtual_space: mem.virt.Space,

    tasks: []Task,
    tasks_idmap: [PER_PROCESS_TASK_MAX_COUNT / 64 + 1]u64,
    tasks_count: usize,
    tasks_lock: mem.RwLock,

    data_context: u64,

    pub fn create(options: ProcessOptions) !*@This() {
        const lock_flags = processes_lock.lockExclusive();
        defer processes_lock.unlockExclusive(lock_flags);

        const id = try allocId();
        errdefer freeId(id);

        const process = &processes[id];
        process.* = std.mem.zeroes(Process);
        process.id = id;

        process.execution_level = options.execution_level;
        process.explicit_termination = options.explicit_termination;
        process.state = .init(.alive);

        if (!process.isPriviledged()) {
            process.virtual_space = .init(
                .lower,
                try mem.phys.allocPage(.l4K, true),
            );
        }
        errdefer if (!process.isPriviledged()) {
            process.virtual_space.free();
        };

        const tasks_page_count = std.mem.alignForward(usize, PER_PROCESS_TASK_MAX_COUNT * @sizeOf(Task), mem.PageLevel.l4K.size()) >> mem.PageLevel.l4K.shift();
        process.tasks.ptr = @ptrFromInt(mem.heap.alloc(
            &mem.virt.kernel_space,
            .l4K,
            @intCast(tasks_page_count),
            .{ .writable = true },
            false,
        ));
        process.tasks.len = PER_PROCESS_TASK_MAX_COUNT;
        errdefer mem.heap.free(&mem.virt.kernel_space, @intFromPtr(process.tasks.ptr));

        @memset(&process.tasks_idmap, 0);
        process.tasks_count = 0;
        process.tasks_lock = .{};

        process.data_context = mem.heap.alloc(
            process.getVirtualSpace(),
            .l4K,
            1,
            .{ .user = !process.isPriviledged(), .writable = true },
            false,
        );
        errdefer mem.heap.free(process.getVirtualSpace(), process.data_context);

        return process;
    }

    /// should only be called if tasks_count == 0
    pub fn destroy(self: *@This()) void {
        mem.heap.free(self.getVirtualSpace(), self.data_context);

        mem.heap.free(&mem.virt.kernel_space, @intFromPtr(self.tasks.ptr));

        if (!self.isPriviledged()) {
            self.virtual_space.free();
        }

        const lock_flags = processes_lock.lockExclusive();
        defer processes_lock.unlockExclusive(lock_flags);

        freeId(self.id);
    }

    pub fn terminate(self: *@This()) void {
        self.state.store(.terminated, .seq_cst);
    }

    pub fn isTerminated(self: *@This()) bool {
        return self.state.load(.seq_cst) == .terminated;
    }

    pub fn isUser(self: *@This()) bool {
        return self.execution_level == .user;
    }

    pub fn isSystem(self: *@This()) bool {
        return self.execution_level == .system;
    }

    pub fn isKernel(self: *@This()) bool {
        return self.execution_level == .kernel;
    }

    pub fn isPriviledged(self: *@This()) bool {
        return self.isKernel() or self.isSystem();
    }

    pub fn getVirtualSpace(self: *@This()) *mem.virt.Space {
        if (self.isPriviledged()) {
            return &mem.virt.kernel_space;
        } else {
            return &self.virtual_space;
        }
    }

    // -- Task -- //

    pub fn createTask(self: *@This(), options: Task.Options) !*Task {
        if (self.state.load(.seq_cst) == .terminated) return Error.ProcessTerminated;

        const flags_lock = self.tasks_lock.lockExclusive();
        defer self.tasks_lock.unlockExclusive(flags_lock);

        const id = try self.allocTaskId();
        errdefer self.freeTaskId(id);

        const task = &self.tasks[id];
        task.id = id;

        task.process = self;

        task.process.tasks_count += 1;

        task.state.store(.ready, .seq_cst);
        task.priority = options.priority;
        task.timer_precision = options.timer_precision;
        task.quantum = options.quantum;
        task.quantum_elapsed_ns = 0;

        task.arch_context = .init();
        task.arch_context.setExecutionAddress(options.entry_point);
        task.base_stack_pointer = mem.heap.alloc(
            task.process.getVirtualSpace(),
            .l4K,
            Task.STACK_PAGE_COUNT,
            .{
                .user = !task.process.isPriviledged(),
                .writable = true,
            },
            true,
        );
        errdefer mem.heap.free(task.process.getVirtualSpace(), task.base_stack_pointer);

        task.arch_context.setStackPointer(task.base_stack_pointer);

        task.arch_context.setExecutionLevel(task.process.execution_level);

        task.arch_context.setDataContext(task.process.data_context);

        return task;
    }

    fn allocTaskId(self: *@This()) Error!u32 {
        if (self.tasks_count >= PER_PROCESS_TASK_MAX_COUNT) return Error.TooMuchTask;
        self.tasks_count += 1;

        for (0..PER_PROCESS_TASK_MAX_COUNT) |id| {
            if (!read_bitmap(&self.tasks_idmap, id)) {
                write_bitmap(&self.tasks_idmap, id, true);
                return @intCast(id);
            }
        }

        return Error.TooMuchTask;
    }

    fn freeTaskId(self: *@This(), id: u32) void {
        if (comptime builtin.mode == .Debug) {
            if (!read_bitmap(&self.tasks_idmap, id)) {
                std.log.warn("TaskID '{}' has been freed while being free.", .{id});
            }
        }

        if (self.tasks_count != 0) {
            self.tasks_count -= 1;
        }

        write_bitmap(&self.tasks_idmap, id, false);
    }
};

pub const TaskState = enum(u8) {
    terminated = 0x0,
    running = 0x1,
    ready = 0x2,
};

pub const Task = struct {
    pub const Options = struct {
        entry_point: u64,
        priority: basalt.task.Priority = .normal,
        quantum: basalt.task.Quantum = .moderate,
        timer_precision: basalt.timer.Precision = .moderate,
    };

    pub const STACK_PAGE_COUNT = 16;
    pub const STACK_SIZE = STACK_PAGE_COUNT * mem.PageLevel.l4K.size();

    id: u32,

    process: *Process,

    state: std.atomic.Value(TaskState),
    priority: basalt.task.Priority,
    timer_precision: basalt.timer.Precision,
    quantum: basalt.task.Quantum,
    quantum_elapsed_ns: usize,

    arch_context: kernel.arch.Context,
    base_stack_pointer: u64,

    pub fn isTerminated(self: *@This()) bool {
        return self.state.load(.seq_cst) == .terminated;
    }

    pub fn terminate(self: *@This()) void {
        self.state.store(.terminated, .seq_cst);
    }

    pub fn destroy(self: *@This()) void {
        mem.heap.free(self.process.getVirtualSpace(), self.base_stack_pointer);

        var process_destroy = false;
        {
            const flags_lock = self.process.tasks_lock.lockExclusive();
            defer self.process.tasks_lock.unlockExclusive(flags_lock);

            self.process.tasks_count -= 1;

            self.process.freeTaskId(self.id);

            if (self.process.tasks_count == 0 and !self.process.explicit_termination) {
                process_destroy = true;
            }
        }

        if (process_destroy) self.process.destroy();
    }
};

// -- Process IDs -- //

fn allocId() Error!u32 {
    if (processes_count >= PROCESS_MAX_COUNT) return Error.TooMuchProcess;
    processes_count += 1;

    for (0..PROCESS_MAX_COUNT) |id| {
        if (!read_bitmap(&processes_idmap, id)) {
            write_bitmap(&processes_idmap, id, true);
            return @intCast(id);
        }
    }

    return Error.TooMuchProcess;
}

fn freeId(id: u32) void {
    if (comptime builtin.mode == .Debug) {
        if (!read_bitmap(&processes_idmap, id)) {
            std.log.warn("ProcessID '{}' has been freed while being free.", .{id});
        }
    }

    if (processes_count != 0) {
        processes_count -= 1;
    }

    write_bitmap(&processes_idmap, id, false);
}

inline fn read_bitmap(bitmap: []u64, index: u64) bool {
    const bit_index = index % 64;
    const word_index = index / 64;
    const word = bitmap[word_index];
    const mask: u64 = @as(u64, 1) << @as(u6, @intCast(bit_index));
    return (word & mask) != 0;
}

inline fn write_bitmap(bitmap: []u64, index: u64, value: bool) void {
    const bit_index = index % 64;
    const word_index = index / 64;

    const mask: u64 = @as(u64, 1) << @as(u6, @intCast(bit_index));
    if (value) {
        bitmap[word_index] |= mask;
    } else {
        bitmap[word_index] &= ~mask;
    }
}
