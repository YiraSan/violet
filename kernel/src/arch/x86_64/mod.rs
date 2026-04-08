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
    let result = core::arch::x86_64::__cpuid(1);
    (result.ebx >> 24) as u8
}

#[inline(always)]
pub unsafe fn load_cpu_ptr() -> *mut super::Cpu {
    let ptr: usize;
    unsafe { 
        asm!(
            "mov {}, gs:[0]",
            out(reg) ptr,
            options(nostack, preserves_flags, readonly),
        ); 
    }
    ptr as *mut super::Cpu
}

#[inline(always)]
pub unsafe fn store_cpu_ptr(ptr: *mut super::Cpu) {
    let val = ptr as u64;
    unsafe {
        asm!(
        "wrmsr",
            in("ecx") 0xC0000101u32,
            in("eax") val as u32,
            in("edx") (val >> 32) as u32,
            options(nomem, nostack, preserves_flags),
        );
    }
}

pub fn halt() -> ! {
    loop {
        unsafe {
            asm!("hlt");
        }
    }
}
