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
const basalt = @import("basalt");

// --- imports --- //

const mod = @import("mod");

// --- main.zig --- //

const entry_point = if (basalt.module.is_module) struct {
    export fn _start(umbilical: basalt.sync.Facet, kernel_indirection_table: *const basalt.module.KernelIndirectionTable) callconv(basalt.task.call_conv) noreturn {
        basalt.module.kernel_indirection_table = kernel_indirection_table;
        setup_routine(umbilical);
        main_entry();
    }
} else struct {
    export fn _start(umbilical: basalt.sync.Facet) callconv(basalt.task.call_conv) noreturn {
        setup_routine(umbilical);
        main_entry();
    }
};

fn setup_routine(umbilical: basalt.sync.Facet) void {
    _ = umbilical;
}

fn main_entry() noreturn {
    mod.main() catch {}; // TODO log the err.
    basalt.task.terminate();
}

// --- zig std features --- //

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = message;
    _ = return_address;

    // TODO print the message !

    basalt.task.terminate();
}

pub const std_options: std.Options = .{
    // .logFn = logFn,
    // .log_level = if (builtin.mode == .Debug) .debug else .info,
    .page_size_max = basalt.heap.PAGE_SIZE,
    .page_size_min = basalt.heap.PAGE_SIZE,
};

pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = basalt.heap.page_allocator;
    };
};

// ---- //

comptime {
    _ = entry_point;
}
