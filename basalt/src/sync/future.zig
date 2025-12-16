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

// --- sync/future.zig --- //

pub const WaitList = struct {
    futures: [128]Future = undefined,
    payloads: [128]u64 = undefined,
    statuses: [128]Future.Status = .{.unset} ** 128,

    pub const init = WaitList{};

    pub fn add(self: *WaitList, future: Future, payload: ?u64) !usize {
        for (0.., &self.statuses) |i, *status| {
            if (status.* == .unset) {
                self.futures[i] = future;
                self.payloads[i] = payload orelse 0;
                status.* = .pending;
                return i;
            }
        }
        return error.ListFull;
    }

    pub fn reset(self: *WaitList, index: usize) void {
        if (index < 128) {
            self.statuses[index] = .pending;
        }
    }

    pub fn remove(self: *WaitList, index: usize) void {
        if (index < 128) {
            self.statuses[index] = .unset;
        }
    }

    /// Be careful, in some cases "nothing to wait for" will return error.Insolvent (e.g. .race wait_mode)
    /// because you asked the kernel for at least 1, but provided 0 pending futures, so this is impossible.
    ///
    /// In other cases, like .barrier wait_mode (which requires "everything" to be done),
    /// "nothing to be done" is logically equivalent to "everything is done"! So the kernel will return success.
    pub fn wait(self: *WaitList, wait_mode: Future.WaitMode, behavior: syscall.SuspendBehavior) syscall.Error!?Result {
        if (Future.waitMany(&self.futures, &self.payloads, &self.statuses, wait_mode, behavior) catch |err| switch (err) {
            syscall.Error.Insolvent => return .insolvent,
            else => return err,
        }) |fail_index| {
            switch (self.statuses[fail_index]) {
                .canceled => return .{ .canceled = fail_index },
                .invalid => return .{ .invalid = fail_index },
                else => unreachable,
            }
        }

        for (0.., self.statuses) |i, status| {
            switch (status) {
                .resolved => return .{ .resolved = .{ .index = i, .payload = self.payloads[i] } },
                .canceled => return .{ .canceled = i },
                .invalid => return .{ .invalid = i },
                else => {},
            }
        }

        return null;
    }

    pub const Result = union(enum) {
        resolved: struct {
            index: usize,
            payload: u64,
        },
        canceled: usize,
        invalid: usize,
        insolvent: void,
    };
};

pub const Future = packed struct(u64) {
    id: u64,

    pub const @"null" = .{ .id = 1 };

    pub fn isNull(self: Future) bool {
        return self.id % 2 != 0;
    }

    /// This create a **local** future (that has for producer and consumer the current process).
    pub fn create(future_type: Type) basalt.syscall.Error!Future {
        const res = try syscall.syscall1(.future_create, @intFromEnum(future_type));
        return .{ .id = res.success2 };
    }

    /// Destroys the future by forcefully completing its lifecycle.
    ///
    /// This helper performs a `cancel()` followed by a no-suspend `wait()`.
    ///
    /// **Why both?**
    /// In a **local** future, the current process holds *both* the Producer
    /// and Consumer references (Refcount = 2).
    /// - `cancel()` drops the **Producer** reference.
    /// - `wait()` drops the **Consumer** reference.
    ///
    /// Calling this ensures the kernel resource is fully deallocated,
    /// regardless of the current state or role.
    pub fn destroy(self: Future) void {
        self.cancel() catch {};
        _ = self.wait(null, .no_suspend) catch {};
    }

    /// If the threshold is no more reachable, it causes an Error.Insolvent.
    ///
    /// @return `null` corresponds to success (threshold has been reached).
    ///
    /// @return `usize` correspond to the index of the future that caused the fail-fast.
    pub fn waitMany(
        futures: []Future,
        /// - input(multi_shot): known_sequence
        /// - output(multi_shot): current_sequence
        /// - output(one_shot): result_value
        payloads: []u64,
        statuses: []Status,
        mode: WaitMode,
        behavior: syscall.SuspendBehavior,
    ) basalt.syscall.Error!?usize {
        if (futures.len == 0) return null;
        if (futures.len != payloads.len) return basalt.syscall.Error.InvalidArgument;
        if (futures.len != statuses.len) return basalt.syscall.Error.InvalidArgument;

        const vals = try syscall.syscall6(
            .future_await,
            @intFromPtr(futures.ptr),
            @intFromPtr(payloads.ptr),
            @intFromPtr(statuses.ptr),
            futures.len,
            @bitCast(mode),
            @intFromEnum(behavior),
        );

        if (vals.success0 == std.math.maxInt(u16)) return null;

        return @intCast(vals.success0);
    }

    /// If the future is canceled/invalid it returns null.
    pub fn wait(self: Future, known_sequence: ?u64, behavior: syscall.SuspendBehavior) basalt.syscall.Error!?u64 {
        var futures = [_]Future{self};
        var payloads = [_]u64{known_sequence orelse 0};
        var statuses = [_]Status{.pending};

        if (try waitMany(&futures, &payloads, &statuses, .race, behavior) == null) {
            if (statuses[0] == .resolved) {
                return payloads[0];
            }
        }

        return null;
    }

    /// Signal to the consumer that the future has been resolved.
    ///
    /// (one-shot) `payload` is the result value of the future.
    ///
    /// (multi-shot) `payload` is the sequence increment (0 is ignored by the kernel).
    pub fn resolve(self: Future, payload: u64) basalt.syscall.Error!void {
        _ = try syscall.syscall3(.future_resolve, self.id, @intFromEnum(Status.resolved), payload);
    }

    /// Cancel the future.
    ///
    /// This signals the intent to abort the pending operation.
    ///
    /// Use `destroy()` instead of `cancel()` for local future if you are the consumer.
    pub fn cancel(self: Future) basalt.syscall.Error!void {
        _ = try syscall.syscall2(.future_resolve, self.id, @intFromEnum(Status.canceled));
    }

    pub const WaitMode = packed struct(u64) {
        /// Wait that one future resolve or cancel.
        pub const race: WaitMode = .{ .resolve_threshold = 1, .fail_fast = true };

        /// Wait that one future resolve or until every futures was canceled.
        pub const any_resolve: WaitMode = .{ .resolve_threshold = 1, .fail_fast = false };

        /// Wait that every futures resolve or cancel.
        pub const barrier: WaitMode = .{ .resolve_threshold = 0, .fail_fast = false };

        /// Wait that every futures resolve, or that one cancel.
        pub const transaction: WaitMode = .{ .resolve_threshold = 0, .fail_fast = true };

        /// Represents the number of resolved futures required to return.
        ///
        /// `0` represents FUTURES_LEN.
        resolve_threshold: u8,

        /// If any future is canceled, return.
        fail_fast: bool,

        _reserved: u55 = 0,
    };

    pub const Type = enum(u8) {
        one_shot = 0,
        multi_shot = 1,
    };

    pub const Status = enum(u8) {
        pending = 0,
        resolved = 1,
        canceled = 2,
        /// Used by the kernel to represent an invalid future.
        /// In the scenario that another task is already awaiting for that future, the kernel will consider that future as invalid from your point of view.
        invalid = 3,
        /// Any value other than pending, resolved, canceled or invalid has no meaning for the kernel and is ignored.
        unset = 4,
        _,
    };
};
