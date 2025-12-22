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
const builtin = @import("builtin");
const build_options = @import("build_options");

// --- imports --- //

const kernel = @import("root");

const adapter =
    if (build_options.use_uefi) @import("uefi/root.zig") else switch (build_options.platform) {
        else => unreachable,
    };

comptime {
    _ = adapter;
}

// --- boot/root.zig --- //

pub var hhdm_base: u64 = 0;
pub var hhdm_limit: u64 = 0;

/// Everything has to be page-aligned.
pub const MemoryEntry = struct {
    physical_base: u64,
    number_of_pages: u64,
};

pub const UnusedMemoryIterator = adapter.UnusedMemoryIterator;

/// TODO temp structure
pub var xsdt: *kernel.drivers.acpi.Xsdt = undefined;

pub var genesis_file: []align(8) const u8 = undefined;
