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
const builtin = @import("builtin");

// --- imports --- //

const kernel = @import("root");

const drivers = kernel.drivers;
const acpi = drivers.acpi;

const serial = kernel.serial;

const mem = kernel.mem;

// --- drivers/serial/ns16550a.zig --- //

pub const architectures: []const std.Target.Cpu.Arch = &.{ .aarch64, .x86_64, .riscv64 };

pub fn init(xsdt: ?*const acpi.Xsdt, stage: drivers.Stage) !void {
    if (initialized) return;

    if (builtin.cpu.arch == .x86_64) {
        bus = .{ .pio = 0x3F8 };
    } else {
        const valid_xsdt = xsdt orelse return;
        const spcr = valid_xsdt.find(acpi.Spcr) orelse return;

        switch (spcr.interface_type) {
            .full_16550, .full_16450, .ns16550a_generic => {},
            else => return,
        }

        const required_stage: drivers.Stage = switch (spcr.base_address.address_space_id) {
            .system_io => blk: {
                if (builtin.cpu.arch != .x86_64) return;
                break :blk .stage0;
            },
            .system_memory => .stage2,
            else => return,
        };

        if (stage != required_stage) return;

        bus = switch (spcr.base_address.address_space_id) {
            .system_io => .{ .pio = @intCast(spcr.base_address.address) },
            .system_memory => .{ .mmio = .{ .base = unreachable, .stride = 1 } }, // TODO vmm
            else => unreachable,
        };
    }

    bus.writeReg(1, 0x00);
    bus.writeReg(3, 0x80);
    bus.writeReg(0, 0x03);
    bus.writeReg(1, 0x00);
    bus.writeReg(3, 0x03);
    bus.writeReg(2, 0xC7);
    bus.writeReg(4, 0x0B);

    initialized = true;

    serial.register(.{
        .name = "ns16550a",
        .context = @ptrCast(&bus),
        .vtable = .{ .write = write, .read = null },
    }, 10);
}

const Bus = union(enum) {
    pio: u16,
    mmio: struct { base: usize, stride: usize },

    fn readReg(self: Bus, offset: usize) u8 {
        return switch (self) {
            .pio => |base_port| inb(base_port + @as(u16, @intCast(offset))),
            .mmio => |m| @as(*volatile u8, @ptrFromInt(m.base + offset * m.stride)).*,
        };
    }

    fn writeReg(self: Bus, offset: usize, value: u8) void {
        switch (self) {
            .pio => |base_port| outb(base_port + @as(u16, @intCast(offset)), value),
            .mmio => |m| @as(*volatile u8, @ptrFromInt(m.base + offset * m.stride)).* = value,
        }
    }
};

inline fn inb(port: u16) u8 {
    if (comptime builtin.cpu.arch != .x86_64) unreachable;
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

inline fn outb(port: u16, value: u8) void {
    if (comptime builtin.cpu.arch != .x86_64) unreachable;
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

var bus: Bus = undefined;
var initialized: bool = false;

fn write(context: *anyopaque, data: []const u8) void {
    const b: *const Bus = @ptrCast(@alignCast(context));

    for (data) |byte| {
        if (byte == '\n') writeByte(b.*, '\r');
        writeByte(b.*, byte);
    }
}

fn writeByte(b: Bus, byte: u8) void {
    while (b.readReg(5) & 0x20 == 0) {
        std.atomic.spinLoopHint();
    }

    b.writeReg(0, byte);
}
