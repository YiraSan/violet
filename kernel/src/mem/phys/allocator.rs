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

use crate::mem::phys::bitmap::{self, Lcr};
use crate::mem::phys::error::{Error, Result};

pub const PAGE_SIZE: u64 = 0x1000; // 4 KiB
pub const PAGE_SHIFT: u32 = 12;

const L0_SHIFT: u32 = 6; // 64 pages per L0 entry
const L1_SHIFT: u32 = 12; // 64 L0 entries per L1
const L2_SHIFT: u32 = 18; // 64 L1 entries per L2

pub struct Branch {
    pub bitmaps: &'static mut [u64],
    pub leaf_free: &'static mut [u32],
}

pub struct Leaf {
    pub bitmaps: &'static mut [u64],
    pub lcrs: &'static mut [Lcr],
}

pub struct Whba {
    level2: Branch,
    level1: Branch,
    level0: Leaf,

    limit_page_index: u64,

    available_pages: u64,
}

#[derive(Debug, Clone, Copy)]
pub struct MetadataSizes {
    pub l0_count: u64,
    pub l1_count: u64,
    pub l2_count: u64,
    pub l0_bytes: u64,
    pub l1_bytes: u64,
    pub l2_bytes: u64,
    pub total_bytes: u64,
}

#[inline(always)]
const fn address_to_page(address: u64) -> Result<u64> {
    if address & (PAGE_SIZE - 1) != 0 {
        return Err(Error::UnalignedAddress);
    }

    Ok(address >> PAGE_SHIFT)
}

#[inline(always)]
const fn page_to_address(page_index: u64) -> u64 {
    page_index << PAGE_SHIFT
}

#[inline(always)]
const fn page_to_l0(page_index: u64) -> u64 {
    page_index >> L0_SHIFT
}

#[inline(always)]
const fn page_to_l1(page_index: u64) -> u64 {
    page_index >> L1_SHIFT
}

#[inline(always)]
const fn page_to_l2(page_index: u64) -> u64 {
    page_index >> L2_SHIFT
}

impl Whba {
    pub const L0_ENTRY_SIZE: u64 = (core::mem::size_of::<u64>() + core::mem::size_of::<Lcr>()) as u64;

    pub const BRANCH_ENTRY_SIZE: u64 =
        (core::mem::size_of::<u64>() + core::mem::size_of::<u32>()) as u64;

    pub fn new(
        limit_page_index: u64,
        l0_bitmaps: &'static mut [u64],
        l0_lcrs: &'static mut [Lcr],
        l1_bitmaps: &'static mut [u64],
        l1_leaf_free: &'static mut [u32],
        l2_bitmaps: &'static mut [u64],
        l2_leaf_free: &'static mut [u32],
    ) -> Self {
        let mut this = Self {
            level0: Leaf {
                bitmaps: l0_bitmaps,
                lcrs: l0_lcrs,
            },
            level1: Branch {
                bitmaps: l1_bitmaps,
                leaf_free: l1_leaf_free,
            },
            level2: Branch {
                bitmaps: l2_bitmaps,
                leaf_free: l2_leaf_free,
            },
            limit_page_index,
            available_pages: 0,
        };

        this.reset();

        this
    }

    pub const fn compute_metadata_sizes(limit_page_index: u64) -> MetadataSizes {
        let l0_count = (limit_page_index + 63) / 64;
        let l1_count = (l0_count + 63) / 64;
        let l2_count = (l1_count + 63) / 64;

        let l0_bytes = l0_count * Self::L0_ENTRY_SIZE;
        let l1_bytes = l1_count * Self::BRANCH_ENTRY_SIZE;
        let l2_bytes = l2_count * Self::BRANCH_ENTRY_SIZE;

        MetadataSizes {
            l0_count,
            l1_count,
            l2_count,
            l0_bytes,
            l1_bytes,
            l2_bytes,
            total_bytes: l0_bytes + l1_bytes + l2_bytes,
        }
    }

    pub fn reset(&mut self) {
        self.available_pages = 0;

        self.level0.bitmaps.fill(u64::MAX);
        self.level0.lcrs.fill(Lcr::EMPTY);

        self.level1.bitmaps.fill(u64::MAX);
        self.level1.leaf_free.fill(0);

        self.level2.bitmaps.fill(u64::MAX);
        self.level2.leaf_free.fill(0);
    }

