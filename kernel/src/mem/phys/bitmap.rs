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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Lcr {
    pub start: u8,
    pub size: u8,
}

impl Lcr {
    pub const EMPTY: Self = Self { start: 0, size: 0 };
    pub const FULL: Self = Self { start: 0, size: 64 };

    #[inline(always)]
    pub const fn is_empty(self) -> bool {
        self.size == 0
    }

    #[inline(always)]
    pub const fn fits(self, needed: u8) -> bool {
        self.size >= needed
    }
}

#[inline(always)]
pub const fn range_mask(start: u8, count: u8) -> u64 {
    debug_assert!(start < 64 || (start == 0 && count == 0));
    debug_assert!(count <= 64);
    debug_assert!((start as u16 + count as u16) <= 64);
 
    if count == 0 {
        return 0;
    }
    if count == 64 {
        return u64::MAX;
    }
 
    let mask = (1u64 << count) - 1;
    mask << start
}

#[inline(always)]
pub const fn calculate_lcr(bitmap: u64) -> Lcr {
    if bitmap == u64::MAX {
        return Lcr::EMPTY;
    }

    if bitmap == 0 {
        return Lcr::FULL;
    }
 
    let mut free = !bitmap;
 
    let mut max_start: u8 = 0;
    let mut max_size: u8 = 0;
 
    let mut cur_start: u8 = 0;
    let mut cur_size: u8 = 0;
 
    let mut i: u8 = 0;
    while i < 64 {
        if (free & 1) != 0 {
            if cur_size == 0 {
                cur_start = i;
            }
            cur_size += 1;
        } else {
            if cur_size > max_size {
                max_size = cur_size;
                max_start = cur_start;
            }
            cur_size = 0;
        }
 
        free >>= 1;
        i += 1;
    }
 
    if cur_size > max_size {
        max_size = cur_size;
        max_start = cur_start;
    }
 
    Lcr {
        start: max_start,
        size: max_size,
    }
}

#[inline(always)]
pub const fn free_count(bitmap: u64) -> u32 {
    (!bitmap).count_ones()
}

#[inline(always)]
pub const fn used_count(bitmap: u64) -> u32 {
    bitmap.count_ones()
}
