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

var gwi_process_id: Process.Id = undefined;
var genesis_process_id: Process.Id = undefined;

pub fn init() !void {
    const process = try Process.create(.{
        .execution_level = .system,
    });
    defer process.release();

    gwi_process_id = process.id;

    const task = try Task.create(gwi_process_id, .{
        .entry_point = @intFromPtr(&gwi_entry),
        .priority = .realtime,
        .quantum = .ultra_heavy,
    });

    try scheduler.register(task);
}

fn gwi_entry() callconv(basalt.task.call_conv) noreturn {
    gwi_main() catch |err| {
        log.err("main terminated with {}", .{err});
    };

    basalt.task.terminate();
}

fn gwi_main() !void {
    var process = try Process.create(.{
        .execution_level = .module,
    });

    genesis_process_id = process.id;

    try startAuxiliary();

    var gwi_prism = try basalt.sync.Prism.create(basalt.proto.Gwi.prism_options);
    defer gwi_prism.destroy();

    const gwi_facet = try basalt.sync.Facet.create(gwi_prism, @bitCast(genesis_process_id));
    defer gwi_facet.drop();

    const task = try loader.loadELF(genesis_process_id, boot.genesis_file, .{
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

        const invocation_arg: basalt.proto.Umbilical.InvocationArg = @bitCast(invocation.arg);

        switch (invocation_arg.command) {
            .get_env => {
                // ...
            },
            else => invocation.future.cancel() catch {},
        }
    }
}

fn startAuxiliary() !void {
    var wait_list: basalt.sync.WaitList = .init;

    const task = try Task.create(gwi_process_id, .{
        .entry_point = @intFromPtr(&console_entry),
        .priority = .normal,
        .quantum = .moderate,
    });

    console_future = try .create(.one_shot);
    const console_idx = try wait_list.add(console_future, null);

    try scheduler.register(task);

    // ---- //

    // TODO add a timeout

    while (try wait_list.wait(.race, .wait)) |result| {
        switch (result) {
            .resolved => |boom| {
                wait_list.remove(boom.index);

                if (boom.index == console_idx) {
                    log.info("console. OK.", .{});
                }
            },
            .insolvent => break,
            else => unreachable,
        }
    }
}

var console_facet: basalt.sync.Facet = .null;
var console_future: basalt.sync.Future = undefined;

fn console_entry() callconv(basalt.task.call_conv) noreturn {
    console_main() catch |err| {
        log.err("console terminated with {}", .{err});
    };

    basalt.task.terminate();
}

fn console_main() !void {
    var console_prism = try basalt.sync.Prism.create(basalt.proto.Console.prism_options);
    defer console_prism.destroy();

    console_facet = try basalt.sync.Facet.create(console_prism, @bitCast(genesis_process_id));
    defer console_facet.drop();

    try console_future.resolve(0);
}
