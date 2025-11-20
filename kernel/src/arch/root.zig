// Copyright (c) 2024-2025 The violetOS Authors
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
const ark = @import("ark");

// --- imports --- //

const kernel = @import("root");

const acpi = kernel.drivers.acpi;

const impl = switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64/root.zig"),
    else => unreachable,
};

pub const TaskContext = impl.TaskContext;
pub const ExceptionContext = impl.ExceptionContext;

comptime {
    _ = impl;
}

// -- arch/root.zig -- //

pub fn init() !void {
    try impl.init();
}

pub fn initCpus() !void {
    try impl.initCpus();
}

pub fn bootCpus() !void {
    try impl.bootCpus();
}

pub fn maskInterrupts() void {
    impl.maskInterrupts();
}

pub fn unmaskInterrupts() void {
    impl.unmaskInterrupts();
}

pub fn maskAndSave() u64 {
    return impl.maskAndSave();
}

pub fn restoreSaved(saved: u64) void {
    impl.restoreSaved(saved);
}

// --- //

pub const Cpu = struct {
    cpuid: u64,

    // -- physical memory -- //
    primary_4k_cache: [128]u64,
    primary_4k_cache_pos: usize,
    recycle_4k_cache: [128]u64,
    recycle_4k_cache_num: usize,

    // -- virtual memory -- //
    user_space: *kernel.mem.virt.Space,

    scheduler_local: kernel.scheduler.Local,
    prism_local: kernel.prism.Local,

    pub fn id() usize {
        switch (builtin.cpu.arch) {
            .aarch64 => {
                const mpidr = ark.armv8.registers.MPIDR_EL1.load();
                // NOTE the primary core should not even start a core from another cluster.
                if (mpidr.aff1 != 0 or mpidr.aff2 != 0 or mpidr.aff3 != 0) unreachable;
                return mpidr.aff0;
            },
            else => unreachable,
        }
    }

    pub fn get() *Cpu {
        return switch (builtin.cpu.arch) {
            .aarch64 => @ptrFromInt(ark.armv8.registers.loadTpidrEL1()),
            else => unreachable,
        };
    }

    comptime {
        if (@sizeOf(Cpu) > kernel.mem.PageLevel.l2M.size()) @compileError("Cpu should be less than or equal to 2 MiB.");
    }
};