    #[inline(always)]
    pub const fn available_pages(&self) -> u64 {
        self.available_pages
    }

    #[inline(always)]
    pub const fn limit_page_index(&self) -> u64 {
        self.limit_page_index
    }

    pub fn unmark(&mut self, address: u64, count: usize) -> Result<()> {
        if count == 0 {
            return Ok(());
        }

        let mut page_index = address_to_page(address)?;
        let end_index = page_index + count as u64;

        if end_index > self.limit_page_index {
            return Err(Error::OutOfBounds);
        }

        let mut l0_index = page_to_l0(page_index) as usize;
        let mut l1_index = page_to_l1(page_index) as usize;
        let mut l2_index = page_to_l2(page_index) as usize;

        let mut pending_l1_delta: u32 = 0;
        let mut pending_l1_mask: u64 = 0;

        let mut pending_l2_delta: u32 = 0;
        let mut pending_l2_mask: u64 = 0;

        while page_index < end_index {
            let start_bit = (page_index % 64) as u8;
            let page_count = core::cmp::min(64 - start_bit as u64, end_index - page_index) as u8;

            let mask = bitmap::range_mask(start_bit, page_count);

            let old_bitmap = self.level0.bitmaps[l0_index];
            
            if old_bitmap & mask != mask {
                return Err(Error::DoubleFree);
            }

            let new_bitmap = old_bitmap & !mask;
            let old_free = bitmap::free_count(old_bitmap);
            let delta = page_count as u32;

            self.available_pages += delta as u64;
            self.level0.bitmaps[l0_index] = new_bitmap;
            self.level0.lcrs[l0_index] = bitmap::calculate_lcr(new_bitmap);

            pending_l1_delta += delta;
            pending_l2_delta += delta;

            if old_free == 0 {
                let l1_bit = (l0_index % 64) as u8;
                pending_l1_mask |= 1u64 << l1_bit;
            }

            let last_l1_index = l1_index;
            let last_l2_index = l2_index;

            page_index += page_count as u64;
            l0_index = page_to_l0(page_index) as usize;
            l1_index = page_to_l1(page_index) as usize;
            l2_index = page_to_l2(page_index) as usize;

            if pending_l1_delta > 0 && (l1_index != last_l1_index || page_index >= end_index) {
                let old_l1_free = self.level1.leaf_free[last_l1_index];
                self.level1.leaf_free[last_l1_index] = old_l1_free + pending_l1_delta;

                if pending_l1_mask != 0 {
                    self.level1.bitmaps[last_l1_index] &= !pending_l1_mask;

                    if old_l1_free == 0 {
                        let l2_bit = (last_l1_index % 64) as u8;
                        pending_l2_mask |= 1u64 << l2_bit;
                    }
                }

                pending_l1_delta = 0;
                pending_l1_mask = 0;
            }

            if pending_l2_delta > 0 && (l2_index != last_l2_index || page_index >= end_index) {
                self.level2.leaf_free[last_l2_index] += pending_l2_delta;

                if pending_l2_mask != 0 {
                    self.level2.bitmaps[last_l2_index] &= !pending_l2_mask;
                }

                pending_l2_delta = 0;
                pending_l2_mask = 0;
            }
        }

        Ok(())
    }

