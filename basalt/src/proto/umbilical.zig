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

// --- imports --- //

const basalt = @import("basalt");

const sync = basalt.sync;

const Facet = sync.Facet;
const Future = sync.Future;
const Prism = sync.Prism;

// --- proto/umbilical.zig --- //

pub const prism_options = Prism.Options{
    .arg_formats = .pair64,
    .notify_on_drop = .defer_on_overflow,
    .queue_mode = .backpressure,
    .queue_size = 1,
};

pub const InvocationArg = extern struct {
    command: enum(u16) { // 2 bytes
        get_env = 0,
        _,
    },

    payload: extern union { // 14 bytes
        get_env: extern struct {
            device: Device,
            version: Version,
            _reserved0: [8]u8 = .{0} ** 8,
        },

        // ...
    },

    comptime {
        if (@sizeOf(InvocationArg) != @sizeOf(Prism.InvocationArg)) @compileError("umbilical.InvocationArg has incorrect size.");
    }
};

const Umbilical = @This();

facet: Facet,

pub const Device = enum(u16) {
    console = 0xb707,
    _,
};

pub const Version = extern struct {
    major: u16,
    minor: u16,
};

pub fn getEnv(self: *const Umbilical, device: Device, version: Version) !Future {
    return self.facet.invoke(
        @bitCast(InvocationArg{
            .command = .get_env,
            .payload = .{ .get_env = .{
                .device = device,
                .version = version,
            } },
        }),
        .default,
    );
}
