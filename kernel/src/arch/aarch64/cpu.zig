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
    asm volatile ("yield");
}

pub inline fn id() u64 {
    const mpidr = asm volatile ("mrs %[ret], mpidr_el1"
        : [ret] "=r" (-> u64),
    );

    return mpidr & 0xff;
}

pub const InterruptState = enum(u1) {
    disabled = 0,
    enabled = 1,
};

pub inline fn setInterrupts(new: InterruptState) InterruptState {
    const old_daif = asm volatile ("mrs %[ret], daif"
        : [ret] "=r" (-> u64),
    );
    const was_enabled: InterruptState = if ((old_daif & (1 << 7)) == 0) .enabled else .disabled;

    switch (new) {
        .disabled => asm volatile ("msr daifset, #0b0011" ::: "memory"),
        .enabled => asm volatile ("msr daifclr, #0b0011" ::: "memory"),
    }
    asm volatile ("isb" ::: "memory");

    return was_enabled;
}
