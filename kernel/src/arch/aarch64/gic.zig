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
const ark = @import("ark");

// --- imports --- //

const kernel = @import("root");

const acpi = kernel.drivers.acpi;

const gic_v2 = @import("gic_v2.zig");

// --- aarch64/gic.zig --- //

var gic_version: enum { v2 } = undefined;

pub fn init() !void {
    switch (ark.armv8.registers.ID_AA64PFR0_EL1.load().gic) {
        .gic_cpu_not_implemented => {
            gic_version = .v2;

            try gic_v2.init();
            try gic_v2.initCpu();
        },
        else => @panic("unimplemented gic version"),
    }
}

pub fn initCpu() !void {
    switch (gic_version) {
        .v2 => {
            try gic_v2.initCpu();
        },
    }
}

pub fn enableIRQ(irq: u32) void {
    switch (gic_version) {
        .v2 => gic_v2.enableIRQ(irq),
    }
}

pub fn disableIRQ(irq: u32) void {
    switch (gic_version) {
        .v2 => gic_v2.disableIRQ(irq),
    }
}

pub fn acknowledge() u32 {
    return switch (gic_version) {
        .v2 => gic_v2.acknowledge(),
    };
}

pub fn endOfInterrupt(irq: u32) void {
    switch (gic_version) {
        .v2 => gic_v2.endOfInterrupt(irq),
    }
}

pub fn sendIPI(cpu_id: u32, vector: u32) void {
    switch (gic_version) {
        .v2 => gic_v2.sendIPI(cpu_id, vector),
    }
}

pub const TriggerMode = enum { level, edge };
pub const Polarity = enum { active_high, active_low };

pub fn configure(irq: u32, trigger_mode: TriggerMode, polarity: Polarity) void {
    switch (gic_version) {
        .v2 => gic_v2.configure(irq, trigger_mode, polarity),
    }
}

pub fn setPriority(irq: u32, priority: u8) void {
    switch (gic_version) {
        .v2 => gic_v2.setPriority(irq, priority),
    }
}
