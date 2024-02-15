const io = @import("io.zig");

const COM1: u16 = 0x3f8;

pub fn init() !void {

    io.write(u8, COM1 + 1, 0x00); // Disable all interrupts
    io.write(u8, COM1 + 3, 0x80); // Enable DLAB (set baud rate divisor)
    io.write(u8, COM1 + 0, 0x03); // Set divisor to 3 (lo byte) 38400 baud
    io.write(u8, COM1 + 1, 0x00); //                  (hi byte)
    io.write(u8, COM1 + 3, 0x03); // 8 bits, no parity, one stop bit
    io.write(u8, COM1 + 2, 0xC7); // Enable FIFO, clear them, with 14-byte threshold
    io.write(u8, COM1 + 4, 0x0B); // IRQs enabled, RTS/DSR set
    
    io.write(u8, COM1 + 4, 0x1E); // Set in loopback mode, test the serial chip
    io.write(u8, COM1 + 0, 0xAE); // Send a test byte

    if (io.read(u8, COM1 + 0) != 0xAE) {
        return error.SerialFault;
    }
    
    // If serial is not faulty set it in normal operation mode:
    // not-loopback with IRQs enabled and OUT#1 and OUT#2 bits enabled
    io.write(u8, COM1 + 4, 0x0F);

}

pub fn write(char: u8) void {
    io.write(u8, COM1 + 0, char);
    if (char == '\n') write('\r');
}

pub fn print(text: []const u8) void {
    for (text) |char| {
        write(char);
    }
}
