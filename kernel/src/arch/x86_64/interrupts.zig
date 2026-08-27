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

// --- arch/x86_64/interrupts.zig --- //

pub const InterruptState = enum(u1) { disabled = 0, enabled = 1 };

pub inline fn set(new: InterruptState) InterruptState {
    const flags = asm volatile (
        \\ pushfq
        \\ pop %[ret]
        : [ret] "=r" (-> u64),
    );
    const was_enabled: InterruptState = if ((flags & (1 << 9)) != 0) .enabled else .disabled;

    switch (new) {
        .disabled => asm volatile ("cli" ::: .{ .memory = true }),
        .enabled => asm volatile ("sti" ::: .{ .memory = true }),
    }

    return was_enabled;
}
