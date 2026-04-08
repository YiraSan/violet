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

use limine::{BaseRevision, RequestsEndMarker, RequestsStartMarker, request::{DtbRequest, HhdmRequest, MemmapRequest, PagingModeRequest, RsdpRequest}};
use spin::Once;

use crate::arch;

#[used]
#[unsafe(link_section = ".requests_start_marker")]
static _START_MARKER: RequestsStartMarker = RequestsStartMarker::new();

#[used]
#[unsafe(link_section = ".requests_end_marker")]
static _END_MARKER: RequestsEndMarker = RequestsEndMarker::new();

#[used]
#[unsafe(link_section = ".requests")]
static BASE_REVISION: BaseRevision = BaseRevision::with_revision(6);

#[used]
#[unsafe(link_section = ".requests")]
static PAGING_MODE_REQUEST: PagingModeRequest = PagingModeRequest::PREFER_MAXIMUM;

#[used]
#[unsafe(link_section = ".requests")]
static DTB_REQUEST: DtbRequest = DtbRequest::new();

#[used]
#[unsafe(link_section = ".requests")]
static RSDP_REQUEST: RsdpRequest = RsdpRequest::new();

#[used]
#[unsafe(link_section = ".requests")]
pub static MEMMAP_REQUEST: MemmapRequest = MemmapRequest::new();

#[used]
#[unsafe(link_section = ".requests")]
static HHDM_REQUEST: HhdmRequest = HhdmRequest::new();

static HHDM_OFFSET: Once<u64> = Once::INIT;

#[inline(always)]
pub fn hhdm_offset() -> u64 {
    *HHDM_OFFSET.call_once(|| {
        HHDM_REQUEST.response().unwrap().offset
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn kernel_entry() -> ! {
    assert!(BASE_REVISION.is_supported());

    crate::stage1();
    crate::stage2();

    arch::halt();
}
