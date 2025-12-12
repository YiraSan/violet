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
const basalt = @import("basalt");

const log = std.log.scoped(.pcie);

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const scheduler = kernel.scheduler;

const Process = scheduler.Process;
const Task = scheduler.Task;

const acpi = kernel.drivers.acpi;

// --- pcie/root.zig --- //

pub fn init() !void {
    const process_id = try Process.create(.{
        .execution_level = .system,
    });

    const task_id = try Task.create(process_id, .{
        .entry_point = @intFromPtr(&task_entry),
    });

    try scheduler.register(task_id);
}

fn task_entry() callconv(basalt.task.call_conv) noreturn {
    task_main() catch |err| {
        log.err("terminated with {}", .{err});
    };
    basalt.task.terminate();
}

fn task_main() !void {
    const interface = try basalt.prism.Interface.create(.{
        .description = .{
            .sub_class = @intFromEnum(basalt.prism.Interface.SystemSubClass.pcie),
            .class = .system,
            .semver_major = 0,
            .semver_minor = 1,
            .flags = .{ .priviledged = true },
        },
        .queue_size = 1, // 128
        .queue_mode = .backpressure,
    });

    // loopback !
    const future = try interface.invoke(444, 25565, .default);

    const invocations = try interface.listen(.default);

    for (invocations) |invocation| {
        try invocation.future.complete(true);
    }

    const resolve_status = try future.wait(.default);
    std.log.info("full loopback test success! {}", .{resolve_status});
}
