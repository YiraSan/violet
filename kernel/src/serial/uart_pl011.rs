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

use core::{arch::asm, hint, ptr::{read_volatile, write_volatile}};

pub struct UartPl011 {
    peripheral_base: usize,
}

impl UartPl011 {
    pub const fn new(peripheral_base: usize) -> Self {
        Self { peripheral_base }
    }

    pub fn write(&self, c: u8) {
        if c == b'\n' {
            self.write(b'\r');
        }

        while self.read_flag().transmit_fifo_full() {
            hint::spin_loop();
        }

        unsafe {
            write_volatile(self.data_ptr(), c); 
        }

        while self.read_flag().busy() {
            hint::spin_loop();
        }
    }

    /// Data Register (Read-write)
    const UART_DR: usize = 0x000;

    #[inline(always)]
    fn data_ptr(&self) -> *mut u8 {
        (self.peripheral_base + Self::UART_DR) as *mut u8
    }

    /// Receive Status Register / Error Clear Register (Read-write)
    const UART_RSR_ECR: usize = 0x004;

    /// Flag Register (Read-only)
    const UART_FR: usize = 0x018;

    #[inline(always)]
    pub fn read_flag(&self) -> FlagRegister {
        unsafe {
            FlagRegister(read_volatile((self.peripheral_base + Self::UART_FR) as *const u16))
        }
    }

    /// IrDA Low-Power Counter Register (Read-write)
    const UART_ILPR: usize = 0x020;

    /// Integer Baud Rate Register (Read-write)
    const UART_IBRD: usize = 0x024;

    #[inline(always)]
    pub fn set_integer_baud_rate(&self, value: u16) {
        unsafe {
            write_volatile((self.peripheral_base + Self::UART_IBRD) as *mut u16, value);
        }
    }

    /// Fractional Baud Rate Register (Read-write)
    const UART_FBRD: usize = 0x028;

    #[inline(always)]
    pub fn set_fractional_baud_rate(&self, value: u8) {
        unsafe {
            write_volatile((self.peripheral_base + Self::UART_FBRD) as *mut u8, value & 0x3F);
        }
    }

    /// Line Control Register (Read-write)
    const UART_LCR_H: usize = 0x02c;

    #[inline(always)]
    fn line_control_ptr(&self) -> *mut u8 {
        (self.peripheral_base + Self::UART_LCR_H) as *mut u8
    }

    #[inline(always)]
    pub fn read_line_control(&self) -> LineControlRegister {
        unsafe {
            LineControlRegister(read_volatile(self.line_control_ptr()))
        }
    }

    #[inline(always)]
    pub fn write_line_control(&self, value: LineControlRegister) {
        unsafe {
            write_volatile(self.line_control_ptr(), value.0);
        }
    }

    /// Control Register (Read-write)
    const UART_CR: usize = 0x030;

    #[inline(always)]
    fn control_ptr(&self) -> *mut u16 {
        (self.peripheral_base + Self::UART_CR) as *mut u16
    }

    #[inline(always)]
    pub fn enable_uart(&self) {
        let mut cr = ControlRegister(unsafe { read_volatile(self.control_ptr()) });
        cr.set_uarten(true);
        unsafe { write_volatile(self.control_ptr(), cr.0) };
        self.synchronize();
    }

    #[inline(always)]
    pub fn disable_uart(&self) {
        let mut cr = ControlRegister(unsafe { read_volatile(self.control_ptr()) });
        cr.set_uarten(false);
        unsafe { write_volatile(self.control_ptr(), cr.0) };
        self.synchronize();
    }

    #[inline(always)]
    pub fn enable_transmit(&self) {
        let mut cr = ControlRegister(unsafe { read_volatile(self.control_ptr()) });
        cr.set_txe(true);
        unsafe { write_volatile(self.control_ptr(), cr.0) };
    }

    #[inline(always)]
    pub fn disable_transmit(&self) {
        let mut cr = ControlRegister(unsafe { read_volatile(self.control_ptr()) });
        cr.set_txe(false);
        unsafe { write_volatile(self.control_ptr(), cr.0) };
    }

    #[inline(always)]
    pub fn enable_receive(&self) {
        let mut cr = ControlRegister(unsafe { read_volatile(self.control_ptr()) });
        cr.set_rxe(true);
        unsafe { write_volatile(self.control_ptr(), cr.0) };
    }

    #[inline(always)]
    pub fn disable_receive(&self) {
        let mut cr = ControlRegister(unsafe { read_volatile(self.control_ptr()) });
        cr.set_rxe(false);
        unsafe { write_volatile(self.control_ptr(), cr.0) };
    }

    /// Interrupt FIFO Level Select Register (Read-write)
    const UART_IFLS: usize = 0x034;

    /// Interrupt Mask Set/Clear Register (Read-write)
    const UART_IMSC: usize = 0x038;

    #[inline(always)]
    pub fn mask_all_interrupts(&self) {
        let mut imsc = InterruptMaskSetClearRegister::new();
        imsc.set_rimim(true)
            .set_ctsmim(true)
            .set_dcdmim(true)
            .set_dsrmim(true)
            .set_rxim(true)
            .set_txim(true)
            .set_rtim(true)
            .set_feim(true)
            .set_peim(true)
            .set_beim(true)
            .set_oeim(true);

        unsafe {
            write_volatile((self.peripheral_base + Self::UART_IMSC) as *mut u16, imsc.0);
        }
    }

