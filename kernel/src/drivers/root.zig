// Copyright (c) 2024-2025 The violetOS authors
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
const build_options = @import("build_options");

// --- imports --- //

const kernel = @import("root");

pub const serial = @import("serial/root.zig");

pub const acpi = @import("acpi.zig");
pub const Timer = @import("timer.zig");

const pcie = @import("pcie/root.zig");
const virtio = @import("virtio/root.zig");

comptime {
    _ = serial;
    _ = acpi;

    _ = Timer;

    _ = pcie;
    _ = virtio;
}

// --- drivers/root.zig --- //

pub fn init() !void {
    try pcie.init();

    if (build_options.platform == .aarch64_qemu or build_options.platform == .riscv64_qemu) {
        try virtio.init();
    }
}

pub const PCIVendorDeviceMatch = struct {
    vendor: u16,
    device: u16,
};

pub const DriverEntry = struct {
    driver: *kernel.scheduler.Process,
    task_options: kernel.scheduler.Task.Options,

    pci_match: ?PCIVendorDeviceMatch,
};
