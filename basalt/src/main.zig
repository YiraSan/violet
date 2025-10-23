const std = @import("std");
const builtin = @import("builtin");

const mod = @import("mod");

export fn _start() callconv(switch (builtin.cpu.arch) {
    .aarch64 => .{ .aarch64_aapcs = .{} },
    .riscv64 => .{ .riscv64_lp64 = .{} },
    else => unreachable,
}) void {
    mod.main() catch {};
}

pub const task = struct {
    /// If there's no receiver the signal is lost.
    pub const Event = struct {
        pub const Policy = enum { one_wake, all_wake };
    };

    /// Yield the current task and switch to another task of the same process.
    /// Useful since yielding avoids an entire context switching.
    pub fn yield() void {} // TODO

    pub const Future = struct {
        pub const Error = error{ Timeout, GeneralFailure, TooMuchTask };

        fid: u64,

        pub const AwaitMode = enum(u8) {
            /// Wait that one task complete or fail.
            any = 0,
            /// Wait that one task complete or if every tasks have failed, producing a Error.GeneralFailure.
            any_complete = 1,
            /// Wait that every tasks complete or fail.
            all = 2,
        };

        pub inline fn wait(self: @This(), timeout_ms: u64) Error!void {
            _ = try waitMany(&[1]@This(){self}, .all, timeout_ms);
        }

        /// Returns the index of the completed/failed task for any/any_complete mode.
        /// The maximum amount of task awaitable at a time is 512, it will produces a Error.TooMuchTask.
        /// When the timeout is reached, Error.Timeout is produced.
        pub inline fn waitMany(futures: []@This(), mode: AwaitMode, timeout_ms: u64) Error!u64 {
            _ = futures;
            _ = mode;
            _ = timeout_ms;
            unreachable;
        }

        pub inline fn cancel(self: @This()) void {
            _ = self;
            unreachable;
        }
    };

    pub const Task = struct {
        pub const SpawnConfig = struct {};

        pub fn spawn(comptime f: anytype, config: SpawnConfig) @This() {
            _ = f;
            _ = config;
            unreachable;
        }
    };
};

pub const heap = struct {
    // TODO implements at least:
    // - DebugAllocator
    // - SmpAllocator
    // - ArenaAllocator
};
