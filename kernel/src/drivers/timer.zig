// Copyright (c) 2025 The violetOS authors
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

const generic_timer = @import("../arch/aarch64/generic_timer.zig");

// --- drivers/timer.zig --- //

pub var selected_timer: enum { unselected, generic_timer } = .unselected;

pub var callback: ?*const fn (ctx: *kernel.arch.ExceptionContext) callconv(basalt.task.call_conv) void = null;

pub fn arm(delay: basalt.timer.Delay) void {
    switch (selected_timer) {
        .generic_timer => generic_timer.arm(delay),
        else => unreachable,
    }
}

pub fn cancel() void {
    switch (selected_timer) {
        .generic_timer => generic_timer.disable(),
        else => unreachable,
    }
}
