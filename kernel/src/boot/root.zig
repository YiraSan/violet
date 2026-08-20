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

// --- dependencies --- //

const builtin = @import("builtin");
const limine = @import("limine");

// --- imports --- //

const kernel = @import("root");

const arch = kernel.arch;
const cpu = arch.cpu;

// --- boot/main.zig --- //

export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

export var base_revision: limine.BaseRevision linksection(".limine_requests") = .init(6);
export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};
export var memmap_request: limine.MemoryMapRequest linksection(".limine_requests") = .{};
export var framebuffer_request: limine.FramebufferRequest linksection(".limine_requests") = .{};

export fn kernel_entry() noreturn {
    if (!base_revision.isSupported()) {
        cpu.halt();
    }

    if (builtin.mode == .Debug) {
        if (framebuffer_request.response) |fb_response| {
            const framebuffer = fb_response.getFramebuffers()[0];
            for (0..100) |i| {
                const fb_ptr: [*]volatile u32 = @ptrCast(@alignCast(framebuffer.address));
                fb_ptr[i * (framebuffer.pitch / 4) + i] = 0xffffff;
            }
        }
    }

    cpu.halt();
}
