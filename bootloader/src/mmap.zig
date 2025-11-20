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

const uefi = std.os.uefi;

// --- mmap.zig --- //

pub const MemoryTable = struct {
    map: [*]uefi.tables.MemoryDescriptor,
    map_key: usize,
    map_size: usize,
    descriptor_size: usize,

    pub fn get(self: MemoryTable, index: usize) ?*uefi.tables.MemoryDescriptor {
        const i = self.descriptor_size * index;
        if (i > (self.map_size - self.descriptor_size)) return null;
        return @ptrFromInt(@intFromPtr(self.map) + i);
    }
};

pub fn get(boot_services: *uefi.tables.BootServices) MemoryTable {
    var map: ?[*]uefi.tables.MemoryDescriptor = null;
    var map_size: usize = 0;
    var map_key: usize = 0;

    var descriptor_size: usize = 0;
    var descriptor_version: u32 = undefined;

    var status = boot_services.getMemoryMap(
        &map_size,
        map,
        &map_key,
        &descriptor_size,
        &descriptor_version,
    );

    if (status != .buffer_too_small) {
        unreachable;
    }

    while (true) {
        map_size += descriptor_size;
        const buffer = uefi.pool_allocator.alloc(u8, map_size) catch unreachable;
        map = @alignCast(@ptrCast(buffer.ptr));

        status = boot_services.getMemoryMap(
            &map_size,
            map,
            &map_key,
            &descriptor_size,
            &descriptor_version,
        );

        if (status == .success) break;
        if (status == .buffer_too_small) {
            uefi.pool_allocator.free(buffer);
            continue;
        }

        unreachable;
    }

    return .{
        .map = @ptrCast(map.?),
        .map_key = map_key,
        .map_size = map_size,
        .descriptor_size = descriptor_size,
    };
}
