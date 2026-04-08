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

use crate::mem::phys::{allocator::{MetadataSizes, Whba}, bitmap::Lcr};

pub struct BumpAllocator {
    start: usize,
    ptr: usize,
    end: usize,
}

impl BumpAllocator {
    #[inline]
    pub const unsafe fn new(start: usize, end: usize) -> Self {
        assert!(start <= end);
        Self { start, ptr: start, end }
    }

    pub fn alloc_slice<T>(&mut self, count: usize) -> &'static mut [T] {
        let align = core::mem::align_of::<T>();
        let aligned_start = (self.ptr + align - 1) & !(align - 1);
        let size = count
            .checked_mul(core::mem::size_of::<T>())
            .expect("BumpAllocator: size overflow");
        let new_ptr = aligned_start
            .checked_add(size)
            .expect("BumpAllocator: pointer overflow");

        assert!(
            new_ptr <= self.end,
            "BumpAllocator: out of space (need {} bytes, have {} remaining)",
            size,
            self.end.saturating_sub(aligned_start)
        );

        self.ptr = new_ptr;

        unsafe { core::slice::from_raw_parts_mut(aligned_start as *mut T, count) }
    }

    #[inline]
    pub const fn used(&self) -> usize {
        self.ptr - self.start
    }

    #[inline]
    pub const fn remaining(&self) -> usize {
        self.end - self.ptr
    }
}

pub struct WhbaMetadataBuffers {
    pub l0_bitmaps: &'static mut [u64],
    pub l0_lcrs: &'static mut [Lcr],
    pub l1_bitmaps: &'static mut [u64],
    pub l1_leaf_free: &'static mut [u32],
    pub l2_bitmaps: &'static mut [u64],
    pub l2_leaf_free: &'static mut [u32],
}

impl WhbaMetadataBuffers {
    pub fn into_whba(self, limit_page_index: u64) -> Whba {
        Whba::new(
            limit_page_index,
            self.l0_bitmaps,
            self.l0_lcrs,
            self.l1_bitmaps,
            self.l1_leaf_free,
            self.l2_bitmaps,
            self.l2_leaf_free,
        )
    }
}

pub fn alloc_whba_metadata(
    bump: &mut BumpAllocator,
    sizes: &MetadataSizes,
) -> WhbaMetadataBuffers {
    WhbaMetadataBuffers {
        l0_bitmaps: bump.alloc_slice::<u64>(sizes.l0_count as usize),
        l0_lcrs: bump.alloc_slice::<Lcr>(sizes.l0_count as usize),
        l1_bitmaps: bump.alloc_slice::<u64>(sizes.l1_count as usize),
        l1_leaf_free: bump.alloc_slice::<u32>(sizes.l1_count as usize),
        l2_bitmaps: bump.alloc_slice::<u64>(sizes.l2_count as usize),
        l2_leaf_free: bump.alloc_slice::<u32>(sizes.l2_count as usize),
    }
}
