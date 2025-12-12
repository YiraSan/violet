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

// --- imports --- //

const basalt = @import("basalt");

const syscall = basalt.syscall;

// --- process/root.zig --- //

/// Terminate current process.
pub fn terminate() noreturn {
    _ = syscall.syscall0(.process_terminate) catch {};
    unreachable;
}

pub const ExecutionLevel = enum(u8) {
    user = 0x00,
    module = 0xe0,
    /// Same as `module`. Used by genesis or internal kernel task. Grants certain privilege.
    system = 0xf0,
};