    #[inline(always)]
    fn synchronize(&self) {
        #[cfg(target_arch = "aarch64")]
        unsafe {
            asm!("dsb sy", "isb", options(nostack, nomem));
        }
    }
}

#[repr(transparent)]
#[derive(Clone, Copy)]
pub struct FlagRegister(u16);

impl FlagRegister {
    pub fn clear_to_send(&self) -> bool { (self.0 & (1 << 0)) != 0 }
    pub fn data_set_ready(&self) -> bool { (self.0 & (1 << 1)) != 0 }
    pub fn data_carier_detect(&self) -> bool { (self.0 & (1 << 2)) != 0 }
    pub fn busy(&self) -> bool { (self.0 & (1 << 3)) != 0 }
    pub fn receive_fifo_empty(&self) -> bool { (self.0 & (1 << 4)) != 0 }
    pub fn transmit_fifo_full(&self) -> bool { (self.0 & (1 << 5)) != 0 }
    pub fn receive_fifo_full(&self) -> bool { (self.0 & (1 << 6)) != 0 }
    pub fn transmit_fifo_empty(&self) -> bool { (self.0 & (1 << 7)) != 0 }
    pub fn ring_indicator(&self) -> bool { (self.0 & (1 << 8)) != 0 }
}

#[repr(u8)]
pub enum WordLength {
    Bits5 = 0b00,
    Bits6 = 0b01,
    Bits7 = 0b10,
    Bits8 = 0b11,
}

#[repr(transparent)]
#[derive(Clone, Copy)]
pub struct LineControlRegister(pub u8);

impl LineControlRegister {
    pub fn new() -> Self { Self(0) }

    pub fn set_brk(&mut self, val: bool) -> &mut Self { self.write_bit(0, val); self }
    pub fn set_par(&mut self, val: bool) -> &mut Self { self.write_bit(1, val); self }
    pub fn set_eps(&mut self, val: bool) -> &mut Self { self.write_bit(2, val); self }
    pub fn set_stp2(&mut self, val: bool) -> &mut Self { self.write_bit(3, val); self }
    pub fn set_fen(&mut self, val: bool) -> &mut Self { self.write_bit(4, val); self }
    pub fn set_sps(&mut self, val: bool) -> &mut Self { self.write_bit(7, val); self }

    pub fn set_wlen(&mut self, val: WordLength) -> &mut Self {
        self.0 = (self.0 & !(0b11 << 5)) | ((val as u8) << 5);
        self
    }

    #[inline(always)]
    fn write_bit(&mut self, bit: u8, val: bool) {
        if val { self.0 |= 1 << bit; } else { self.0 &= !(1 << bit); }
    }
}

#[repr(transparent)]
#[derive(Clone, Copy)]
pub struct ControlRegister(u16);

impl ControlRegister {
    pub fn set_uarten(&mut self, val: bool) { self.write_bit(0, val); }
    pub fn set_siren(&mut self, val: bool) { self.write_bit(1, val); }
    pub fn set_sirlp(&mut self, val: bool) { self.write_bit(2, val); }
    pub fn set_lbe(&mut self, val: bool) { self.write_bit(7, val); }
    pub fn set_txe(&mut self, val: bool) { self.write_bit(8, val); }
    pub fn set_rxe(&mut self, val: bool) { self.write_bit(9, val); }
    pub fn set_dtr(&mut self, val: bool) { self.write_bit(10, val); }
    pub fn set_rts(&mut self, val: bool) { self.write_bit(11, val); }
    pub fn set_out1(&mut self, val: bool) { self.write_bit(12, val); }
    pub fn set_out2(&mut self, val: bool) { self.write_bit(13, val); }
    pub fn set_rts_en(&mut self, val: bool) { self.write_bit(14, val); }
    pub fn set_cts_en(&mut self, val: bool) { self.write_bit(15, val); }

    #[inline(always)]
    fn write_bit(&mut self, bit: u8, val: bool) {
        if val { self.0 |= 1 << bit; } else { self.0 &= !(1 << bit); }
    }
}

#[repr(transparent)]
#[derive(Clone, Copy)]
pub struct InterruptMaskSetClearRegister(u16);

impl InterruptMaskSetClearRegister {
    pub fn new() -> Self { Self(0) }

    pub fn set_rimim(&mut self, val: bool) -> &mut Self { self.write_bit(0, val); self }
    pub fn set_ctsmim(&mut self, val: bool) -> &mut Self { self.write_bit(1, val); self }
    pub fn set_dcdmim(&mut self, val: bool) -> &mut Self { self.write_bit(2, val); self }
    pub fn set_dsrmim(&mut self, val: bool) -> &mut Self { self.write_bit(3, val); self }
    pub fn set_rxim(&mut self, val: bool) -> &mut Self { self.write_bit(4, val); self }
    pub fn set_txim(&mut self, val: bool) -> &mut Self { self.write_bit(5, val); self }
    pub fn set_rtim(&mut self, val: bool) -> &mut Self { self.write_bit(6, val); self }
    pub fn set_feim(&mut self, val: bool) -> &mut Self { self.write_bit(7, val); self }
    pub fn set_peim(&mut self, val: bool) -> &mut Self { self.write_bit(8, val); self }
    pub fn set_beim(&mut self, val: bool) -> &mut Self { self.write_bit(9, val); self }
    pub fn set_oeim(&mut self, val: bool) -> &mut Self { self.write_bit(10, val); self }

    #[inline(always)]
    fn write_bit(&mut self, bit: u8, val: bool) {
        if val { self.0 |= 1 << bit; } else { self.0 &= !(1 << bit); }
    }
}
