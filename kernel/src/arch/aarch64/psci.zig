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
const CallArgs = ark.armv8.CallArgs;

// --- imports --- //

const kernel = @import("root");
const acpi = kernel.drivers.acpi;

// --- aarch64/psci.zig --- //

const PsciFunction = enum(u32) {
    version = 0x84000000,
    cpu_off = 0x84000002,
    cpu_on = 0xC4000003,
    affinity_info = 0xC4000004,
    migrate_info_type = 0xC4000005,
    migrate = 0xC4000006,
    system_off = 0x84000008,
    system_reset = 0x84000009,
    cpu_suspend = 0xC4000001,
};

var way: enum { hvc, smc } = undefined;

pub fn init() !void {
    var xsdt_iter = kernel.boot.xsdt.iter();
    while (xsdt_iter.next()) |xsdt_entry| {
        switch (xsdt_entry) {
            .fadt => |fadt| {
                if (fadt.arm_boot_arch.psci_compliant) {
                    if (fadt.arm_boot_arch.psci_use_hvc) {
                        way = .hvc;
                    } else {
                        way = .smc;
                    }
                } else {
                    @panic("doesn't support PSCI.");
                }
            },
            else => {},
        }
    }
}

pub const ReturnCode = enum(i32) {
    success = 0,
    not_supported = -1,
    invalid_params = -2,
    denied = -3,
    already_on = -4,
    on_pending = -5,
    internal_failure = -6,
    not_present = -7,
    disabled = -8,
};

pub const Error = error{ NotSupported, InvalidParams, Denied, AlreadyOn, OnPending, InternalFailure, NotPresent, Disabled };

pub fn cpuOn(mpidr: u64, entry: u64, context_id: u64) Error!void {
    var call_args: CallArgs = .{};
    call_args.x0 = @intFromEnum(PsciFunction.cpu_on);
    call_args.x1 = mpidr;
    call_args.x2 = entry;
    call_args.x3 = context_id;

    const result: ReturnCode = @enumFromInt(@as(i32, @bitCast(@as(u32, @truncate(switch (way) {
        .hvc => call_args.hypervisorCall(),
        .smc => call_args.secureMonitorCall(),
    })))));

    switch (result) {
        .success => {},
        .already_on => return Error.AlreadyOn,
        .on_pending => return Error.OnPending,
        .denied => return Error.Denied,
        .disabled => return Error.Disabled,
        .internal_failure => return Error.InternalFailure,
        .invalid_params => return Error.InvalidParams,
        .not_present => return Error.NotPresent,
        .not_supported => return Error.NotSupported,
    }
}

const Version = packed struct(u32) {
    major: u16,
    minor: u16,
};

pub fn version() Version {
    var call_args: CallArgs = .{};
    call_args.x0 = @intFromEnum(PsciFunction.version);

    const result = switch (way) {
        .hvc => call_args.hypervisorCall(),
        .smc => call_args.secureMonitorCall(),
    };

    return @bitCast(@as(u32, @truncate(result)));
}
