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

use limine::memmap::MEMMAP_USABLE;
use spin::{Mutex, Once};

use crate::{arch::Cpu, boot::{self, MEMMAP_REQUEST, hhdm_offset}, mem::phys::{allocator::{PAGE_SIZE, Whba}, bump::{BumpAllocator, alloc_whba_metadata}, error::Error}};

pub mod allocator;
pub mod bump;
pub mod bitmap;
pub mod error;

static GLOBAL: Once<Mutex<Whba>> = Once::INIT;

pub fn get_global() -> &'static Mutex<Whba> {
    unsafe { GLOBAL.get_unchecked() }
}

#[derive(Debug)]
pub enum InitError {
    NoMetadataRegion,
    Whba(Error),
}

impl From<Error> for InitError {
    fn from(e: Error) -> Self {
        Self::Whba(e)
    }
}

pub struct Local {
    primary: [u64; 128],
    primary_pos: usize,

    recycle: [u64; 128],
    recycle_count: usize,
}

pub enum CacheAction {
    Hit(u64),
    NeedRefill,
}

pub enum FreeAction {
    Cached,
    NeedFlush([u64; 128]),
}

impl Local {
    pub fn alloc_page(&mut self) -> CacheAction {
        if self.recycle_count > 0 {
            self.recycle_count -= 1;
            CacheAction::Hit(self.recycle[self.recycle_count])
        } else if self.primary_pos < 128 {
            let addr = self.primary[self.primary_pos];
            self.primary_pos += 1;
            CacheAction::Hit(addr)
        } else {
            CacheAction::NeedRefill
        }
    }

    pub fn free_page(&mut self, address: u64) -> FreeAction {
        if self.recycle_count < 128 {
            self.recycle[self.recycle_count] = address;
            self.recycle_count += 1;
            FreeAction::Cached
        } else if self.primary_pos == 128 {
            self.primary = self.recycle;
            self.primary_pos = 0;
            self.recycle_count = 1;
            self.recycle[0] = address;
            FreeAction::Cached
        } else {
            let to_flush = self.recycle;
            self.recycle_count = 1;
            self.recycle[0] = address;
            FreeAction::NeedFlush(to_flush)
        }
    }

    pub fn refill(&mut self, pages: [u64; 128]) {
        self.primary = pages;
        self.primary_pos = 0;
    }
}

pub fn alloc_page(reset: bool) -> Result<u64, Error> {
    let mut cpu_ref = Cpu::current_ref();
    let local = cpu_ref.phys_local();
    
    let address = match local.alloc_page() {
        CacheAction::Hit(addr) => addr,
        CacheAction::NeedRefill => {
            let mut whba = get_global().lock();
            let mut pages = [0u64; 128];
            whba.alloc_non_contiguous(&mut pages)?;
            drop(whba);
            local.refill(pages);

            let CacheAction::Hit(addr) = local.alloc_page() else {
                unreachable!("PhysCache is empty after a refill");
            };
            addr
        }
    };

    if reset {
        unsafe {
            core::ptr::write_bytes((hhdm_offset() + address) as *mut u8, 0, 0x1000);
        }
    }

    Ok(address)
}

pub fn init() -> Result<(), InitError> {
    let entries = MEMMAP_REQUEST.response().unwrap().entries();

    let mut max_physical_address: u64 = 0;

    for entry in entries {
        if entry.type_ != MEMMAP_USABLE {
            continue;
        }

        let end = entry.base + entry.length;
        if end > max_physical_address {
            max_physical_address = end;
        }
    }

    let limit_page_index = max_physical_address / PAGE_SIZE;

    let sizes = Whba::compute_metadata_sizes(limit_page_index);

    let metadata_total_bytes = (sizes.total_bytes + PAGE_SIZE).next_multiple_of(PAGE_SIZE);
    let metadata_page_count = (metadata_total_bytes / PAGE_SIZE) as usize;

    let mut metadata_phys_start: u64 = 0;
    let mut found = false;

    for entry in entries {
        if entry.type_ != MEMMAP_USABLE {
            continue;
        }

        if entry.length >= metadata_total_bytes {
            metadata_phys_start = entry.base;
            found = true;
            break;
        }
    }

    if !found {
        return Err(InitError::NoMetadataRegion);
    }

    let hhdm_offset = boot::hhdm_offset();
    let metadata_virt_start = hhdm_offset + metadata_phys_start;
    let metadata_virt_end = metadata_virt_start + metadata_total_bytes;

    let mut bump = unsafe { BumpAllocator::new(metadata_virt_start as usize, metadata_virt_end as usize) };

    let buffers = alloc_whba_metadata(&mut bump, &sizes);

    let mut whba = buffers.into_whba(limit_page_index);

    for entry in entries {
        if entry.type_ != MEMMAP_USABLE {
            continue;
        }

        whba.unmark(entry.base, (entry.length / PAGE_SIZE) as usize)?;
    }

    whba.mark(metadata_phys_start, metadata_page_count)?;

    GLOBAL.call_once(|| {
        whba.into()
    });

    Ok(())
}
