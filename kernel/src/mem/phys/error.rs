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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    OutOfMemory,
    OutOfBounds,
    UnalignedAddress,
    DoubleFree,
    DoubleAlloc,
    ContiguousTooLarge,
}

impl core::fmt::Display for Error {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::OutOfMemory => write!(f, "out of physical memory"),
            Self::OutOfBounds => write!(f, "address or range exceeds allocator limit"),
            Self::UnalignedAddress => write!(f, "address is not page-aligned"),
            Self::DoubleFree => write!(f, "attempted to free already-free pages"),
            Self::DoubleAlloc => write!(f, "attempted to allocate already-used pages"),
            Self::ContiguousTooLarge => write!(f, ">= 64 contigous pages allocation is not supported yet"),
        }
    }
}

pub type Result<T> = core::result::Result<T, Error>;
