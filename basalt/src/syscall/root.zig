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
const builtin = @import("builtin");

// --- imports --- //

const basalt = @import("basalt");

const module = basalt.module;

// --- syscall/root.zig --- //

/// Defines the suspension strategy for asynchronous system calls (Prism IPC).
/// This enum allows callers to explicitly control execution flow or delegate
/// the decision to the kernel based on the scheduling context.
pub const SuspendBehavior = enum(u64) {
    /// **Context-Aware (Recommended for Libraries).**
    ///
    /// Delegates the decision to the kernel scheduler:
    /// - **Real-Time Tasks:** Treated as `.no_suspend`. Returns `WouldSuspend` immediately.
    /// - **Other Tasks:** Treated as `.wait`. Suspends execution until the resource is available.
    ///
    /// Libraries should prefer this mode to remain compatible with both realtime
    /// and throughput-oriented workloads without code duplication.
    default = 0,

    /// **Force Suspension.**
    ///
    /// The task enters the `waiting` state if the operation cannot complete immediately.
    /// **Warning:** Using this in a Real-Time task will induce unpredictable latency (jitter)
    /// and may violate deadline guarantees.
    wait = 1,

    /// **Force Poll.**
    ///
    /// The syscall returns immediately with a WouldSuspend if the operation
    /// cannot complete. The task is never suspended.
    no_suspend = 2,
};

// pub const ResolveStatus = enum(u64) {
//     /// anything that is not 1 or 2 is considered "fail".
//     fail = 0,
//     success = 1,
//     cancel = 2,
// };

// NOTE this have to be synchronized with Code.
pub const MAX_CODE: usize = 128;

pub const Code = enum(u64) {
    null = 0x00,

    mem_map = 0x10,
    mem_seal = 0x11,
    mem_unmap = 0x12,
    mem_share = 0x13,
    mem_accept = 0x14,

    process_terminate = 0x20,

    task_terminate = 0x30,
    task_yield = 0x31,

    prism_create = 0x40,
    prism_destroy = 0x41,
    prism_consume = 0x42,

    facet_create = 0x51,
    facet_destroy = 0x52,
    facet_invoke = 0x53,

    future_create = 0x61,
    future_resolve = 0x62,
    future_await = 0x63,

    timer_single = 0x70,
    timer_sequential = 0x71,
};

pub const Error = error{
    UnknownSyscall,
    InternalFailure,

    InvalidPointer,
    InvalidArgument,
    InvalidPrism,
    InvalidFuture,

    WouldSuspend,
    Insolvent,
};

pub const ErrorCode = enum(u16) {
    unknown_syscall = 0,
    internal_failure = 1,

    invalid_pointer = 2,
    invalid_argument = 3,
    invalid_prism = 4,
    invalid_future = 5,

    would_suspend = 6,
    insolvent = 7,

    pub fn toError(self: @This()) Error!void {
        switch (self) {
            .unknown_syscall => return Error.UnknownSyscall,
            .internal_failure => return Error.InternalFailure,

            .invalid_pointer => return Error.InvalidPointer,
            .invalid_argument => return Error.InvalidArgument,
            .invalid_prism => return Error.InvalidPrism,
            .invalid_future => return Error.InvalidFuture,

            .would_suspend => return Error.WouldSuspend,

            .insolvent => return Error.Insolvent,
        }
    }
};

pub const Result = packed struct(u64) {
    is_success: bool, // bit 0
    _reserved0: u15 = 0, // bit 1-15
    value: packed union {
        err: packed struct(u48) {
            error_code: ErrorCode = .unknown_syscall, // bit 16-31
            _reserved1: u32 = 0, // bit 32-63
        },
        success: packed struct(u48) {
            success0: u16 = 0, // bit 16-31
            success1: u32 = 0, // bit 32-63
        },
    },
};

pub const ReturnValues = struct {
    success0: u16 = 0,
    success1: u32 = 0,
    success2: u64 = 0,
};

inline fn syscall_fn(code: Code, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64, arg7: u64) extern struct { syscall_result: Result, success2: u64 } {
    var syscall_result: Result = undefined;
    var success2: u64 = undefined;

    switch (builtin.cpu.arch) {
        .aarch64 => {
            asm volatile (
                \\ svc #0
                : [out0] "={x0}" (syscall_result),
                  [out1] "={x1}" (success2),
                : [code] "{x0}" (code),
                  [arg1] "{x1}" (arg1),
                  [arg2] "{x2}" (arg2),
                  [arg3] "{x3}" (arg3),
                  [arg4] "{x4}" (arg4),
                  [arg5] "{x5}" (arg5),
                  [arg6] "{x6}" (arg6),
                  [arg7] "{x7}" (arg7),
                : "memory", "cc"
            );
        },
        else => unreachable,
    }

    return .{
        .syscall_result = syscall_result,
        .success2 = success2,
    };
}

