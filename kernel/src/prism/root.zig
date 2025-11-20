// Copyright (c) 2025 The violetOS authors
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

// --- imports --- //

const kernel = @import("root");
const mem = kernel.mem;
const scheduler = kernel.scheduler;
const syscall = kernel.syscall;

// --- prism/root.zig --- //

pub fn init() !void {
    syscall.register(.prism_register, &syscall_register);
}

pub fn initCpu() !void {
    // const local = Local.get();

    // future_slot_map.init(&local.futures);
}

fn syscall_register(ctx: *kernel.arch.ExceptionContext) callconv(basalt.task.call_conv) void {
    const config_addr = ctx.getArg(1);
    if (!syscall.isAddressSafe(config_addr, false)) return syscall.fail(ctx, .invalid_address);
    const config: *basalt.prism.Interface.Config = @ptrFromInt(config_addr);

    std.log.info("{}", .{config});
}

// ---- //

// var interface_manager: mem.InstanciedSlotMap(Interface) = .{};

// pub const Interface = struct {
//     owner_id: u32,
//     listener_id: ?*scheduler.Task,
// };

// const FutureSlotMap = mem.InstanciedSlotMap(Future);
// var future_slot_map: FutureSlotMap = .{};

// pub const Future = struct {
//     /// Process ID.
//     producer_id: u32,
//     /// Process ID + Task ID.
//     consumer_id: ?u64,
//     queue: mem.Queue(u64),
//     lock: mem.RwLock,
// };

pub const Local = struct {
    // futures: FutureSlotMap.Instance,

    pub fn get() *@This() {
        return &kernel.arch.Cpu.get().scheduler_local;
    }
};
