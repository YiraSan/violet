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

const Prism = sync.Prism;
const Future = sync.Future;

// --- sync/facet.zig --- //

pub const Facet = packed struct(u64) {
    id: u64,

    pub const @"null" = Facet{ .id = 1 };

    pub fn isNull(self: Facet) bool {
        return self.id % 2 != 0;
    }

    pub fn create(prism: Prism, caller_id: u64) !Facet {
        const res = try syscall.syscall2(
            .facet_create,
            prism.id,
            caller_id,
        );

        return .{ .id = res.success2 };
    }

    pub fn drop(self: Facet) void {
        _ = syscall.syscall1(.facet_drop, self.id) catch {};
    }

    pub fn invoke(self: Facet, arg: Prism.InvocationArg, behavior: syscall.SuspendBehavior) !Future {
        const res = try syscall.syscall4(
            .facet_invoke,
            self.id,
            @intFromEnum(behavior),
            arg.pair64.arg0,
            arg.pair64.arg1,
        );

        return .{ .id = res.success2 };
    }
};
