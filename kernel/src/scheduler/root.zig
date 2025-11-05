// --- dependencies --- //

const std = @import("std");
const builtin = @import("builtin");
const basalt = @import("basalt");
const ark = @import("ark");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const virt = mem.virt;

// --- scheduler/root.zig --- //

pub fn getCurrentProcess() *Process {
    unreachable;
}

pub fn getCurrentTask() *Task {
    unreachable;
}

fn getNextProcess() *Process {
    unreachable;
}

fn getNextTask() *Task {
    unreachable;
}

pub fn acknowledgeTimer(arch_data: *anyopaque) void {
    // TODO treat it as an event.
    _ = arch_data;
    std.log.info("scheduler timer acknowledgment in cpu{}", .{kernel.arch.Cpu.id()});
}

fn armTimer(task: *Task) void {
    const precision = task.options.precision.toDelay();
    const quantum = task.options.quantum.toDelay();

    if (@intFromEnum(quantum) < @intFromEnum(precision)) {
        kernel.drivers.Timer.arm(quantum);
    } else {
        kernel.drivers.Timer.arm(precision);
    }
}

pub fn switchProcess(arch_data: *anyopaque) void {
    _ = arch_data;
}

pub fn switchTask(arch_data: *anyopaque) void {
    _ = arch_data;
}

pub fn terminateProcess(arch_data: *anyopaque) void {
    _ = arch_data;
    unreachable;
}

pub fn terminateTask(arch_data: *anyopaque) void {
    _ = arch_data;
    unreachable;
}

pub fn init() !void {
    // ...
    try initCpu();
}

pub fn initCpu() !void {
    const cpu = kernel.arch.Cpu.get();
    cpu.process = null;
    cpu.task = null;
}

pub const ExecutionLevel = enum {
    kernel,
    /// For modules and system' services.
    system,
    user,
};

pub const Process = struct {
    id: u16,
    tasks: []Task,
    last_task_id: u16,
    execution_level: ExecutionLevel,
    virt_space: virt.Space,
    context: kernel.arch.ProcessContext,

    // pub fn new(execution_level: ExecutionLevel) *@This() {
    //     const id = newId();
    //     procs[id].id = id;
    //     procs[id].last_task_id = 0;

    //     const page_count = std.mem.alignForward(u64, @sizeOf(Task) * std.math.maxInt(u16), mem.PageLevel.l4K.size()) >> 12;
    //     procs[id].tasks.ptr = @ptrFromInt(mem.heap.alloc(&mem.virt.kernel_space, .l4K, @intCast(page_count), .{
    //         .writable = true,
    //     }));
    //     procs[id].tasks.len = 0;

    //     if (execution_level == .user) {
    //         procs[id].virt_space = .init(.lower, mem.phys.allocPage(.l4K, true) catch unreachable);
    //     }

    //     procs[id].execution_level = execution_level;

    //     return &procs[id];
    // }

    pub fn virtSpace(self: *@This()) *virt.Space {
        return if (self.execution_level == .user) &self.virt_space else &virt.kernel_space;
    }

    // pub fn loadELF(self: *@This(), file: []const u8) !void {
    //     _ = self;
    //     _ = file;
    //     unreachable;
    // }

    // fn newTaskId(self: *@This()) u16 {
    //     self.tasks.len += 1;
    //     defer self.last_task_id += 1;
    //     return self.last_task_id;
    // }

    // pub fn newTask(
    //     self: *@This(),
    //     entry_point: *const fn () callconv(.{ .aarch64_aapcs = .{} }) noreturn,
    //     task_options: basalt.task.TaskOptions,
    // ) *Task {
    //     const id = self.newTaskId();
    //     self.tasks[id].process = self.id;
    //     self.tasks[id].id = id;
    //     self.tasks[id].options = task_options;
    //     self.tasks[id].state = .ready;
    //     self.tasks[id].entry_point = entry_point;

    //     switch (builtin.cpu.arch) {
    //         .aarch64 => {
    //             self.tasks[id].context = .{
    //                 .lr = 0,
    //                 .xregs = undefined,
    //                 .vregs = undefined,
    //                 .fpcr = 0,
    //                 .fpsr = 0,
    //                 .elr_el1 = @intFromPtr(entry_point),
    //                 .spsr_el1 = .{
    //                     .mode = if (self.execution_level == .user) .el0 else .el1t,
    //                 },
    //                 // TODO TODO TODO GUARD PAGE !!!!!!!!!!!!!!!!!!!!!!!!!!! (yes that's very important)
    //                 .sp = mem.heap.alloc(self.virtSpace(), .l4K, 16, .{
    //                     .writable = true,
    //                     .user = self.execution_level == .user,
    //                 }),
    //             };

    //             @memset(&self.tasks[id].context.xregs, 0);
    //             @memset(&self.tasks[id].context.vregs, 0);
    //         },
    //         else => unreachable,
    //     }

    //     return &self.tasks[id];
    // }
};

pub const Task = struct {
    process: u16,
    id: u16,
    options: basalt.task.TaskOptions,
    state: State,
    entry_point: *const fn () callconv(.{ .aarch64_aapcs = .{} }) noreturn,
    context: kernel.arch.TaskContext,

    pub const State = enum {
        first_entry,
        ready,
    };
};
