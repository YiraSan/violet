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

pub inline fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

pub inline fn pause() void {
    // TODO Zihintpause ?
    asm volatile ("fence" ::: "memory");
}

pub inline fn id() u64 {
    @compileError("use percpu instead.");
}

pub const InterruptState = enum(u1) {
    disabled = 0,
    enabled = 1,
};

pub inline fn setInterrupts(new: InterruptState) InterruptState {
    const old_sstatus = asm volatile ("csrr %[ret], sstatus"
        : [ret] "=r" (-> u64),
    );
    const was_enabled: InterruptState = if ((old_sstatus & (1 << 1)) != 0) .enabled else .disabled;

    switch (new) {
        .disabled => asm volatile ("csrci sstatus, 0x2" ::: "memory"),
        .enabled => asm volatile ("csrsi sstatus, 0x2" ::: "memory"),
    }

    return was_enabled;
}