pub inline fn syscall0(code: Code) Error!ReturnValues {
    const res = if (comptime module.is_module)
        module.kernel_indirection_table.call_system(code, undefined, undefined, undefined, undefined, undefined, undefined, undefined)
    else
        syscall_fn(code, undefined, undefined, undefined, undefined, undefined, undefined, undefined);

    if (!res.syscall_result.is_success) {
        try res.syscall_result.value.err.error_code.toError();
        unreachable;
    }

    return .{
        .success0 = res.syscall_result.value.success.success0,
        .success1 = res.syscall_result.value.success.success1,
        .success2 = res.success2,
    };
}

pub inline fn syscall1(code: Code, arg1: u64) Error!ReturnValues {
    const res = if (comptime module.is_module)
        module.kernel_indirection_table.call_system(code, arg1, undefined, undefined, undefined, undefined, undefined, undefined)
    else
        syscall_fn(code, arg1, undefined, undefined, undefined, undefined, undefined, undefined);

    if (!res.syscall_result.is_success) {
        try res.syscall_result.value.err.error_code.toError();
        unreachable;
    }

    return .{
        .success0 = res.syscall_result.value.success.success0,
        .success1 = res.syscall_result.value.success.success1,
        .success2 = res.success2,
    };
}

pub inline fn syscall2(code: Code, arg1: u64, arg2: u64) Error!ReturnValues {
    const res = if (comptime module.is_module)
        module.kernel_indirection_table.call_system(code, arg1, arg2, undefined, undefined, undefined, undefined, undefined)
    else
        syscall_fn(code, arg1, arg2, undefined, undefined, undefined, undefined, undefined);

    if (!res.syscall_result.is_success) {
        try res.syscall_result.value.err.error_code.toError();
        unreachable;
    }

    return .{
        .success0 = res.syscall_result.value.success.success0,
        .success1 = res.syscall_result.value.success.success1,
        .success2 = res.success2,
    };
}

pub inline fn syscall3(code: Code, arg1: u64, arg2: u64, arg3: u64) Error!ReturnValues {
    const res = if (comptime module.is_module)
        module.kernel_indirection_table.call_system(code, arg1, arg2, arg3, undefined, undefined, undefined, undefined)
    else
        syscall_fn(code, arg1, arg2, arg3, undefined, undefined, undefined, undefined);

    if (!res.syscall_result.is_success) {
        try res.syscall_result.value.err.error_code.toError();
        unreachable;
    }

    return .{
        .success0 = res.syscall_result.value.success.success0,
        .success1 = res.syscall_result.value.success.success1,
        .success2 = res.success2,
    };
}

pub inline fn syscall4(code: Code, arg1: u64, arg2: u64, arg3: u64, arg4: u64) Error!ReturnValues {
    const res = if (comptime module.is_module)
        module.kernel_indirection_table.call_system(code, arg1, arg2, arg3, arg4, undefined, undefined, undefined)
    else
        syscall_fn(code, arg1, arg2, arg3, arg4, undefined, undefined, undefined);

    if (!res.syscall_result.is_success) {
        try res.syscall_result.value.err.error_code.toError();
        unreachable;
    }

    return .{
        .success0 = res.syscall_result.value.success.success0,
        .success1 = res.syscall_result.value.success.success1,
        .success2 = res.success2,
    };
}

pub inline fn syscall5(code: Code, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64) Error!ReturnValues {
    const res = if (comptime module.is_module)
        module.kernel_indirection_table.call_system(code, arg1, arg2, arg3, arg4, arg5, undefined, undefined)
    else
        syscall_fn(code, arg1, arg2, arg3, arg4, arg5, undefined, undefined);

    if (!res.syscall_result.is_success) {
        try res.syscall_result.value.err.error_code.toError();
        unreachable;
    }

    return .{
        .success0 = res.syscall_result.value.success.success0,
        .success1 = res.syscall_result.value.success.success1,
        .success2 = res.success2,
    };
}

pub inline fn syscall6(code: Code, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) Error!ReturnValues {
    const res = if (comptime module.is_module)
        module.kernel_indirection_table.call_system(code, arg1, arg2, arg3, arg4, arg5, arg6, undefined)
    else
        syscall_fn(code, arg1, arg2, arg3, arg4, arg5, arg6, undefined);

    if (!res.syscall_result.is_success) {
        try res.syscall_result.value.err.error_code.toError();
        unreachable;
    }

    return .{
        .success0 = res.syscall_result.value.success.success0,
        .success1 = res.syscall_result.value.success.success1,
        .success2 = res.success2,
    };
}

pub inline fn syscall7(code: Code, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64, arg7: u64) Error!ReturnValues {
    const res = if (comptime module.is_module)
        module.kernel_indirection_table.call_system(code, arg1, arg2, arg3, arg4, arg5, arg6, arg7)
    else
        syscall_fn(code, arg1, arg2, arg3, arg4, arg5, arg6, arg7);

    if (!res.syscall_result.is_success) {
        try res.syscall_result.value.err.error_code.toError();
        unreachable;
    }

    return .{
        .success0 = res.syscall_result.value.success.success0,
        .success1 = res.syscall_result.value.success.success1,
        .success2 = res.success2,
    };
}
