const std = @import("std");
const builtin = @import("builtin");

pub const syscall = struct {
    pub const MAX_CODE: usize = @intFromEnum(Code.task__yield) + 1;

    pub const Code = enum(u64) {
        null = 0,

        process__terminate = 11,

        task__terminate = 20,
        task__yield = 21,
    };

    pub const Error = error{
        UnknownSyscall,
    };

    pub const ErrorCode = enum(u16) {
        unknown_syscall = 0,

        pub fn toError(self: @This()) Error!void {
            switch (self) {
                .unknown_syscall => return Error.UnknownSyscall,
            }
        }
    };

    pub const Result = packed struct(u64) {
        is_success: bool, // bit 0
        _reserved0: u15 = 0, // bit 1-15
        code: u16 = 0, // bit 16-31
        _reserved1: u32 = 0, // bit 32-63
    };

    pub fn syscall0(code: Code) !void {
        switch (builtin.cpu.arch) {
            .aarch64 => {
                const result = asm volatile (
                    \\ svc #0
                    : [output] "={x0}" (-> Result),
                    : [code] "{x8}" (code),
                    : "memory", "cc"
                );

                if (!result.is_success) {
                    const error_code: ErrorCode = @enumFromInt(result.code);
                    try error_code.toError();
                }
            },
            else => unreachable,
        }
    }
};

pub const timer = struct {
    /// Precision = min(Precision, Quantum).
    /// Under heavy load precision is reduced but not if the task has realtime priority.
    pub const Precision = enum(u8) {
        disabled = 0xff,

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
                else => unreachable,
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

        pub fn nanoseconds(self: @This()) usize {
            return switch (self) {
                ._0_5ms => 500,
                ._1ms => 1 * std.time.ns_per_ms,
                ._5ms => 5 * std.time.ns_per_ms,
                ._10ms => 10 * std.time.ns_per_ms,
                ._50ms => 50 * std.time.ns_per_ms,
                ._100ms => 100 * std.time.ns_per_ms,
            };
        }
    };
};

pub const task = struct {
    pub const call_conv: std.builtin.CallingConvention = switch (builtin.cpu.arch) {
        .aarch64 => .{ .aarch64_aapcs = .{} },
        .riscv64 => .{ .riscv64_lp64 = .{} },
        else => unreachable,
    };

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

        pub fn toDelay(self: @This()) timer.Delay {
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

    /// Yield current task and switch to another task.
    pub fn yield() void {
        _ = syscall.syscall0(.task__yield) catch {};
    }

    /// Terminate current task.
    pub fn terminate() noreturn {
        _ = syscall.syscall0(.task__terminate) catch {};
        unreachable;
    }

    pub const Task = struct {
        pub const SpawnConfig = struct {};

        pub fn spawn(comptime f: anytype, config: SpawnConfig) @This() {
            _ = f;
            _ = config;
            unreachable;
        }
    };
};

pub const event = struct {};

pub const process = struct {
    /// Terminate current process.
    pub fn terminate() noreturn {
        _ = syscall.syscall0(.process__terminate) catch {};
        unreachable;
    }

    pub const ExecutionLevel = enum(u8) {
        user = 0x00,
        system = 0x9f,
        kernel = 0xff,
    };

    /// If there's no receiver the signal is lost.
    pub const Event = struct {
        pub const Policy = enum { one_wake, all_wake };
    };

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
};
