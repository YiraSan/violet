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

// --- arch/riscv64/registers.zig --- //

inline fn csrRead(comptime name: []const u8) u64 {
    return asm volatile ("csrr %[ret], " ++ name
        : [ret] "=r" (-> u64),
    );
}

inline fn csrWrite(comptime name: []const u8, value: u64) void {
    asm volatile ("csrw " ++ name ++ ", %[val]"
        :
        : [val] "r" (value),
        : .{ .memory = true });
}

pub const Satp = packed struct(u64) {
    pub const Mode = enum(u4) {
        bare = 0,
        sv39 = 8,
        sv48 = 9,
        sv57 = 10,
    };

    ppn: u44 = 0,
    asid: u16 = 0,
    mode: Mode = .bare,

    pub inline fn load() Satp {
        return @bitCast(csrRead("satp"));
    }

    pub inline fn store(self: Satp) void {
        csrWrite("satp", @bitCast(self));
    }
};
