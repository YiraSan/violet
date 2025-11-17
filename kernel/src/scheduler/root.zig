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

const process = @import("process.zig");
pub const Process = process.Process;
pub const Task = process.Task;

// --- scheduler/root.zig --- //

var incomming_tasks: mem.Queue(*Task) = .{};
var incomming_tasks_lock: mem.SpinLock = .{};

pub fn registerTask(task: *Task) !void {
    incomming_tasks_lock.lock();
    defer incomming_tasks_lock.unlock();

    try incomming_tasks.append(task);
}

pub fn acknowledgeTimer(arch_data: *anyopaque) void {
    const cpu = kernel.arch.Cpu.get();

    // TODO register timer event

    if (cpu.current_task) |task| {
        if (task.isTerminated() or task.process.isTerminated()) {
            task.destroy();
            cpu.current_task = null;
        }
    }

    if (cpu.current_task) |current_task| {
        current_task.quantum_elapsed_ns += getTimerPrecision(current_task).nanoseconds();

        if (current_task.quantum_elapsed_ns < current_task.quantum.toDelay().nanoseconds()) {
            kernel.drivers.Timer.arm(getTimerPrecision(current_task));
            return;
        }

        kernel.arch.Context.store(current_task, arch_data);
    }

    const nlast_task = cpu.current_task;

    if (switchTask(arch_data)) {
        if (nlast_task) |task| {
            cpu.queue_tasks.append(task) catch @panic("oops scheduler out of memory");
        }
        return;
    } else if (cpu.current_task) |task| {
        kernel.drivers.Timer.arm(getTimerPrecision(task));
    } else {
        idle(arch_data);
    }
}

pub fn terminateProcess(arch_data: *anyopaque) void {
    const cpu = kernel.arch.Cpu.get();

    if (cpu.current_task) |current_task| {
        current_task.process.terminate();
        current_task.destroy();
        cpu.current_task = null;
    }

    if (!switchTask(arch_data)) {
        idle(arch_data);
    }
}

pub fn terminateTask(arch_data: *anyopaque) void {
    const cpu = kernel.arch.Cpu.get();

    if (cpu.current_task) |current_task| {
        current_task.terminate();
        current_task.destroy();
        cpu.current_task = null;
    }

    if (!switchTask(arch_data)) {
        idle(arch_data);
    }
}

fn idle(arch_data: *anyopaque) void {
    const cpu = kernel.arch.Cpu.get();

    kernel.arch.Context.load(cpu.idle_task, arch_data);

    if (true) { // "true" means: no event to wait for
        kernel.drivers.Timer.arm(._100ms);
    } else {
        // ...
    }
}

fn getTimerPrecision(task: *Task) basalt.timer.Delay {
    const timer_precision = task.timer_precision.toDelay();
    const quantum = task.quantum.toDelay();

    if (@intFromEnum(quantum) < @intFromEnum(timer_precision)) {
        return quantum;
    } else {
        return timer_precision;
    }
}

fn switchTask(arch_data: *anyopaque) bool {
    const cpu = kernel.arch.Cpu.get();

    var ntask: ?*Task = null;

    const cpu_task_ready = cpu.queue_tasks.count() > 0;

    if (cpu.cycle_done >= (cpu.queue_tasks.count() / 15 + 1) or !cpu_task_ready) {
        incomming_tasks_lock.lock();
        defer incomming_tasks_lock.unlock();

        if (incomming_tasks.count() > 0) {
            ntask = incomming_tasks.pop();
        }
    }

    if (cpu_task_ready and ntask == null) {
        ntask = cpu.queue_tasks.pop();
    }

    if (ntask) |task| {
        if (task.process.isTerminated() or task.isTerminated()) {
            task.destroy();
            return switchTask(arch_data);
        }

        if (cpu.current_task) |current_task| {
            if (current_task.process.id != task.process.id) {
                task.process.virtual_space.apply();
            }
        } else {
            task.process.virtual_space.apply();
        }

        cpu.current_task = task;
        cpu.cycle_done += 1;
        kernel.arch.Context.load(task, arch_data);
        kernel.drivers.Timer.arm(getTimerPrecision(task));
        log.debug("cpu{} switched on task {}:{}", .{ cpu.mpidr, cpu.current_task.?.process.id, cpu.current_task.?.id });

        return true;
    } else {
        cpu.cycle_done = 0;
    }

    return false;
}

var idle_process: *Process = undefined;

pub fn init() !void {
    try process.init();

    idle_process = try Process.create(.{ .execution_level = .kernel }); // .kernel is used to avoid creating a virtual space.

    try initCpu();
}

pub fn initCpu() !void {
    const cpu = kernel.arch.Cpu.get();
    cpu.current_task = null;
    cpu.queue_tasks = .{};
    cpu.cycle_done = 0;
    cpu.idle_task = try idle_process.createTask(.{ .entry_point = &idle_task });
}

fn idle_task(_: *[0x1000]u8) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    // NOTE in the future this will be used to check for event that doesn't create interruption.
    ark.cpu.halt();
}
