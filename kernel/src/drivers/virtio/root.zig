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

//! `drivers/virtio/` directory is dedicated to VirtIO 1.0.
//! Legacy drivers won't be implemented.

// --- dependencies --- //

const std = @import("std");
const basalt = @import("basalt");

// --- imports --- //

const kernel = @import("root");
const pcie = kernel.drivers.pcie;

pub const block = @import("block.zig");

// --- VirtIO --- //

pub fn init() !void {
    try block.init();
}

pub const Capability = extern struct {
    header: pcie.Capability align(1),

    length: u8 align(1),
    type: enum(u8) {
        common = 0x1,
        notify = 0x2,
        isr = 0x3,
        device = 0x4,
        pci = 0x5,
    } align(1),

    bar: u8 align(1),
    id: u8 align(1),
    _padding: [2]u8 align(1),

    bar_offset: u32 align(1),
    bar_length: u32 align(1),

    pub const VENDOR_ID = 0x09;
};

pub const QueueDescriptor = extern struct {
    /// Guest Physical Address
    address: u64 align(1),
    length: u32 align(1),
    flags: u16 align(1),
    next: u16 align(1),
};
