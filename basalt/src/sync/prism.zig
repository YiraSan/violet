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
const syscall = basalt.syscall;

const Future = sync.Future;

// --- sync/prism.zig --- //

pub const Prism = packed struct(u64) {
    id: u64,

    pub fn create(options: Options) !Prism {
        const res = try syscall.syscall1(.prism_create, @intFromPtr(&options));
        return .{ .id = res.success2 };
    }
    }

    pub fn invoke(self: *const Prism, arg0: u64, arg1: u64, behavior: syscall.BlockingBehavior) !Future {
        var future_id: u64 = undefined;

        _ = try syscall.syscall5(
            .prism_invoke,
            @intFromEnum(behavior),
            self.id,
            @intFromPtr(&future_id),
            arg0,
            arg1,
        );

        return .{ .id = future_id };
    }

    pub const Invocation = packed struct(u256) {
        facet: u64,
        future: Future,
        arg0: u64,
        arg1: u64,
    };

    pub const QueueMode = enum(u8) {
        backpressure = 0,
        overwrite = 1,
    };

    pub const Options = extern struct {
        /// real_queue_size = queue_size * 128.
        ///
        /// `1` is minimum. `32` is maximum.
        queue_size: u8 = 1,
        queue_mode: QueueMode = .backpressure,
    };
};
