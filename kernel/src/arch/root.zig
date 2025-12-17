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

pub const sendIPI = impl.sendIPI;
pub const extend_frame = impl.extend_frame;

pub const GeneralFrame = impl.GeneralFrame;
pub const ExtendedFrame = impl.ExtendedFrame;
pub const ExceptionData = impl.ExceptionData;

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

/// takes 256*8 = 2048 bytes so less than a page, doesn't make sense to allocate dynamically until violetOS supports multi-cluster.
pub var cpus: [256]?*Cpu = .{null} ** 256;
pub var cpu_count: usize = 0;

pub const Cpu = struct {
    cpuid: u64,
    kernel_stack_top: u64,

    phys_local: kernel.mem.phys.Local,
    scheduler_local: kernel.scheduler.Local,
    timer_local: kernel.drivers.Timer.Local,

    pub fn premptCpu(self: *@This(), force: bool) void {
        if (self.scheduler_local.is_idling.load(.acquire) or force) {
            // IPI 1 is timerCallback (which is scheduler preemption)
            sendIPI(@intCast(self.cpuid), 1);
        }
    }

    pub fn id() u8 {
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
            .aarch64 => @ptrFromInt(ark.armv8.registers.loadTpidrEl1()),
            else => unreachable,
        };
    }

    pub fn getCpu(idx: u8) ?*Cpu {
        return cpus[idx];
    }

    comptime {
        if (@sizeOf(Cpu) > 256 * 1024) @compileError("Cpu should be less than or equal to 256 KiB.");
    }
};
