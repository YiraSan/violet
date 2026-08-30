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

// --- arch/x86_64/cpu.zig --- //

pub inline fn halt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub inline fn pause() void {
    asm volatile ("pause");
}

pub inline fn syncMem() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

pub inline fn syncStores() void {
    asm volatile ("sfence" ::: .{ .memory = true });
}

const IA32_KERNEL_GS_BASE = 0xC0000102;

pub inline fn getPerCpu() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (IA32_KERNEL_GS_BASE),
    );

    return (@as(u64, high) << 32) | low;
}

pub inline fn setPerCpu(val: u64) void {
    const low: u32 = @truncate(val);
    const high: u32 = @truncate(val >> 32);

    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (IA32_KERNEL_GS_BASE),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
    );
}
