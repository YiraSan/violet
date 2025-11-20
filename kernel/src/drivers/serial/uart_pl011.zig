// Copyright (c) 2025 The violetOS authors
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

const builtin = @import("builtin");

// --- uart_pl011.zig --- //

peripheral_base: u64,

pub fn write(self: *const @This(), char: u8) void {
    if (char == '\n') self.write('\r');

    while (self.readFlag().transmit_fifo_full) {}
    self.dataPtr().* = char;
    while (self.readFlag().busy) {}
}

// --- registers --- //

/// Data Register (Read-write)
const UART_DR = 0x000;

inline fn dataPtr(self: *const @This()) *volatile u8 {
    const dr: *volatile u8 = @ptrFromInt(self.peripheral_base + UART_DR);

    return dr;
}

/// Receive Status Register / Error Clear Register (Read-write)
const UART_RSR_ECR = 0x004;

/// Flag Register (Read-only)
const UART_FR = 0x018;

const FlagRegister = packed struct(u16) {
    clear_to_send: bool,
    data_set_ready: bool,
    data_carier_detect: bool,
    busy: bool,
    receive_fifo_empty: bool,
    transmit_fifo_full: bool,
    receive_fifo_full: bool,
    transmit_fifo_empty: bool,
    ring_indicator: bool,
    _reserved: u7,
};

inline fn readFlag(self: *const @This()) FlagRegister {
    const fr: *volatile FlagRegister = @ptrFromInt(self.peripheral_base + UART_FR);

    return fr.*;
}

/// IrDA Low-Power Counter Register (Read-write)
const UART_ILPR = 0x020;

/// Integer Baud Rate Register (Read-write)
const UART_IBRD = 0x024;

pub inline fn setIntegerBaudRate(self: *const @This(), value: u16) void {
    const ibrd: *volatile u16 = @ptrFromInt(self.peripheral_base + UART_IBRD);

    ibrd.* = value;
}

/// Fractional Baud Rate Register (Read-write)
const UART_FBRD = 0x028;

pub inline fn setFractionalBaudRate(self: *const @This(), value: u6) void {
    const fbrd: *volatile u8 = @ptrFromInt(self.peripheral_base + UART_FBRD);

    fbrd.* = value;
}

/// Line Control Register (Read-write)
const UART_LCR_H = 0x02c;

const LineControlRegister = packed struct(u8) {
    /// Send break.
    brk: bool, // bit 0
    /// Parity enable.
    par: bool, // bit 1
    /// Even parity select.
    eps: bool, // bit 2
    /// Two stop bits select.
    stp2: bool, // bit 3
    /// Enable FIFOs
    fen: bool, // bit 4
    /// Word length.
    wlen: enum(u2) { // bit 5-6
        u8 = 0b11,
        u7 = 0b10,
        u6 = 0b01,
        u5 = 0b00,
    },
    /// Stick parity select.
    sps: bool, // bit 7
};

inline fn lineControlPtr(self: *const @This()) *volatile LineControlRegister {
    return @ptrFromInt(self.peripheral_base + UART_LCR_H);
}

pub inline fn readLineControl(self: *const @This()) LineControlRegister {
    const lcr = self.lineControlPtr();

    return lcr.*;
}

pub inline fn writeLineControl(self: *const @This(), value: LineControlRegister) void {
    const lcr = self.lineControlPtr();

    lcr.* = value;
}

/// Control Register (Read-write)
const UART_CR = 0x030;

const ControlRegister = packed struct(u16) {
    /// Uart enable.
    uarten: bool, // bit 0
    /// SIR enable.
    siren: bool, // bit 1
    /// SIR low-power IrDA mode.
    sirlp: bool, // bit 2
    /// Do not modify.
    _reserved0: u4, // bit 3-6
    /// Loop Back enable.
    lbe: bool, // bit 7
    /// Transmit enable.
    txe: bool, // bit 8
    /// Receive enable.
    rxe: bool, // bit 9
    /// Data transmit ready.
    dtr: bool, // bit 10
    /// Request to send.
    rts: bool, // bit 11
    out1: u1, // bit 12
    out2: u1, // bit 13
    /// RTS hardware flow control enable.
    rts_en: bool, // bit 14
    /// CTS hardware flow control enable.
    cts_en: bool, // bit 15
};

inline fn controlPtr(self: *const @This()) *volatile ControlRegister {
    return @ptrFromInt(self.peripheral_base + UART_CR);
}

pub inline fn enableUart(self: *const @This()) void {
    const cr = self.controlPtr();
    cr.uarten = true;

    synchronize();
}

pub inline fn disableUart(self: *const @This()) void {
    const cr = self.controlPtr();
    cr.uarten = false;

    synchronize();
}

pub inline fn enableTransmit(self: *const @This()) void {
    const cr = self.controlPtr();
    cr.txe = true;
}

pub inline fn disableTransmit(self: *const @This()) void {
    const cr = self.controlPtr();
    cr.txe = false;
}

pub inline fn enableReceive(self: *const @This()) void {
    const cr = self.controlPtr();
    cr.rxe = true;
}

pub inline fn disableReceive(self: *const @This()) void {
    const cr = self.controlPtr();
    cr.rxe = false;
}

/// Interrupt FIFO Level Select Register (Read-write)
const UART_IFLS = 0x034;

/// Interrupt Mask Set/Clear Register (Read-write)
const UART_IMSC = 0x038;

const InterruptMaskSetClearRegister = packed struct(u16) {
    /// nUARTRI modem interrupt mask.
    rimim: bool, // bit 0
    /// nUARTCTS modem interrupt mask.
    ctsmim: bool, // bit 1
    /// nUARTDCD modem interrupt mask.
    dcdmim: bool, // bit 2
    /// nUARTDSR modem interrupt mask.
    dsrmim: bool, // bit 3
    /// Receive interrupt mask.
    rxim: bool, // bit 4
    /// Transmit interrupt mask.
    txim: bool, // bit 5
    /// Receive timeout interrupt mask.
    rtim: bool, // bit 6
    /// Framing error interrupt mask.
    feim: bool, // bit 7
    /// Parity error interrupt mask.
    peim: bool, // bit 8
    /// Break error interrupt mask.
    beim: bool, // bit 9
    /// Overrun error interrupt mask.
    oeim: bool, // bit 10
    /// Do not modify.
    _reserved: u5, // bit 11-15
};

inline fn interruptMaskPtr(self: *const @This()) *volatile InterruptMaskSetClearRegister {
    return @ptrFromInt(self.peripheral_base + UART_IMSC);
}

pub inline fn maskAllInterrupts(self: *const @This()) void {
    const imsc = self.interruptMaskPtr();
    imsc.* = .{
        .rimim = true,
        .ctsmim = true,
        .dcdmim = true,
        .dsrmim = true,
        .rxim = true,
        .txim = true,
        .rtim = true,
        .feim = true,
        .peim = true,
        .beim = true,
        .oeim = true,
        ._reserved = imsc._reserved,
    };
}

/// Raw Interrupt Status Register (Read-only)
const UART_RIS = 0x03c;

/// Masked Interrupt Status Register (Read-only)
const UART_MIS = 0x040;

/// Interrupt Clear Register (Write-only)
const UART_ICR = 0x044;

/// DMA Control Register (Read-write)
const UART_DMACR = 0x048;

// ... //

inline fn synchronize() void {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            asm volatile ("dsb sy");
            asm volatile ("isb");
        },
        else => {},
    }
}
