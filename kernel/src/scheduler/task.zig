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
const ark = @import("ark");
const basalt = @import("basalt");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const scheduler = kernel.scheduler;
const syscall = kernel.syscall;

const heap = mem.heap;
const vmm = mem.vmm;

const Process = scheduler.Process;

// --- scheduler/task.zig --- //

const Task = @This();
const TaskMap = heap.SlotMap(Task);
pub const Id = TaskMap.Key;

pub const STACK_PAGE_COUNT = 16; // 64 KiB
pub const STACK_SIZE = STACK_PAGE_COUNT * mem.PageLevel.l4K.size();

var tasks_map: TaskMap = .init();
var tasks_map_lock: mem.RwLock = .{};

id: Id,
process: *scheduler.Process,

ref_count: std.atomic.Value(usize),
state: std.atomic.Value(State),

priority: basalt.task.Priority,
quantum: basalt.time.Delay,
uptime_schedule: u64, // When it has been scheduled last
uptime_suspend: u64, // When it has been suspended last

host_id: u8,
host_affinity: u8,

base_stack: u64,

exception: bool,
suspended: bool,
/// NOTE: We default to Eager switching for three reasons:
/// 1. Security: Lazy switching is vulnerable to side-channels on x86_64 (CVE-2018-3665).
/// 2. Real-Time: Eager switching guarantees deterministic context switch timing.
/// 3. Performance: On AArch64/RISC-V, almost all processes use SIMD, making Lazy logic pure overhead.
should_extend: bool,
is_extended: bool,
exception_data: kernel.arch.ExceptionData,
stack_pointer: extern union {
    general: *kernel.arch.GeneralFrame,
    extended: *kernel.arch.ExtendedFrame,
},

// next_listener: ?*Task,

futures_lock: mem.RwLock,
futures_generation: u64,
futures_waitmode: basalt.sync.Future.WaitMode,
futures_payloads: [128]u64,
futures_statuses: [128]basalt.sync.Future.Status,
futures_pending: u8,
futures_resolved: u8,
futures_canceled: u8,

futures_userland_len: u64,
futures_userland_payloads_ptr: u64,
futures_userland_statuses_ptr: u64,

futures_failfast_index: ?u8,

kernel_locals_kernel: *basalt.syscall.KernelLocals,
kernel_locals_userland: u64,

pub fn create(process_id: Process.Id, options: Options) !Id {
    const process = Process.acquire(process_id) orelse return Error.InvalidProcess;
    errdefer process.release();

    var task: Task = undefined;
    task.process = process;

    task.ref_count = .init(0);
    task.state = .init(.ready);

    task.priority = options.priority;
    task.quantum = options.quantum.toDelay();
    task.uptime_schedule = 0;
    task.uptime_suspend = 0;

    task.host_id = 0;
    task.host_affinity = 16;

    // task.next_listener = null;

    // TODO GUARD PAGES

    const stack_object = try vmm.Object.create(STACK_SIZE, .{ .writable = true });

    const vs = task.process.virtualSpace();
    task.base_stack = try vs.map(
        stack_object,
        STACK_SIZE,
        0,
        0,
        null,
        true,
    );
    errdefer vs.unmap(task.base_stack, false) catch {};

    const kernel_stack_base = try vmm.kernel_space.map(
        stack_object,
        STACK_SIZE,
        0,
        0,
        null,
        true,
    );
    defer vmm.kernel_space.unmap(kernel_stack_base, false) catch {};

    task.exception = true;
    task.suspended = true;
    task.should_extend = true;
    task.is_extended = true; // NOTE starting on "is_extended" to avoid leaking data from the last task.

    task.exception_data.init(&task);

    const frame_offset = STACK_SIZE - @sizeOf(kernel.arch.ExtendedFrame);

    task.stack_pointer = .{ .extended = @ptrFromInt(task.base_stack + frame_offset) };

    const kernel_stack_pointer: *kernel.arch.ExtendedFrame = @ptrFromInt(kernel_stack_base + frame_offset);

    kernel_stack_pointer.general_frame.program_counter = options.entry_point;
    kernel_stack_pointer.general_frame.stack_pointer = task.base_stack + STACK_SIZE;

    // NOTE on x86_64 initializing to zero the SSE context isn't valid. (MXCSR)

    // std.log.warn("umbilical id not given to task !!!!", .{});

    if (task.process.isPrivileged()) {
        kernel_stack_pointer.general_frame.setArg(1, @intFromPtr(&syscall.kernel_indirection_table));
    }

    task.futures_lock = .{};
    task.futures_generation = 0;
    task.futures_waitmode = undefined;
    task.futures_payloads = undefined;
    task.futures_statuses = undefined;
    task.futures_pending = 0;
    task.futures_resolved = 0;
    task.futures_canceled = 0;

    task.futures_userland_payloads_ptr = 0;
    task.futures_userland_statuses_ptr = 0;

    task.futures_failfast_index = null;

    const locals_object = try vmm.Object.create(@sizeOf(basalt.syscall.KernelLocals), .{});

    task.kernel_locals_userland = try vs.map(
        locals_object,
        @sizeOf(basalt.syscall.KernelLocals),
        0,
        0,
        null,
        true,
    );
    errdefer vs.unmap(task.kernel_locals_userland, false) catch {};

    task.kernel_locals_kernel = @ptrFromInt(try vmm.kernel_space.map(
        locals_object,
        @sizeOf(basalt.syscall.KernelLocals),
        0,
        0,
        .{ .writable = true },
        true,
    ));
    errdefer vmm.kernel_space.unmap(@intFromPtr(task.kernel_locals_kernel), false) catch {};

    task.kernel_locals_kernel.process_id = @bitCast(process_id);


    const lock_flags = tasks_map_lock.lockExclusive();
    defer tasks_map_lock.unlockExclusive(lock_flags);

    const slot_key = try tasks_map.insert(task);
    const task_ptr = tasks_map.get(slot_key) orelse unreachable;
    task_ptr.id = slot_key;

    _ = task_ptr.process.task_count.fetchAdd(1, .acq_rel);

    task.kernel_locals_kernel.task_id = @bitCast(slot_key);

    return slot_key;
}

