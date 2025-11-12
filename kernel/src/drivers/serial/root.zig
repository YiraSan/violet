// --- dependencies --- //

const std = @import("std");

const log = std.log.scoped(.serial);

// --- imports --- //

const kernel = @import("root");
const acpi = kernel.drivers.acpi;

const Pl011 = @import("uart_pl011.zig");

const mem = kernel.mem;
const virt = mem.virt;

// --- serial/root.zig --- //

var impl: Impl = .null;

const Impl = union(enum) {
    null,
    pl011: Pl011,
};

pub fn init(xsdt: *acpi.Xsdt) !void {
    var xsdt_iter = xsdt.iter();

    while (xsdt_iter.next()) |xsdt_entry| {
        switch (xsdt_entry) {
            .spcr => |spcr| {
                if (spcr.interface_type == @intFromEnum(acpi.Dbg2SerialPortType.pl011) or
                    spcr.interface_type == @intFromEnum(acpi.Dbg2SerialPortType.arm_sbsa_generic) or
                    spcr.interface_type == @intFromEnum(acpi.Dbg2SerialPortType.bcm2835))
                {
                    const reservation = virt.kernel_space.reserve(1);

                    reservation.map(spcr.base_address.address, .{
                        .writable = true,
                        .device = true,
                    }, .no_hint);

                    const virt_address = reservation.address();

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

var logfn_lock: mem.SpinLock = .{};

pub fn print(comptime format: []const u8, args: anytype) void {
    logfn_lock.lock();
    defer logfn_lock.unlock();
    writer.print(format, args) catch {};
}
