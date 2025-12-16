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

pub const Prism = struct {
    id: u64,

    current_queue: []Invocation = &[_]Invocation{},
    current_index: usize = 0,

    pub fn create(options: Options) !Prism {
        const res = try syscall.syscall1(.prism_create, @intFromPtr(&options));
        return .{ .id = res.success2 };
    }

    pub fn destroy(self: *Prism) void {
        _ = syscall.syscall1(.prism_destroy, self.id) catch {};
    }

    /// Can be used if the current queue doesn't need to be fetched anymore, even though they may be some invocation to consume.
    /// If it returns without any error, it means that the queue has at least one invocation.
    pub fn swap(self: *Prism, suspend_behavior: syscall.SuspendBehavior) !void {
        const res = try syscall.syscall2(.prism_consume, self.id, @intFromEnum(suspend_behavior));

        self.current_index = 0;
        self.current_queue.ptr = @ptrFromInt(res.success2);
        self.current_queue.len = res.success1;
    }

    /// With suspend_behavior `.wait` this never returns `null`.
    ///
    /// @return `null` corresponds to WouldSuspend.
    pub fn consume(self: *Prism, suspend_behavior: syscall.SuspendBehavior) !?*const Invocation {
        if (self.current_queue.len == self.current_index) {
            self.swap(suspend_behavior) catch |err| switch (err) {
                syscall.Error.WouldSuspend => return null,
                else => return err,
            };
        }

        defer self.current_index += 1;

        return &self.current_queue[self.current_index];
    }

    /// sequence/time and cpuid are written by the kernel itself.
    pub const InvocationArg = extern union {
        pair64: extern struct { arg0: u64, arg1: u64 },
        one64_time64: extern struct { arg0: u64, time_ns: u64 },
        one64_time32_one32: extern struct { arg0: u64, time_ms: u32, arg1: u32 },
        one64_sequence64: extern struct { arg0: u64, sequence64: u64 },
        one64_one32_sequence32: extern struct { arg0: u64, arg1: u32, sequence32: u32 },
        one64_time32_sequence32: extern struct { arg0: u64, time_ms: u32, sequence32: u32 },
        one64_one32_one16_cpuid: extern struct { arg0: u64, arg1: u32, arg2: u16, cpuid: u16 },
        one64_sequence32_one16_cpuid: extern struct { arg0: u64, sequence32: u32, arg2: u16, cpuid: u16 },
        one64_time32_one16_cpuid: extern struct { arg0: u64, time_ms: u32, arg1: u16, cpuid: u16 },
    };

    pub const Invocation = extern struct {
        facet_id: u64,
        future: Future,
        arg: InvocationArg,

        pub fn isDropNotification(self: *const Invocation) bool {
            return self.future.isNull();
        }

        comptime {
            if (@sizeOf(Invocation) != 32) @compileError("invalid invocation size!");
        }
    };

    pub const QueueMode = enum(u8) {
        backpressure = 0,
        overwrite = 1,
    };

    pub const Options = extern struct {
        /// real_queue_size = queue_size * 128.
        ///
        /// `1` (128) is minimum. `32` (4096) is maximum.
        queue_size: u8 = 1,
        queue_mode: QueueMode = .backpressure,
        arg_formats: enum(u8) {
            pair64 = 0,
            one64_time64 = 1,
            one64_time32_one32 = 2,
            one64_sequence64 = 3,
            one64_one32_sequence32 = 4,
            one64_time32_sequence32 = 5,

            // NOTE please update isValid() or trustedModulesOnly() whenever you add a format !

            one64_one32_one16_cpuid = 253,
            one64_sequence32_one16_cpuid = 254,
            one64_time32_one16_cpuid = 255,

            _,

            pub fn isValid(self: @This()) bool {
                return @intFromEnum(self) <= 5 or self.trustedModulesOnly();
            }

            pub fn trustedModulesOnly(self: @This()) bool {
                return @intFromEnum(self) >= 253;
            }
        } = .pair64,
        /// Notify the prism consumer that a facet has been dropped.
        ///
        /// The message can be identified in the queue by a Future.null.
        notify_on_drop: bool = true,
    };
};
