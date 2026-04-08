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

#[cfg(target_arch = "aarch64")]
#[path = "aarch64/mod.rs"]
mod _impl;

#[cfg(target_arch = "riscv64")]
#[path = "riscv64/mod.rs"]
mod _impl;

#[cfg(target_arch = "x86_64")]
#[path = "x86_64/mod.rs"]
mod _impl;

pub use _impl::*;

// -- Cpu -- //

use core::{marker::PhantomData, sync::atomic::{AtomicPtr, AtomicUsize, Ordering}};

use crate::{boot::hhdm_offset, mem::phys::{self, Local as PhysLocal, error::Error}};

static CPUS: [AtomicPtr<Cpu>; 256] = {
    const NULL: AtomicPtr<Cpu> = AtomicPtr::new(core::ptr::null_mut());
    [NULL; 256]
};

static CPU_COUNT: AtomicUsize = AtomicUsize::new(0);

#[repr(C, align(128))]
pub struct Cpu {
    #[cfg(target_arch = "x86_64")]
    self_ptr: *mut Cpu,

    pub cpuid: u8,

    pub phys_local: PhysLocal,
}

const _: () = assert!(
    size_of::<Cpu>() <= 256 * 1024,
    "Cpu shouldn't be greater than 256 KiB !"
);

impl Cpu {
    #[inline(always)]
    pub fn id() -> u8 {
        Self::current_ref().cpuid
    }

    #[inline(always)]
    pub fn current_ref() -> CpuRef {
        let ptr = unsafe { load_cpu_ptr() };
        debug_assert!(!ptr.is_null(), "Cpu::current_ref called before init");
        CpuRef { ptr, _no_send: PhantomData }
    }

    pub fn init_current(cpu: *mut Cpu) {
        let hw_id = hardware_cpu_id();
        unsafe { (*cpu).cpuid = hw_id; }

        #[cfg(target_arch = "x86_64")]
        {
            unsafe { (*cpu).self_ptr = cpu; }
        }

        unsafe { store_cpu_ptr(cpu); }

        CPUS[hw_id as usize].store(cpu, Ordering::Release);
        CPU_COUNT.fetch_add(1, Ordering::Release);
    }

    pub fn get(index: u8) -> Option<&'static Cpu> {
        let ptr = CPUS[index as usize].load(Ordering::Acquire);
        if ptr.is_null() { None } else { unsafe { Some(&*ptr) } }
    }

    #[inline(always)]
    pub fn hardware_id() -> u8 {
        hardware_cpu_id()
    }
}

pub struct CpuRef {
    ptr: *mut Cpu,
    _no_send: PhantomData<*mut ()>,
}

impl core::ops::Deref for CpuRef {
    type Target = Cpu;
    #[inline(always)]
    fn deref(&self) -> &Cpu {
        unsafe { &*self.ptr }
    }
}

impl CpuRef {
    #[inline(always)]
    pub fn phys_local(&mut self) -> &mut PhysLocal {
        unsafe { &mut (*self.ptr).phys_local }
    }
}

pub fn init() -> Result<(), Error> {
    let page_count = (size_of::<Cpu>()).next_multiple_of(0x1000) / 0x1000;

    let mut global = phys::get_global().lock();
    let cpu_ptr = (hhdm_offset() + global.alloc_contiguous(page_count)?) as *mut Cpu;
    drop(global);

    Cpu::init_current(cpu_ptr);

    Ok(())
}
