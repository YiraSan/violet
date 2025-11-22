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

pub const SyscallFn = *const fn (*kernel.arch.ExceptionContext) callconv(basalt.task.call_conv) void;

pub var registers: [basalt.syscall.MAX_CODE]u64 = undefined;

pub fn init() !void {
    @memset(&registers, 0);

    register(.null, &null_syscall);
}

pub fn register(code: basalt.syscall.Code, syscall_fn: SyscallFn) void {
    registers[@intFromEnum(code)] = @intFromPtr(syscall_fn);
}

fn null_syscall(context: *kernel.arch.ExceptionContext) callconv(basalt.task.call_conv) void {
    success(context);
}

pub fn success(context: *kernel.arch.ExceptionContext) void {
    context.setArg(0, @bitCast(basalt.syscall.Result{
        .is_success = true,
    }));
}

pub fn fail(context: *kernel.arch.ExceptionContext, code: basalt.syscall.ErrorCode) void {
    context.setArg(0, @bitCast(basalt.syscall.Result{
        .is_success = false,
        .code = @intFromEnum(code),
    }));
}

pub fn isAddressSafe(virt_address: u64, writable: bool) bool {
    const local = kernel.scheduler.Local.get();

    if (local.current_task) |current_task| {
        const region = current_task.process.virtualSpace().allocator.findRegion(virt_address);

        if (region) |reg| {
            if (reg.object) |object| {
                if (!object.flags.writable and writable) return false;

                return true;
            }
        }
    } else {
        @panic("syscall.isAddressSafe called outside a task !");
    }

    return false;
}
