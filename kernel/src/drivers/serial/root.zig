// --- dependencies --- //

const std = @import("std");

// --- imports --- //

const kernel = @import("root");
const acpi = kernel.drivers.acpi;

const Pl011 = @import("pl011.zig");

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
    xsdt_loop: while (xsdt_iter.next()) |xsdt_entry| {
        switch (xsdt_entry) {
            .dbg2 => |dbg2| {
                var dbg2_iter = dbg2.iter();
                while (dbg2_iter.next()) |device| {
                    if (device.port_type == .serial) {
                        switch (device.port_subtype.serial) {
                            .pl011 => {
                                const addrs = device.base_address_registers();
                                const sizes = device.address_sizes();

                                const page_count = std.mem.alignForward(u32, sizes[0], 0x1000);

                                const reservation = virt.kernel_space.reserve(page_count);

                                reservation.map(addrs[0].address, .{
                                    .writable = true,
                                    .device = true,
                                });

                                const addr = reservation.address();

                                virt.flush(addr);

                                var pl011: Pl011 = undefined;

                                pl011.init(addr);

                                impl = .{ .pl011 = pl011 };
                                break :xsdt_loop;
                            },
                            else => {},
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

pub const writer = std.io.Writer(
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

pub fn read() ?u8 {
    switch (impl) {
        .null => return null,
    }
}
