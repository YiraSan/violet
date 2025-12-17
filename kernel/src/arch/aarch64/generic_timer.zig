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
const basalt = @import("basalt");
const ark = @import("ark");

// --- imports --- //

const gic = @import("gic.zig");
const exception = @import("exception.zig");

const kernel = @import("root");

const acpi = kernel.drivers.acpi;
const Timer = kernel.drivers.Timer;

// --- generic_timer.zig --- //

var gsiv: u32 = undefined;
var is_virtual: bool = undefined;

pub fn init() !void {
    var xsdt_iter = kernel.boot.xsdt.iter();
    xsdt_loop: while (xsdt_iter.next()) |xsdt_entry| {
        switch (xsdt_entry) {
            .gtdt => |gtdt| {
                if (gtdt.el1_virtual_gsiv != 0) {
                    exception.irq_callbacks[gtdt.el1_virtual_gsiv] = &callback;
                    gsiv = gtdt.el1_virtual_gsiv;
                    is_virtual = true;
                    Timer.selected_timer = .generic_timer;
                } else if (gtdt.el1_non_secure_gsiv != 0) {
                    exception.irq_callbacks[gtdt.el1_non_secure_gsiv] = &callback;
                    gsiv = gtdt.el1_non_secure_gsiv;
                    is_virtual = false;
                    Timer.selected_timer = .generic_timer;
                } else {
                    @panic("generic_timer isn't available.");
                }

                break :xsdt_loop;
            },
            else => {},
        }
    }
}

pub fn enableCpu() !void {
    gic.configure(gsiv, .level, .active_low);
    gic.setPriority(gsiv, 0x80);
    gic.enableIRQ(gsiv);
}

pub fn disableCpu() !void {
    gic.disableIRQ(gsiv);
}

fn callback() callconv(basalt.task.call_conv) void {
    disable();
    if (Timer.callback) |timer_callback| {
        timer_callback();
    }
}

pub inline fn getUptime() u64 {
    const frequency = ark.armv8.registers.loadCntfrqEl0();
    if (frequency == 0) return 0;

    const ticks = if (is_virtual)
        ark.armv8.registers.loadCntvctEl0()
    else
        ark.armv8.registers.loadCntpctEl0();

    const ticks_u128: u128 = @as(u128, ticks) * std.time.ns_per_s;
    return @intCast(ticks_u128 / frequency);
}

pub inline fn arm(nanoseconds: u64) void {
    disable();

    const frequency = ark.armv8.registers.loadCntfrqEl0();

    const total_cycles: u128 = @as(u128, @intCast(nanoseconds)) * @as(u128, @intCast(frequency));

    const interval: u128 = total_cycles / 1_000_000_000;

    if (is_virtual) {
        ark.armv8.registers.storeCntvTvalEl0(@intCast(interval));
    } else {
        ark.armv8.registers.storeCntpTvalEl0(@intCast(interval));
    }

    enable();
}

pub inline fn enable() void {
    if (is_virtual) {
        ark.armv8.registers.storeCntvCtlEl0(0b0001);
    } else {
        ark.armv8.registers.storeCntpCtlEl0(0b0001);
    }
}

pub inline fn disable() void {
    if (is_virtual) {
        ark.armv8.registers.storeCntvCtlEl0(0b0000);
    } else {
        ark.armv8.registers.storeCntpCtlEl0(0b0000);
    }
}
