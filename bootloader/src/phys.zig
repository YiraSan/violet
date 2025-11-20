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

const uefi = std.os.uefi;
const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;

// --- phys.zig --- //

pub fn allocPages(count: usize) u64 {
    var physical_address: [*]align(0x1000) u8 = undefined;
    _ = uefi.system_table.boot_services.?.allocatePages(.allocate_any_pages, .loader_data, count, &physical_address);
    @memset(physical_address[0..0x1000], 0);
    return @intFromPtr(physical_address);
}

pub fn freePages(address: u64, count: usize) void {
    _ = uefi.system_table.boot_services.?.freePages(@ptrFromInt(address), count);
}
