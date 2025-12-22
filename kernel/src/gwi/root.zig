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

const basalt = @import("basalt");
const std = @import("std");

const log = std.log.scoped(.gwi);

// --- imports --- //

const kernel = @import("root");

const boot = kernel.boot;
const loader = kernel.loader;
const scheduler = kernel.scheduler;

const Process = scheduler.Process;
const Task = scheduler.Task;

// --- gwi/root.zig --- //

pub fn init() !void {
    const process = try Process.create(.{
        .execution_level = .system,
    });
    defer process.release();

    const task = try Task.create(process.id, .{
        .entry_point = @intFromPtr(&gwi_entry),
        .priority = .realtime,
        .quantum = .ultra_heavy,
    });

    try scheduler.register(task);
}

fn gwi_entry() callconv(basalt.task.call_conv) noreturn {
    gwi_main() catch |err| {
        log.err("terminated with {}", .{err});
    };

    basalt.task.terminate();
}

fn gwi_main() !void {
    var process = try Process.create(.{
        .execution_level = .module,
    });

    var gwi_prism = try basalt.sync.Prism.create(basalt.proto.Gwi.prism_options);
    defer gwi_prism.destroy();

    const gwi_facet = try basalt.sync.Facet.create(gwi_prism, @bitCast(process.id));
    defer gwi_facet.drop();

    const task = try loader.loadELF(process.id, boot.genesis_file, .{
        .entry_point = 0, // provided by the loader
        .priority = .reactive,
        .quantum = .heavy,
        .facet = gwi_facet,
    });

    process.release();

    try scheduler.register(task);

    while (try gwi_prism.consume(.wait)) |invocation| {
        if (invocation.isDropNotification()) {
            log.err("genesis has crashed.", .{});
            break;
        }

        log.info("received: {}", .{invocation.arg.pair64});
    }
}
