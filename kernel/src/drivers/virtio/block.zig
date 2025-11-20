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

const log = std.log.scoped(.virtio_blk);

// --- imports --- //

const kernel = @import("root");

const virtio = kernel.drivers.virtio;
const pcie = kernel.drivers.pcie;

// --- virtio/block.zig --- //

// pub const BlockDevice = struct {};

pub fn init() !void {
    const process_id = try kernel.scheduler.Process.create(.{
        .execution_level = .kernel,
        .kernel_space_only = true,
    });

    try kernel.scheduler.register(
        try kernel.scheduler.Task.create(process_id, .{
            .entry_point = @intFromPtr(&listening_task),
            .priority = .realtime,
            .quantum = .ultra_heavy,
            .timer_precision = .disabled,
        }),
    );
}

fn listening_task() callconv(basalt.task.call_conv) noreturn {
    log.info("initializing ...", .{});

    // TODO somehow listen to new PCI device

    basalt.task.terminate();
}

// fn handle(context: *[0x1000]u8) !void {
//     log.info("device found at ({})", .{device});

//     const function0 = device.function(0);
//     function0.config_space.command.mse = true;
//     function0.config_space.command.bme = true;
//     // function0.config_space.command.id = true;

//     var capabilities = function0.config_space.capabilities();
//     while (capabilities.next()) |cap| {
//         if (cap.vendor_id == virtio.Capability.VENDOR_ID) {
//             const capability: *volatile virtio.Capability = @ptrCast(cap);

//             switch (capability.type) {
//                 .common => {},
//                 .notify => {},
//                 .isr => {},
//                 .device => {},
//                 .pci => {},
//             }
//         }
//     }
// }
