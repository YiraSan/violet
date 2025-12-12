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

// --- timer/root.zig --- //

pub const Delay = enum(u64) {
    _100us = 100 * std.time.ns_per_us,
    _500us = 500 * std.time.ns_per_us,

    _1ms = 1 * std.time.ns_per_ms,
    _5ms = 5 * std.time.ns_per_ms,
    _10ms = 10 * std.time.ns_per_ms,
    _50ms = 50 * std.time.ns_per_ms,
    _100ms = 100 * std.time.ns_per_ms,
    _500ms = 500 * std.time.ns_per_ms,

    _1s = 1 * std.time.ns_per_s,
    _5s = 5 * std.time.ns_per_s,
    _10s = 10 * std.time.ns_per_s,
    _50s = 50 * std.time.ns_per_s,

    _1min = 1 * std.time.ns_per_min,
    _5min = 5 * std.time.ns_per_min,
    _10min = 10 * std.time.ns_per_min,
    _50min = 50 * std.time.ns_per_min,

    _30hz = std.time.ns_per_s / 30,
    _60hz = std.time.ns_per_s / 60,
    _120hz = std.time.ns_per_s / 120,
    _240hz = std.time.ns_per_s / 240,

    pub inline fn nanoseconds(self: @This()) u64 {
        return @intFromEnum(self);
    }

    pub inline fn microseconds(self: @This()) u64 {
        return self.nanoseconds() / std.time.ns_per_us;
    }

    pub inline fn miliseconds(self: @This()) u64 {
        return self.microseconds() / std.time.us_per_ms;
    }

    pub inline fn seconds(self: @This()) u64 {
        return self.miliseconds() / std.time.ms_per_s;
    }

    pub inline fn minutes(self: @This()) u64 {
        return self.seconds() / std.time.s_per_min;
    }
};

pub fn sleep(delay: Delay) !void {
    const timer = try single(delay);
    defer timer.deinit();

    try timer.wait();
}

pub fn single(delay: Delay) !SingleTimer {
    var future: Future = undefined;

    _ = try syscall.syscall2(.timer_single, @intFromPtr(&future), delay.nanoseconds());

    return .{ .future = future };
}

pub fn sequential(delay: Delay) !SequentialTimer {
    var future: Future = undefined;

    _ = try syscall.syscall2(.timer_sequential, @intFromPtr(&future), delay.nanoseconds());

    return .{ .future = future };
}

pub const SingleTimer = struct {
    future: Future,

    pub fn wait(self: SingleTimer) !void {
        _ = try self.future.wait(null, .wait) orelse return error.Canceled;
    }

    pub fn deinit(self: SingleTimer) void {
        self.future.cancel() catch {};
    }
};

pub const SequentialTimer = struct {
    future: Future,
    known_sequence: u64 = 0,

    pub fn wait(self: *SequentialTimer) !u64 {
        const delta = try self.future.wait(self.known_sequence, .wait) orelse return error.Canceled;
        self.known_sequence += delta;
        return delta;
    }

    pub fn deinit(self: *SequentialTimer) void {
        self.future.cancel() catch {};
    }
};
