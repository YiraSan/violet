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

pub mod ns16550a;
pub mod uart_pl011;

use core::fmt::Write;
use spin::Mutex;
use uart_pl011::UartPl011;
use ns16550a::Ns16550a;

pub static SERIAL_IMPL: Mutex<SerialPort> = Mutex::new(SerialPort::None);

pub enum SerialPort {
    None,
    UartPl011(UartPl011),
    Ns16550a(Ns16550a),
}

impl SerialPort {
    fn write(&self, c: u8) {
        match self {
            SerialPort::None => {},
            SerialPort::UartPl011(pl011) => pl011.write(c),
            SerialPort::Ns16550a(ns16550a) => ns16550a.write(c),
        }
    }
}

impl core::fmt::Write for SerialPort {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        for byte in s.bytes() {
            self.write(byte);
        } 
        Ok(())
    }
}

#[doc(hidden)]
pub fn _print(args: core::fmt::Arguments) {
    let mut port = SERIAL_IMPL.lock();
    let _ = port.write_fmt(args);
}

#[macro_export]
macro_rules! print {
    ($($arg:tt)*) => ($crate::serial::_print(format_args!($($arg)*)));
}

#[macro_export]
macro_rules! println {
    () => ($crate::print!("\n"));
    ($($arg:tt)*) => ($crate::print!("{}\n", format_args!($($arg)*)));
}

#[derive(Clone, Copy)]
pub enum IoBus {
    #[cfg(target_arch = "x86_64")]
    Pio { base_port: u16 },

    Mmio { base_addr: usize, stride: usize },
}

impl IoBus {
    #[inline(always)]
    pub unsafe fn read_u8(&self, offset: usize) -> u8 {
        match self {
            #[cfg(target_arch = "x86_64")]
            IoBus::Pio { base_port } => unsafe {
                let mut val: u8;
                core::arch::asm!("in al, dx", out("al") val, in("dx") base_port + offset as u16, options(nomem, nostack, preserves_flags));
                val
            }
            IoBus::Mmio { base_addr, stride } => unsafe {
                core::ptr::read_volatile((*base_addr + (offset * stride)) as *const u8)
            }
        }
    }

    #[inline(always)]
    pub unsafe fn write_u8(&self, offset: usize, val: u8) {
        match self {
            #[cfg(target_arch = "x86_64")]
            IoBus::Pio { base_port } => unsafe {
                core::arch::asm!("out dx, al", in("dx") base_port + offset as u16, in("al") val, options(nomem, nostack, preserves_flags));
            }
            IoBus::Mmio { base_addr, stride } => unsafe {
                core::ptr::write_volatile((*base_addr + (offset * stride)) as *mut u8, val)
            }
        }
    }
}
