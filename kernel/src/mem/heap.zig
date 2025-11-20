// Copyright (c) 2025 The violetOS authors
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

const std = @import("std");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const virt = mem.virt;

// --- mem/heap.zig --- //

pub fn init() !void {
    // TODO configure heap syscalls.
}

pub fn alloc(space: *virt.Space, level: mem.PageLevel, count: u16, flags: mem.virt.MemoryFlags, stack: bool) u64 {
    if (level != .l4K) unreachable;

    if (count == 0) return 0;

    if (stack) {
        const stack_res = space.reserve(@as(usize, @intCast(count)) + 2);
        stack_res.map(0, flags, .heap_stack);

        {
            var mapping = space.getPage(stack_res.address()) orelse unreachable;
            mapping.hint = .stack_begin_guard_page;
            _ = space.setPage(stack_res.address(), mapping);
        }

        {
            const begin_addr = stack_res.address() + 0x1000;
            var mapping = space.getPage(begin_addr) orelse unreachable;
            mapping.hint = .heap_begin_stack;
            _ = space.setPage(begin_addr, mapping);
        }

        {
            const end_page_addr = stack_res.address() + (stack_res.size << 12) - 0x1000;
            var mapping = space.getPage(end_page_addr) orelse unreachable;
            mapping.hint = .stack_end_guard_page;
            _ = space.setPage(end_page_addr, mapping);
        }

        return stack_res.address() + 0x1000;
    } else {
        const res = space.reserve(count);

        if (count > 1) {
            res.map(0, flags, .heap_inbetween);

            {
                var mapping = space.getPage(res.address()) orelse unreachable;
                mapping.hint = .heap_begin;
                _ = space.setPage(res.address(), mapping);
            }

            {
                const end_page_addr = res.address() + (res.size << 12) - 0x1000;
                var mapping = space.getPage(end_page_addr) orelse unreachable;
                mapping.hint = .heap_end;
                _ = space.setPage(end_page_addr, mapping);
            }
        } else {
            res.map(0, flags, .heap_single);
        }

        return res.address();
    }
}

/// Re-allocate virtually the memory somewhere else in the virtual space with a different size by freeing exceeding memory.
pub fn realloc(space: *virt.Space, address: u64, new_count: u16) u64 {
    if (new_count == 0) {
        free(space, address);
        return 0;
    }

    var addr = std.mem.alignBackward(u64, address, mem.PageLevel.l4K.size());
    const nmapping = space.getPage(addr);

    if (nmapping) |mapping| {
        switch (mapping.hint) {
            .heap_single => {
                const reservation = space.reserve(1);
                reservation.map(mapping.phys_addr, mapping.flags, mapping.hint);
                space.unmapPage(addr);
                virt.flush(addr, .l4K);
                return reservation.address();
            },
            .heap_begin => {
                var reservation = space.reserve(new_count);
                const res_addr = reservation.address();
                reservation.size = 1;

                var done: usize = 0;
                var nmap = nmapping;
                while (nmap) |map| {
                    if (done < new_count) {
                        reservation.map(map.phys_addr, map.flags, if (done == new_count - 1) .heap_end else if (done == 0) .heap_begin else .heap_inbetween);
                    } else {
                        if (map.phys_addr != 0) {
                            mem.phys.freePage(map.phys_addr, map.level);
                        }
                    }

                    done += 1;

                    space.unmapPage(addr);
                    virt.flush(addr, .l4K);

                    if (map.hint == .heap_end) break;

                    reservation.virt += map.level.size();
                    addr += map.level.size();
                    nmap = space.getPage(addr);
                }

                return res_addr;
            },
            .heap_begin_stack => {
                var reservation = space.reserve(new_count + 2);
                const res_addr = reservation.address() + 0x1000;
                reservation.size = 1;

                {
                    const guard_addr = addr - 0x1000;
                    const guard_map = space.getPage(guard_addr).?;
                    if (guard_map.hint != .stack_begin_guard_page) unreachable;
                    reservation.map(guard_map.phys_addr, guard_map.flags, guard_map.hint);
                    space.unmapPage(guard_addr);
                    virt.flush(guard_addr, .l4K);
                    reservation.virt += guard_map.level.size();
                }

                var done: usize = 0;
                var nmap = nmapping;
                while (nmap) |map| {
                    if (done == new_count) {
                        reservation.map(0, map.flags, .stack_end_guard_page);
                    } else if (done < new_count) {
                        reservation.map(map.phys_addr, map.flags, map.hint);
                    } else {
                        if (map.phys_addr != 0) {
                            mem.phys.freePage(map.phys_addr, map.level);
                        }
                    }

                    done += 1;

                    space.unmapPage(addr);
                    virt.flush(addr, .l4K);

                    if (map.hint == .stack_end_guard_page) break;

                    reservation.virt += map.level.size();
                    addr += map.level.size();
                    nmap = space.getPage(addr);
                }

                return res_addr;
            },
            else => {
                return 0;
            },
        }
    }

    return 0;
}

pub fn free(space: *virt.Space, address: u64) void {
    var addr = std.mem.alignBackward(u64, address, mem.PageLevel.l4K.size());
    const nmapping = space.getPage(addr);

    if (nmapping) |mapping| {
        switch (mapping.hint) {
            .heap_single => {
                if (mapping.phys_addr != 0) {
                    mem.phys.freePage(mapping.phys_addr, mapping.level);
                }
                space.unmapPage(addr);
                virt.flush(addr, .l4K);
            },
            .heap_begin => {
                var nmap = nmapping;
                while (nmap) |map| {
                    if (map.phys_addr != 0) {
                        mem.phys.freePage(map.phys_addr, map.level);
                    }
                    space.unmapPage(addr);
                    virt.flush(addr, .l4K);

                    if (map.hint == .heap_end) break;

                    addr += map.level.size();
                    nmap = space.getPage(addr);
                }
            },
            .heap_begin_stack => {
                {
                    const guard_addr = addr - 0x1000;
                    const guard_map = space.getPage(guard_addr).?;
                    if (guard_map.hint != .stack_begin_guard_page) unreachable;
                    space.unmapPage(guard_addr);
                    virt.flush(guard_addr, .l4K);
                }

                var nmap = nmapping;
                while (nmap) |map| {
                    if (map.phys_addr != 0) {
                        mem.phys.freePage(map.phys_addr, map.level);
                    }
                    space.unmapPage(addr);
                    virt.flush(addr, .l4K);

                    if (map.hint == .stack_end_guard_page) break;

                    addr += map.level.size();
                    nmap = space.getPage(addr);
                }
            },
            else => {},
        }
    }
}
