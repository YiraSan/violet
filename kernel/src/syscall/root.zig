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

// --- syscall/root.zig --- //

pub const SyscallFn = *const fn (*kernel.arch.GeneralFrame) anyerror!void;

var registers: [basalt.syscall.MAX_CODE]u64 = undefined;

pub var kernel_indirection_table: basalt.module.KernelIndirectionTable = undefined;

pub fn init() !void {
    @memset(&registers, 0);

    register(.null, &null_syscall);

    basalt.module.kernel_indirection_table = &kernel_indirection_table;
}

pub export fn internal_call_system(frame: *kernel.arch.GeneralFrame) callconv(basalt.task.call_conv) void {
    const code = frame.getArg(0);

    if (code < registers.len) {
        const syscall_fn_val = registers[code];
        if (syscall_fn_val != 0) {
            const syscall_fn: SyscallFn = @ptrFromInt(syscall_fn_val);

            frame.setArg(0, @bitCast(basalt.syscall.Result{
                .is_success = false,
                .value = .{ .err = .{ .error_code = .internal_failure } },
            }));

            return syscall_fn(frame) catch {};
        }
    }

    frame.setArg(0, @bitCast(basalt.syscall.Result{
        .is_success = false,
        .value = .{ .err = .{ .error_code = .unknown_syscall } },
    }));
}

pub fn register(code: basalt.syscall.Code, syscall_fn: SyscallFn) void {
    registers[@intFromEnum(code)] = @intFromPtr(syscall_fn);
}

fn null_syscall(frame: *kernel.arch.GeneralFrame) !void {
    success(frame, .{});
}

pub fn success(frame: *kernel.arch.GeneralFrame, values: basalt.syscall.ReturnValues) void {
    frame.setArg(0, @bitCast(basalt.syscall.Result{
        .is_success = true,
        .value = .{
            .success = .{ .success0 = values.success0, .success1 = values.success1 },
        },
    }));

    frame.setArg(1, values.success2);
}

pub fn fail(frame: *kernel.arch.GeneralFrame, code: basalt.syscall.ErrorCode) !void {
    frame.setArg(0, @bitCast(basalt.syscall.Result{
        .is_success = false,
        .value = .{ .err = .{
            .error_code = code,
        } },
    }));

    return error._;
}

pub fn pin(task: *kernel.scheduler.Task, virt_address: u64, T: type, count: usize, writable: bool) bool {
    if (!std.mem.isAligned(virt_address, @alignOf(T))) return false;

    const vs = task.process.virtualSpace();
    const lock_flags = vs.allocator.lock.lockShared();
    defer vs.allocator.lock.unlockShared(lock_flags);

    const region_id = vs.allocator.regions.find(virt_address) orelse return false;
    const region = vs.allocator.regions.get(region_id).?;

    if (region.object) |object| {
        if (region.end - virt_address < @sizeOf(T) * count) return false;
        if (!object.flags.writable and writable) return false;

        _ = region.syscall_pinned.fetchAdd(1, .acq_rel);

        return true;
    }

    return false;
}

pub fn unpin(task: *kernel.scheduler.Task, virt_address: u64) void {
    const vs = task.process.virtualSpace();
    const lock_flags = vs.allocator.lock.lockShared();
    defer vs.allocator.lock.unlockShared(lock_flags);

    const region_id = vs.allocator.regions.find(virt_address) orelse return;
    const region = vs.allocator.regions.get(region_id).?;

    _ = region.syscall_pinned.fetchSub(1, .acq_rel);
}
