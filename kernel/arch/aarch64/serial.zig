const std = @import("std");
const mmio = @import("mmio.zig");

// this is qemu virt uart base address
pub var base_address: usize = 0x09000000;

const   CR_TXEN: u32 = 1 << 8;
const CR_UARTEN: u32 = 1 << 0;

const    DR_OFFSET: usize = 0x000;
const    FR_OFFSET: usize = 0x018;
const  IBRD_OFFSET: usize = 0x024;
const  FBRD_OFFSET: usize = 0x028;
const   LCR_OFFSET: usize = 0x02c;
const    CR_OFFSET: usize = 0x030;
const  IMSC_OFFSET: usize = 0x038;
const   INT_OFFSET: usize = 0x044;
const DMACR_OFFSET: usize = 0x048;

const  FLAG_CTS: u8 = 1 << 0;
const  FLAG_DSR: u8 = 1 << 1;
const  FLAG_DCD: u8 = 1 << 2;
const FLAG_BUSY: u8 = 1 << 3;
const FLAG_RXFE: u8 = 1 << 4;
const FLAG_TXFF: u8 = 1 << 5;
const FLAG_RXFF: u8 = 1 << 6;
const FLAG_TXFE: u8 = 1 << 7;

pub fn init() !void {
    // Turn off the UART.
    mmio.write(u32, base_address + CR_OFFSET, 0);

    // Mask all interupts.
    mmio.write(u32, base_address + INT_OFFSET, 0x7ff);

    // Set maximum speed to 115200 baud.
    mmio.write(u32, base_address + IBRD_OFFSET, 0x02);
    mmio.write(u32, base_address + FBRD_OFFSET, 0x0b);

    // Enable 8N1 and FIFO.
    mmio.write(u32, base_address + LCR_OFFSET, 0x07 << 0x04);

    // Enable interrupts.
    mmio.write(u32, base_address + INT_OFFSET, 0x301);

    // Eanble UART
    mmio.write(u32, base_address + CR_OFFSET, CR_TXEN | CR_UARTEN);
}

inline fn read_flag_register() u8 {
    return mmio.read(u8, base_address + FR_OFFSET);
}

fn write(char: u8) void {
    while (read_flag_register() & FLAG_TXFF != 0) {}
    mmio.write(u8, base_address, char);
    while (read_flag_register() & FLAG_BUSY != 0) {}
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
    if (read_flag_register() & FLAG_RXFE != 0) {
        return null;
    } else {
        return mmio.read(u8, base_address);
    }
}
