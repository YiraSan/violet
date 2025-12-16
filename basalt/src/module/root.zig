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
const build_options = @import("build_options");

// --- imports --- //

const basalt = @import("basalt");

const syscall = basalt.syscall;

// --- module/root.zig --- //

pub const is_module = build_options.module_mode;

pub const PtrResult = extern struct {
    result: syscall.Result,
    value: [*]u8,
};

pub const KernelIndirectionTable = extern struct {
    call_system: *const fn (code: syscall.Code, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64, arg7: u64) callconv(basalt.task.call_conv) extern struct { syscall_result: syscall.Result, success2: u64 },
};

pub var kernel_indirection_table: *const KernelIndirectionTable = if (build_options.module_mode) undefined else unreachable;
