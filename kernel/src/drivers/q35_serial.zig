const std = @import("std");
const build_options = @import("build_options");

inline fn ioread(comptime T: type, port: u16) T {
    return switch (T) {
        u8 => asm volatile("inb %[port], %[ret]"
            : [ret] "={al}"(-> u8),
            : [port] "N{dx}"(port),
        ),

        u16 => asm volatile("inw %[port], %[ret]"
            : [ret] "={al}"(-> u16),
            : [port] "N{dx}"(port),
        ),

        u32 => asm volatile("inl %[port], %[ret]"
            : [ret] "={eax}"(-> u32),
            : [port] "N{dx}"(port),
        ),

        else => unreachable,
    };
}

inline fn iowrite(comptime T: type, port: u16, value: T) void {
    switch (T) {
        u8 => asm volatile("outb %[value], %[port]"
            :
            : [value] "{al}"(value),
              [port] "N{dx}"(port),
        ),

        u16 => asm volatile("outw %[value], %[port]"
            :
            : [value] "{al}"(value),
              [port] "N{dx}"(port),
        ),

        u32 => asm volatile("outl %[value], %[port]"
            :
            : [value] "{eax}"(value),
              [port] "N{dx}"(port),
        ),

        else => unreachable,
    }
}

const COM1: u16 = 0x3f8;

pub fn init() !void {

    iowrite(u8, COM1 + 1, 0x00); // Disable all interrupts
    iowrite(u8, COM1 + 3, 0x80); // Enable DLAB (set baud rate divisor)
    iowrite(u8, COM1 + 0, 0x03); // Set divisor to 3 (lo byte) 38400 baud
    iowrite(u8, COM1 + 1, 0x00); //                  (hi byte)
    iowrite(u8, COM1 + 3, 0x03); // 8 bits, no parity, one stop bit
    iowrite(u8, COM1 + 2, 0xC7); // Enable FIFO, clear them, with 14-byte threshold
    iowrite(u8, COM1 + 4, 0x0B); // IRQs enabled, RTS/DSR set
    
    iowrite(u8, COM1 + 4, 0x1E); // Set in loopback mode, test the serial chip
    iowrite(u8, COM1 + 0, 0xAE); // Send a test byte

    if (ioread(u8, COM1 + 0) != 0xAE) {
        return error.SerialFault;
    }
    
    // If serial is not faulty set it in normal operation mode:
    // not-loopback with IRQs enabled and OUT#1 and OUT#2 bits enabled
    iowrite(u8, COM1 + 4, 0x0F);

}

fn write(char: u8) void {
    iowrite(u8, COM1 + 0, char);
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
    return ioread(u8, COM1 + 0);
}
