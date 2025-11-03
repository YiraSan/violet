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

pub const LocalStorage = struct {
    pub const TPIDRRO_EL0 = packed struct(u64) {
        process_id: u16,
        task_id: u16,
        _reserved1: u32,

        pub fn get() @This() {
            const val = ark.cpu.armv8a_64.registers.TPIDRRO_EL0.get().value;
            return @bitCast(val);
        }

        pub fn set(self: @This()) void {
            const reg = ark.cpu.armv8a_64.registers.TPIDRRO_EL0{ .value = @bitCast(self) };
            reg.set();
        }
    };

    pub fn getProcessId() u16 {
        return TPIDRRO_EL0.get().process_id;
    }

    pub fn getTaskId() u16 {
        return TPIDRRO_EL0.get().task_id;
    }

    pub fn setProcessId(process_id: u16) void {
        var reg = TPIDRRO_EL0.get();
        reg.process_id = process_id;
        reg.set();
    }

    pub fn setTaskId(task_id: u16) void {
        var reg = TPIDRRO_EL0.get();
        reg.task_id = task_id;
        reg.set();
    }
};

pub fn getTimerDelay() kernel.drivers.Timer.Delay {
    unreachable;
}

pub fn getCurrentProcess() *Process {
    const process_id = LocalStorage.getProcessId();
    return &Process.procs[process_id];
}

pub fn getCurrentTask() *Task {
    const process = getCurrentProcess();
    const task_id = LocalStorage.getTaskId();
    return &process.tasks[task_id];
}

fn getNextProcess() *Process {
    return getCurrentProcess(); // TODO
}

fn getNextTask() *Task {
    // TODO a WAY better algorithm.
    const process = getCurrentProcess();
    var task_id = LocalStorage.getTaskId();
    task_id = @intCast((task_id + 1) % process.tasks.len);
    return &process.tasks[task_id];
}

pub fn acknowledgeTimer(arch_data: *anyopaque) void {
    // TODO treat it as an event.
    switchProcess(arch_data);
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

pub fn firstEntry(arch_data: *anyopaque) void {
    LocalStorage.setProcessId(0);
    LocalStorage.setTaskId(0);

    var process = &Process.procs[0];
    var task = &process.tasks[0];

    kernel.arch.loadContext(arch_data, &process.context, &task.context);

    armTimer(task);
}

pub fn switchProcess(arch_data: *anyopaque) void {
    const current_process = getCurrentProcess();
    const next_process = getNextProcess();

    if (current_process == next_process) return switchTask(arch_data);

    kernel.arch.storeContext(arch_data, &current_process.context, null);

    LocalStorage.setProcessId(next_process.id);
    kernel.arch.loadContext(arch_data, &next_process.context, null);

    unreachable;
}

pub fn switchTask(arch_data: *anyopaque) void {
    const current_task = getCurrentTask();
    const next_task = getNextTask();

    defer armTimer(next_task);

    if (current_task == next_task) return;

    kernel.arch.storeContext(arch_data, null, &current_task.context);

    LocalStorage.setTaskId(next_task.id);
    kernel.arch.loadContext(arch_data, null, &next_task.context);
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
    const procs_page_count = std.mem.alignForward(u64, @sizeOf(Process) * std.math.maxInt(u16), mem.PageLevel.l4K.size()) >> 12;
    Process.procs.ptr = @ptrFromInt(mem.heap.alloc(&mem.virt.kernel_space, .l4K, @intCast(procs_page_count), .{ .writable = true }));
    Process.procs.len = 0;
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

    // TODO ids needs way better managment.

    pub var procs: []Process = undefined;
    var last_id: u16 = 0;
    fn newId() u16 {
        procs.len += 1;
        defer last_id += 1;
        return last_id;
    }

    pub fn new(execution_level: ExecutionLevel) *@This() {
        const id = newId();
        procs[id].id = id;
        procs[id].last_task_id = 0;

        const page_count = std.mem.alignForward(u64, @sizeOf(Task) * std.math.maxInt(u16), mem.PageLevel.l4K.size()) >> 12;
        procs[id].tasks.ptr = @ptrFromInt(mem.heap.alloc(&mem.virt.kernel_space, .l4K, @intCast(page_count), .{
            .writable = true,
        }));
        procs[id].tasks.len = 0;

        if (execution_level == .user) {
            procs[id].virt_space = .init(.lower, mem.phys.alloc_page(.l4K, true) catch unreachable);
        }

        procs[id].execution_level = execution_level;

        return &procs[id];
    }

    pub fn virtSpace(self: *@This()) *virt.Space {
        return if (self.execution_level == .user) &self.virt_space else &virt.kernel_space;
    }

    pub fn loadELF(self: *@This(), file: []const u8) !void {
        _ = self;
        _ = file;
        unreachable;
    }

    fn newTaskId(self: *@This()) u16 {
        self.tasks.len += 1;
        defer self.last_task_id += 1;
        return self.last_task_id;
    }

    pub fn newTask(
        self: *@This(),
        entry_point: *const fn () callconv(.{ .aarch64_aapcs = .{} }) noreturn,
        task_options: basalt.task.TaskOptions,
    ) *Task {
        const id = self.newTaskId();
        self.tasks[id].process = self.id;
        self.tasks[id].id = id;
        self.tasks[id].options = task_options;
        self.tasks[id].state = .ready;
        self.tasks[id].entry_point = entry_point;

        switch (builtin.cpu.arch) {
            .aarch64 => {
                self.tasks[id].context = .{
                    .lr = 0,
                    .xregs = undefined,
                    .vregs = undefined,
                    .fpcr = 0,
                    .fpsr = 0,
                    .elr_el1 = @intFromPtr(entry_point),
                    .spsr_el1 = .{
                        .mode = if (self.execution_level == .user) .el0 else .el1t,
                    },
                    // TODO TODO TODO GUARD PAGE !!!!!!!!!!!!!!!!!!!!!!!!!!! (yes that's very important)
                    .sp = mem.heap.alloc(self.virtSpace(), .l4K, 16, .{
                        .writable = true,
                        .user = self.execution_level == .user,
                    }),
                };

                @memset(&self.tasks[id].context.xregs, 0);
                @memset(&self.tasks[id].context.vregs, 0);
            },
            else => unreachable,
        }

        return &self.tasks[id];
    }
};

pub const Task = struct {
    process: u16,
    id: u16,
    options: basalt.task.TaskOptions,
    state: State,
    entry_point: *const fn () callconv(.{ .aarch64_aapcs = .{} }) noreturn,
    context: kernel.arch.TaskContext,

    pub const State = enum {
        ready,
    };
};
