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

const module = basalt.module;

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const scheduler = kernel.scheduler;
const syscall = kernel.syscall;

const vmm = mem.vmm;

// --- mem/syscall.zig --- //

pub fn init() !void {
    syscall.register(.mem_map, &mem_map);
    syscall.register(.mem_unmap, &mem_unmap);
}

fn mem_map(frame: *kernel.arch.GeneralFrame) !void {
    const sched_local = scheduler.Local.get();

    if (sched_local.current_task) |task| {
        const vs = task.process.virtualSpace();

        const address_addr = frame.getArg(1);
        if (!syscall.pin(task, address_addr, u64, 1, true)) return try syscall.fail(frame, .invalid_pointer);
        defer syscall.unpin(task, address_addr);
        const address_ptr: *u64 = @ptrFromInt(address_addr);

        const count = frame.getArg(2); // TODO maybe add a limit or something.
        const size = count * basalt.heap.PAGE_SIZE;

        const alignment = frame.getArg(3);
        if (!std.mem.isValidAlign(alignment)) return try syscall.fail(frame, .invalid_argument);

        var errored = false;

        const object = vmm.Object.create(size, .{}) catch return try syscall.fail(frame, .internal_failure);
        defer if (errored) if (vmm.Object.acquire(object)) |obj| {
            obj.release();
        };

        address_ptr.* = vs.map(
            object,
            size,
            alignment,
            0,
            .{ .writable = true },
        ) catch {
            errored = true;
            return try syscall.fail(frame, .internal_failure);
        };

        return syscall.success(frame, .{});
    } else {
        return try syscall.fail(frame, .unknown_syscall);
    }
}

fn mem_unmap(frame: *kernel.arch.GeneralFrame) !void {
    const sched_local = scheduler.Local.get();

    if (sched_local.current_task) |current_task| {
        const address = frame.getArg(1);

        current_task.process.virtualSpace().unmap(address, true) catch |err| {
            switch (err) {
                vmm.Allocator.Error.InvalidAddress => return syscall.fail(frame, .invalid_argument),
                else => return syscall.fail(frame, .internal_failure),
            }
        };

        return syscall.success(frame, .{});
    } else {
        return syscall.fail(frame, .unknown_syscall);
    }
}
