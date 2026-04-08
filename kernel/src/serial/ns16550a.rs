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

use super::IoBus;

pub struct Ns16550a {
    bus: IoBus,
}

impl Ns16550a {
    pub const fn new(bus: IoBus) -> Self {
        Self { bus }
    }

    pub fn init(&self) {
        unsafe {
            self.bus.write_u8(1, 0x00); // Interrupt Enable Register
            self.bus.write_u8(3, 0x80); // Line Control Register (Enable DLAB)
            self.bus.write_u8(0, 0x03); // Divisor Latch Low (38400 bauds)
            self.bus.write_u8(1, 0x00); // Divisor Latch High
            self.bus.write_u8(3, 0x03); // LCR (8 bits, no parity, 1 stop bit)
            self.bus.write_u8(2, 0xC7); // FIFO Control Register
            self.bus.write_u8(4, 0x0B); // Modem Control Register
        }
    }

    pub fn write(&self, char: u8) {
        if char == b'\n' { self.write(b'\r'); }

        while unsafe { self.bus.read_u8(5) & 0x20 } == 0 {
            core::hint::spin_loop();
        }
        
        unsafe { self.bus.write_u8(0, char); }
    }
}