pub fn extendFrame(self: *Task) void {
    if (!self.suspended) {
        self.suspended = true;

        if (!self.is_extended and self.should_extend) {
            self.stack_pointer.extended = kernel.arch.extend_frame(self.stack_pointer.general);
            self.is_extended = true;
        }
    }
}

pub fn kill(self: *Task) void {
    self.state.store(.dying, .release);
}

fn destroy(self: *Task) void {
    const lock_flags = tasks_map_lock.lockExclusive();
    defer tasks_map_lock.unlockExclusive(lock_flags);

    if (self.ref_count.load(.acquire) > 0) {
        return;
    }

    const process = self.process;
    defer process.release();

    defer tasks_map.remove(self.id);

    self.process.virtualSpace().unmap(self.base_stack, false) catch {};
    self.process.virtualSpace().unmap(self.kernel_locals_userland, false) catch {};

    vmm.kernel_space.unmap(@intFromPtr(self.kernel_locals_kernel), false) catch {};
}

pub fn acquire(id: Id) ?*Task {
    const lock_flags = tasks_map_lock.lockShared();
    defer tasks_map_lock.unlockShared(lock_flags);

    const task: *Task = tasks_map.get(id) orelse return null;
    if (task.state.load(.acquire) == .dying) return null;

    _ = task.ref_count.fetchAdd(1, .acq_rel);

    return task;
}

/// Invalidate Process pointer.
pub fn release(self: *Task) void {
    if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
        self.destroy();
    }
}

pub inline fn isDying(self: *const Task) bool {
    return self.state.load(.acquire) == .dying;
}

pub inline fn penalty(self: *const Task) u64 {
    const userland_penalty: u64 = if (self.process.isPrivileged()) 0 else 250 * std.time.ns_per_us;

    const priority_penalty: u64 = switch (self.priority) {
        .background => 500 * std.time.ns_per_ms,
        .normal => 50 * std.time.ns_per_ms,
        .reactive => 5 * std.time.ns_per_ms,
        .realtime => 0,
    };

    return priority_penalty + userland_penalty;
}

pub inline fn updateAffinity(self: *Task) void {
    if (self.priority != .realtime) {
        if (self.host_id != kernel.arch.Cpu.id()) {
            self.host_affinity -= 1;
            if (self.host_affinity == 0) {
                self.host_id = kernel.arch.Cpu.id();
                self.host_affinity = 24;
            }
        } else {
            self.host_affinity = @min(self.host_affinity + 1, 254);
        }
    }
}

// ---- //

pub const Options = struct {
    entry_point: u64,
    priority: basalt.task.Priority = .normal,
    quantum: basalt.task.Quantum = .moderate,
};

pub const State = enum(u8) {
    ready,
    dying,
    waiting,
    waiting_queued,
};

pub const Error = error{
    InvalidProcess,
};