    pub fn mark(&mut self, address: u64, count: usize) -> Result<()> {
        if count == 0 {
            return Ok(());
        }

        let mut page_index = address_to_page(address)?;
        let end_index = page_index + count as u64;

        if end_index > self.limit_page_index {
            return Err(Error::OutOfBounds);
        }

        let mut l0_index = page_to_l0(page_index) as usize;
        let mut l1_index = page_to_l1(page_index) as usize;
        let mut l2_index = page_to_l2(page_index) as usize;

        let mut pending_l1_delta: u32 = 0;
        let mut pending_l1_mask: u64 = 0;

        let mut pending_l2_delta: u32 = 0;
        let mut pending_l2_mask: u64 = 0;

        while page_index < end_index {
            let start_bit = (page_index % 64) as u8;
            let page_count = core::cmp::min(64 - start_bit as u64, end_index - page_index) as u8;

            let mask = bitmap::range_mask(start_bit, page_count);

            let old_bitmap = self.level0.bitmaps[l0_index];

            if old_bitmap & mask != 0 {
                return Err(Error::DoubleAlloc);
            }

            let new_bitmap = old_bitmap | mask;
            let new_free = bitmap::free_count(new_bitmap);
            let delta = page_count as u32;

            self.available_pages -= delta as u64;
            self.level0.bitmaps[l0_index] = new_bitmap;
            self.level0.lcrs[l0_index] = bitmap::calculate_lcr(new_bitmap);

            pending_l1_delta += delta;
            pending_l2_delta += delta;

            if new_free == 0 {
                let l1_bit = (l0_index % 64) as u8;
                pending_l1_mask |= 1u64 << l1_bit;
            }

            let last_l1_index = l1_index;
            let last_l2_index = l2_index;

            page_index += page_count as u64;
            l0_index = page_to_l0(page_index) as usize;
            l1_index = page_to_l1(page_index) as usize;
            l2_index = page_to_l2(page_index) as usize;

            if pending_l1_delta > 0 && (l1_index != last_l1_index || page_index >= end_index) {
                self.level1.leaf_free[last_l1_index] -= pending_l1_delta;

                if pending_l1_mask != 0 {
                    self.level1.bitmaps[last_l1_index] |= pending_l1_mask;
                }

                let new_l1_free = self.level1.leaf_free[last_l1_index];
                if new_l1_free == 0 {
                    let l2_bit = (last_l1_index % 64) as u8;
                    pending_l2_mask |= 1u64 << l2_bit;
                }

                pending_l1_delta = 0;
                pending_l1_mask = 0;
            }

            if pending_l2_delta > 0 && (l2_index != last_l2_index || page_index >= end_index) {
                self.level2.leaf_free[last_l2_index] -= pending_l2_delta;

                if pending_l2_mask != 0 {
                    self.level2.bitmaps[last_l2_index] |= pending_l2_mask;
                }

                pending_l2_delta = 0;
                pending_l2_mask = 0;
            }
        }

        Ok(())
    }

    pub fn alloc_contiguous(&mut self, page_count: usize) -> Result<u64> {
        if page_count == 0 {
            return Ok(0);
        }

        if self.available_pages < page_count as u64 {
            return Err(Error::OutOfMemory);
        }

        if page_count > 64 {
            return Err(Error::ContiguousTooLarge);
        }

        let l0_index = self
            .find_best_fit_l0(page_count)
            .ok_or(Error::OutOfMemory)?;

        let lcr = self.level0.lcrs[l0_index];
        let mask = bitmap::range_mask(lcr.start, page_count as u8);

        self.commit_allocation(l0_index, mask, page_count)?;

        let page_index = (l0_index as u64 * 64) + lcr.start as u64;
        Ok(page_to_address(page_index))
    }
    
    pub fn alloc_non_contiguous(&mut self, dest: &mut [u64]) -> Result<()> {
        if dest.is_empty() {
            return Ok(());
        }

        if self.available_pages < dest.len() as u64 {
            return Err(Error::OutOfMemory);
        }

        let mut allocated: usize = 0;

        while allocated < dest.len() {
            let l2_index = Self::find_most_saturated_branch(
                self.level2.leaf_free,
                0,
                self.level2.leaf_free.len(),
            )
            .ok_or(Error::OutOfMemory)?;

            let l1_start = l2_index * 64;
            let l1_count = core::cmp::min(64, self.level1.leaf_free.len() - l1_start);
            let l1_index =
                Self::find_most_saturated_branch(self.level1.leaf_free, l1_start, l1_count)
                    .ok_or(Error::OutOfMemory)?;

            let l0_start = l1_index * 64;
            let l0_index = self.find_most_saturated_leaf(l0_start).ok_or(Error::OutOfMemory)?;

            let mut bitmap = self.level0.bitmaps[l0_index];
            let mut mask_accumulator: u64 = 0;
            let mut taken: usize = 0;
            let needed = dest.len() - allocated;

            while taken < needed {
                let free_bits = !bitmap;
                if free_bits == 0 {
                    break;
                }

                let bit_idx = free_bits.trailing_zeros() as u8;
                let bit_mask = 1u64 << bit_idx;

                bitmap |= bit_mask;
                mask_accumulator |= bit_mask;

                let global_page = (l0_index as u64 * 64) + bit_idx as u64;
                dest[allocated] = global_page * PAGE_SIZE;

                allocated += 1;
                taken += 1;
            }

            if taken > 0 {
                self.commit_allocation(l0_index, mask_accumulator, taken)?;
            }
        }

        Ok(())
    }

