// Copyright (c) 2024-2026 YiraSan
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

const kernel = @import("root");

// --- arch/aarch64/interrupts.zig --- //

pub const InterruptState = enum(u1) { disabled = 0, enabled = 1 };

pub inline fn set(new: InterruptState) InterruptState {
    const old_daif = asm volatile ("mrs %[ret], daif"
        : [ret] "=r" (-> u64),
    );
    const was_enabled: InterruptState = if ((old_daif & (1 << 7)) == 0) .enabled else .disabled;

    switch (new) {
        .disabled => asm volatile ("msr daifset, #0b0011" ::: .{ .memory = true }),
        .enabled => asm volatile ("msr daifclr, #0b0011" ::: .{ .memory = true }),
    }
    asm volatile ("isb" ::: .{ .memory = true });

    return was_enabled;
}

// pub const Context = packed struct {};
// pub const ExtendedContext = packed struct {};
// pub extern fn extend(ctx: *Context) *ExtendedContext;
// pub extern fn resumeSamePrivilege(ctx: *Context) noreturn;
// pub extern fn resumeSamePrivilegeExtended(ctx: *ExtendedContext) noreturn;
// pub extern fn resumeLowerPrivilege(ctx: *Context) noreturn;
// pub extern fn resumeLowerPrivilegeExtended(ctx: *ExtendedContext) noreturn;
