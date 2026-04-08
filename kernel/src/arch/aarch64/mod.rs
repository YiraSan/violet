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

use core::arch::asm;

#[inline(always)]
pub fn hardware_cpu_id() -> u8 {
    let mpidr: u64;
    unsafe { asm!("mrs {}, mpidr_el1", out(reg) mpidr, options(nomem, nostack)) };
    (mpidr & 0xFF) as u8
}

#[inline(always)]
pub unsafe fn load_cpu_ptr() -> *mut super::Cpu {
    let ptr: usize;
    unsafe { asm!("mrs {}, tpidr_el1", out(reg) ptr, options(nomem, nostack, preserves_flags)); }
    ptr as *mut super::Cpu
}

#[inline(always)]
pub unsafe fn store_cpu_ptr(ptr: *mut super::Cpu) {
    unsafe { asm!("msr tpidr_el1, {}", in(reg) ptr as usize, options(nomem, nostack, preserves_flags)); }
}

pub fn halt() -> ! {
    loop {
        unsafe {
            asm!("wfi");
        }
    }
}
