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

#![no_std]
#![no_main]

#![feature(custom_test_frameworks)]
#![test_runner(crate::test_runner)]
#![reexport_test_harness_main = "test_main"]

mod arch;
mod boot;
mod mem;
mod serial;

mod log;

use owo_colors::OwoColorize;

#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    arch::halt();
}

#[cfg(test)]
fn test_runner(_tests: &[&dyn Fn()]) {}

fn stage1() {
    mem::phys::init().unwrap();
    arch::init().unwrap();

    #[cfg(target_arch = "x86_64")]
    {
        use crate::serial::SerialPort;
        use crate::serial::IoBus;
        use crate::serial::ns16550a::Ns16550a;

        use crate::serial::SERIAL_IMPL;

        let bus = IoBus::Pio { base_port: 0x3F8 };
        let uart = Ns16550a::new(bus);
        uart.init();
        *SERIAL_IMPL.lock() = SerialPort::Ns16550a(uart);
    }
}

fn stage2() {
    clear_console!();
    println!();
    info!("current version is {}", env!("CARGO_PKG_VERSION").bold());
}
