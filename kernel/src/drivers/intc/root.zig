// Copyright (c) 2024-2026 YiraSan
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

const log = std.log.scoped(.ints);

// --- imports --- //

const kernel = @import("root");

const arch = kernel.arch;
const drivers = kernel.drivers;
const sched = kernel.sched;
const mem = kernel.mem;

// --- drivers/intc/root.zig --- //

pub const IrqHandler = *const fn (irq: u32) void;

pub const Controller = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        register: *const fn (ptr: *anyopaque, irq: u32, handler: IrqHandler) void,
        acknowledge: *const fn (ptr: *anyopaque) ?u32,
        dispatch: *const fn (ptr: *anyopaque, irq: u32) void,
    };

    pub inline fn register(self: Controller, irq: u32, handler: IrqHandler) void {
        self.vtable.register(self.ptr, irq, handler);
    }

    pub inline fn acknowledge(self: Controller) ?u32 {
        return self.vtable.acknowledge(self.ptr);
    }

    pub inline fn dispatch(self: Controller, irq: u32) void {
        self.vtable.dispatch(self.ptr, irq);
    }
};

pub var active_controller: ?Controller = null;

pub fn setController(controller: Controller) void {
    active_controller = controller;
}

pub fn register(irq: u32, handler: IrqHandler) void {
    const ctrl = active_controller orelse @panic("register() called before an interrupt controller was set");
    ctrl.register(irq, handler);
}
