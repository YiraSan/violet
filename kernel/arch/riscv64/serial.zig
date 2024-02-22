const std = @import("std");
const mmio = @import("io/mmio.zig");

// this is qemu virt uart base address
pub var base_address: usize = 0x10000000;

const INTERRUPT_OFFSET: u64 = 1;
const FIFO_CONTROL_OFFSET: u64 = 2;
const LINE_CONTROL_OFFSET: u64 = 3;
const MODEM_CONTROL_OFFSET: u64 = 4;
const LINE_STATUS_OFFSET: u64 = 5;

pub fn init() !void {
    // Disable all interupts.
    mmio.write(u8, base_address + INTERRUPT_OFFSET, 0x00);

    // Enable DLAB.
    mmio.write(u8, base_address + LINE_CONTROL_OFFSET, 0x80);

    // Set maximum speed to 115200 baud by configuring DLL
    // and DLM.
    mmio.write(u8, base_address, 0x01);
    mmio.write(u8, base_address + INTERRUPT_OFFSET, 0);

    // Disable DLAB and set data word length to 8 bits.
    mmio.write(u8, base_address + LINE_CONTROL_OFFSET, 0x03);

    // Enable FIFO, clear TX/RX queues, and set a 14-byte
    // interrupt threshold.
    mmio.write(u8, base_address + FIFO_CONTROL_OFFSET, 0xc7);

    // Mark data terminal ready, signal request to send and
    // enable auxilliary output #2. (used as interrupt line
    // for the CPU)
    mmio.write(u8, base_address + MODEM_CONTROL_OFFSET, 0x0b);

    // Enable interrupts.
    mmio.write(u8, base_address + INTERRUPT_OFFSET, 0x01);
}

fn write(char: u8) void {
    mmio.write(u8, base_address, char);
    if (char == '\n') write('\r');
}

fn writeHandler(_: *anyopaque, bytes: []const u8) anyerror!usize {
    for (bytes) |char| {
        write(char);
    }
    return bytes.len;
}

pub const writer = std.io.Writer(
    *anyopaque,
    anyerror,
    writeHandler,
){ .context = undefined };

pub fn print(comptime format: []const u8, args: anytype) void {
    writer.print(format, args) catch {};
}

pub fn read() ?u8 {
    return mmio.read(u8, base_address);
}
