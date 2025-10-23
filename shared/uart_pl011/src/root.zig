const std = @import("std");

const CR_UARTEN: u32 = 1 << 0;
const CR_TXEN: u32 = 1 << 8;
const CR_RXEN: u32 = 1 << 9;

const DR_OFFSET: usize = 0x000;
const FR_OFFSET: usize = 0x018;
const IBRD_OFFSET: usize = 0x024;
const FBRD_OFFSET: usize = 0x028;
const LCR_OFFSET: usize = 0x02c;
const CR_OFFSET: usize = 0x030;
const IMSC_OFFSET: usize = 0x038;
const INT_OFFSET: usize = 0x044;
const DMACR_OFFSET: usize = 0x048;

const FLAG_CTS: u8 = 1 << 0;
const FLAG_DSR: u8 = 1 << 1;
const FLAG_DCD: u8 = 1 << 2;
const FLAG_BUSY: u8 = 1 << 3;
const FLAG_RXFE: u8 = 1 << 4;
const FLAG_TXFF: u8 = 1 << 5;
const FLAG_RXFF: u8 = 1 << 6;
const FLAG_TXFE: u8 = 1 << 7;

fn mmio_read(comptime T: type, address: usize) T {
    const ptr = @as(*volatile T, @ptrFromInt(address));
    return @atomicLoad(T, ptr, .acquire);
}

fn mmio_write(comptime T: type, address: usize, data: T) void {
    const ptr = @as(*volatile T, @ptrFromInt(address));
    @atomicStore(T, ptr, data, .release);
}

base_address: u64,

pub fn init(self: *@This(), base_address: u64) void {
    self.base_address = base_address;

    // Désactive le UART.
    mmio_write(u32, self.base_address + CR_OFFSET, 0);

    // Masque toutes les interruptions.
    mmio_write(u32, self.base_address + INT_OFFSET, 0x7FF);

    // Configure le baud rate à 115200 bauds (UARTCLK = 48 MHz).
    mmio_write(u32, self.base_address + IBRD_OFFSET, 26); // integer baud rate divisor
    mmio_write(u32, self.base_address + FBRD_OFFSET, 3); // fractional baud rate divisor

    // Configure la ligne : 8 bits, pas de parité, 1 stop bit, FIFO activée (8N1 + FIFO)
    mmio_write(u32, self.base_address + LCR_OFFSET, (0x3 << 5) | (1 << 4)); // 0x70 : 8 bits (0x3<<5), FIFO enable (1<<4)

    // Active les interruptions nécessaires (optionnel, peut être 0 si tu ne gères pas d’interruptions)
    mmio_write(u32, self.base_address + INT_OFFSET, 0);

    // Active l’UART, TX et RX
    mmio_write(u32, self.base_address + CR_OFFSET, CR_UARTEN | CR_TXEN | CR_RXEN);
}

inline fn read_flag_register(self: *@This()) u8 {
    return mmio_read(u8, self.base_address + FR_OFFSET);
}

pub fn write(self: *@This(), char: u8) void {
    if (char == '\n') self.write('\r');
    while (self.read_flag_register() & FLAG_TXFF != 0) {}
    mmio_write(u8, self.base_address, char);
    while (self.read_flag_register() & FLAG_BUSY != 0) {}
}

pub fn read(self: *@This()) ?u8 {
    if (self.read_flag_register() & FLAG_RXFE != 0) {
        return null;
    } else {
        return mmio_read(u8, self.base_address);
    }
}
