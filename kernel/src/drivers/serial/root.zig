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

const log = std.log.scoped(.serial);

// --- imports --- //

const kernel = @import("root");
const acpi = kernel.drivers.acpi;

const Pl011 = @import("uart_pl011.zig");

const mem = kernel.mem;
const vmm = mem.vmm;

// --- serial/root.zig --- //

var impl: Impl = .null;

const Impl = union(enum) {
    null,
    pl011: Pl011,
};

pub fn init() !void {
    var xsdt_iter = kernel.boot.xsdt.iter();
    while (xsdt_iter.next()) |xsdt_entry| {
        switch (xsdt_entry) {
            .spcr => |spcr| {
                if (spcr.interface_type == @intFromEnum(acpi.Dbg2SerialPortType.pl011) or
                    spcr.interface_type == @intFromEnum(acpi.Dbg2SerialPortType.arm_sbsa_generic) or
                    spcr.interface_type == @intFromEnum(acpi.Dbg2SerialPortType.bcm2835))
                {
                    const virt_address = try vmm.kernel_space.allocator.alloc(4096, 0, null, 0, null);

                    try vmm.kernel_space.paging.map(virt_address, spcr.base_address.address, 1, .l4K, .{
                        .type = .device,
                        .writable = true,
                    });

                    var pl011: Pl011 = .{ .peripheral_base = virt_address };

                    pl011.disableUart();
                    pl011.maskAllInterrupts();

                    const nbaud_rate: ?u32 = if (spcr.preciseBaudRate()) |pbr| pbr else switch (spcr.configured_baud_rate) {
                        .pre_configured => null,
                        .rate_9600 => 9600,
                        .rate_19200 => 19200,
                        .rate_57600 => 57600,
                        .rate_115200 => 115200,
                    };

                    if (nbaud_rate) |baud_rate| {
                        const clock_frequency = spcr.uartClockFrequency() orelse 48_000_000;

                        const baud_div = @as(f32, @floatFromInt(clock_frequency)) / @as(f32, @floatFromInt(16 * baud_rate));

                        const ibrd = @as(u16, @intFromFloat(@floor(baud_div)));
                        const fbrd = @as(u6, @intFromFloat(@round((baud_div - @as(f32, @floatFromInt(ibrd))) * 64)));

                        pl011.setIntegerBaudRate(ibrd);
                        pl011.setFractionalBaudRate(fbrd);
                    }

                    pl011.writeLineControl(.{
                        .brk = false,
                        .par = spcr.parity != 0,
                        .eps = false,
                        .stp2 = spcr.stop_bits > 1,
                        .fen = true,
                        .wlen = .u8,
                        .sps = false,
                    });

                    pl011.enableReceive();
                    pl011.enableTransmit();

                    pl011.enableUart();

                    impl = .{ .pl011 = pl011 };
                }

                return;
            },
            else => {},
        }
    }

    xsdt_iter = kernel.boot.xsdt.iter();
    while (xsdt_iter.next()) |xsdt_entry| {
        switch (xsdt_entry) {
            .dbg2 => |dbg2| {
                var dbg2_iter = dbg2.iter();
                while (dbg2_iter.next()) |device| {
                    if (device.port_type == .serial) {
                        if (device.port_subtype.serial == .pl011) {
                            const addrs = device.base_address_registers();
                            const sizes = device.address_sizes();
                            const size = std.mem.alignForward(u32, sizes[0], 0x1000);
                            const page_count = size >> mem.PageLevel.l4K.shift();

                            const virt_address = try vmm.kernel_space.allocator.alloc(size, 0, null, 0, null);

                            try vmm.kernel_space.paging.map(virt_address, addrs[0].address, page_count, .l4K, .{
                                .type = .device,
                                .writable = true,
                            });

                            var pl011: Pl011 = .{ .peripheral_base = virt_address };

                            pl011.disableUart();
                            pl011.maskAllInterrupts();

                            // 115200
                            pl011.setIntegerBaudRate(26);
                            pl011.setFractionalBaudRate(3);

                            pl011.writeLineControl(.{
                                .brk = false,
                                .par = false,
                                .eps = false,
                                .stp2 = false,
                                .fen = true,
                                .wlen = .u8,
                                .sps = false,
                            });

                            pl011.enableReceive();
                            pl011.enableTransmit();

                            pl011.enableUart();

                            impl = .{ .pl011 = pl011 };

                            return;
                        }
                    }
                }
            },
            else => {},
        }
    }
}

fn writeHandler(_: *anyopaque, bytes: []const u8) anyerror!usize {
    switch (impl) {
        .null => {},
        .pl011 => |pl011| {
            for (bytes) |char| {
                pl011.write(char);
            }
        },
    }

    return bytes.len;
}

const writer = std.io.Writer(
    *anyopaque,
    anyerror,
    writeHandler,
){ .context = undefined };

pub var logfn_lock: mem.RwLock = .{};

pub fn print(comptime format: []const u8, args: anytype) void {
    const lock_flags = logfn_lock.lockExclusive();
    defer logfn_lock.unlockExclusive(lock_flags);

    writer.print(format, args) catch {};
}
