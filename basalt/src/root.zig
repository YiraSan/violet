const std = @import("std");

pub const timer = struct {
    /// If conditions are met, the system will give the quantum asked by the process,
    /// if the system' charge increase the quantum will probably be reduced, the minimum being 1ms.
    pub const Quantum = enum(u8) {
        /// 1ms
        ultra_light = 0x0,
        /// 5ms
        light = 0x1,
        /// 10ms
        moderate = 0x2,
        /// 50ms
        ///
        /// Require a permission if used with reactive.
        /// It is impossible to use heavy with realtime.
        heavy = 0x3,
        /// 100ms
        ///
        /// Require a permission if not used with normal and reactive.
        /// It is impossible to use ultra_heavy with realtime.
        ultra_heavy = 0x4,

        pub fn toDelay(self: @This()) Delay {
            return switch (self) {
                .ultra_light => ._1ms,
                .light => ._5ms,
                .moderate => ._10ms,
                .heavy => ._50ms,
                .ultra_heavy => ._100ms,
            };
        }
    };

    pub const Priority = enum(u8) {
        /// Will not be scheduled in order to reduce system charge.
        background = 0x0,
        /// Guarantee a minimal amount of CPU-time under massive charge.
        normal = 0x1,
        /// Gives the priority over normal-task, while having the same aspect as normal tasks.
        reactive = 0x2,
        /// Guarantee that the task is scheduled very often even under massive charge.
        ///
        /// Whenever a realtime task becomes ready the kernel preempts the currently running task immediately if it is not also a realtime task.
        realtime = 0x3,
    };

    /// Precision = min(Precision, Quantum).
    /// Under heavy load precision is reduced but not if the task has realtime priority.
    pub const Precision = enum(u8) {
        /// 10ms
        low = 0x0,
        /// 5ms
        moderate = 0x1,
        /// 1ms
        high = 0x2,
        /// 0.5ms
        realtime = 0x3,

        pub fn toDelay(self: @This()) Delay {
            return switch (self) {
                .low => ._10ms,
                .moderate => ._5ms,
                .high => ._1ms,
                .realtime => ._0_5ms,
            };
        }
    };

    pub const Delay = enum(u8) {
        _0_5ms = 1,
        _1ms = 2,
        _5ms = 3,
        _10ms = 4,
        _50ms = 5,
        _100ms = 6,
    };
};

pub const task = struct {
    pub const TaskOptions = extern struct {
        quantum: timer.Quantum align(1) = .moderate,
        priority: timer.Priority align(1) = .normal,
        precision: timer.Precision align(1) = .moderate,
    };

    pub const ExecutionLevel = enum(u8) {
        kernel = 0x1,
        system = 0x2,
        usrapp = 0x3,
    };

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