    #[inline(always)]
    pub fn free_contiguous(&mut self, address: u64, page_count: usize) -> Result<()> {
        self.unmark(address, page_count)
    }

    #[inline(always)]
    pub fn free_non_contiguous(&mut self, addresses: &[u64]) -> Result<()> {
        for &addr in addresses {
            self.unmark(addr, 1)?;
        }
        Ok(())
    }

    fn find_best_fit_l0(&self, needed: usize) -> Option<usize> {
        if needed == 0 || needed > 64 {
            return None;
        }

        let needed_u8 = needed as u8;
        let mut best_index: usize = 0;
        let mut best_size: u8 = u8::MAX;
        let mut found = false;

        for (l2_index, &l2_free) in self.level2.leaf_free.iter().enumerate() {
            if (l2_free as usize) < needed {
                continue;
            }

            let l1_start = l2_index * 64;

            for l1_offset in 0..64 {
                let l1_index = l1_start + l1_offset;
                if l1_index >= self.level1.leaf_free.len() {
                    break;
                }

                if (self.level1.leaf_free[l1_index] as usize) < needed {
                    continue;
                }

                let l0_start = l1_index * 64;

                for l0_offset in 0..64 {
                    let l0_index = l0_start + l0_offset;
                    if l0_index >= self.level0.lcrs.len() {
                        break;
                    }

                    let lcr = self.level0.lcrs[l0_index];

                    if lcr.size < needed_u8 {
                        continue;
                    }

                    if lcr.size == needed_u8 {
                        return Some(l0_index);
                    }

                    if lcr.size < best_size {
                        best_size = lcr.size;
                        best_index = l0_index;
                        found = true;
                    }
                }
            }
        }

        if found {
            Some(best_index)
        } else {
            None
        }
    }

    fn commit_allocation(
        &mut self,
        l0_index: usize,
        mask: u64,
        count: usize,
    ) -> Result<()> {
        let old_bitmap = self.level0.bitmaps[l0_index];

        if old_bitmap & mask != 0 {
            return Err(Error::DoubleAlloc);
        }

        let new_bitmap = old_bitmap | mask;
        self.level0.bitmaps[l0_index] = new_bitmap;
        self.level0.lcrs[l0_index] = bitmap::calculate_lcr(new_bitmap);

        self.available_pages -= count as u64;

        let consumed = count as u32;
        let l1_index = l0_index >> 6;

        self.level1.leaf_free[l1_index] -= consumed;

        if new_bitmap == u64::MAX {
            let bit_in_l1 = (l0_index % 64) as u8;
            self.level1.bitmaps[l1_index] |= 1u64 << bit_in_l1;
        }

        let l2_index = l1_index >> 6;
        if l2_index < self.level2.leaf_free.len() {
            self.level2.leaf_free[l2_index] -= consumed;

            if self.level1.leaf_free[l1_index] == 0 {
                let bit_in_l2 = (l1_index % 64) as u8;
                self.level2.bitmaps[l2_index] |= 1u64 << bit_in_l2;
            }
        }

        Ok(())
    }

    fn find_most_saturated_branch(counts: &[u32], start: usize, len: usize) -> Option<usize> {
        let end = core::cmp::min(start + len, counts.len());
        let slice = &counts[start..end];

        let mut best_index: usize = 0;
        let mut min_free: u32 = u32::MAX;
        let mut found = false;

        for (i, &free) in slice.iter().enumerate() {
            if free > 0 && free < min_free {
                min_free = free;
                best_index = start + i;
                found = true;

                if min_free == 1 {
                    break;
                }
            }
        }

        if found {
            Some(best_index)
        } else {
            None
        }
    }

    fn find_most_saturated_leaf(&self, start: usize) -> Option<usize> {
        let end = core::cmp::min(start + 64, self.level0.bitmaps.len());
        let slice = &self.level0.bitmaps[start..end];

        let mut best_index: usize = 0;
        let mut min_free: u32 = u32::MAX;
        let mut found = false;

        for (i, &bm) in slice.iter().enumerate() {
            let free = bitmap::free_count(bm);

            if free > 0 && free < min_free {
                min_free = free;
                best_index = start + i;
                found = true;

                if min_free == 1 {
                    break;
                }
            }
        }

        if found {
            Some(best_index)
        } else {
            None
        }
    }
}
