// Copyright (c) 2024-2025 The violetOS authors
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
const builtin = @import("builtin");

// --- imports --- //

const kernel = @import("root");

const boot = kernel.boot;
const mem = kernel.mem;

const heap = mem.heap;
const phys = mem.phys;

const impl = switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64/vmm.zig"),
    else => unreachable,
};

// --- mem/vmm.zig --- //

pub var kernel_space: Space = undefined;

pub fn init() !void {
    try impl.init();
}

pub const Allocator = struct {
    pub const Error = error{
        OutOfVirtualMemory,
        NotPageAligned,
        OutOfRange,
        AddressAlreadyInUse,
        InvalidAddress,
    };

    const Region = struct {
        pub const Map = heap.SlotMap(Region);
        pub const Id = Map.Key;

        start: u64,
        size: u64,

        object: ?*Object,
        offset: u64,

        next_sorted: ?Id,
    };

    const PAGE_SIZE = mem.PageLevel.l4K.size();

    pub const LOWER_BASE: u64 = 0x0000_0000_0001_0000; // 64 KiB
    pub const LOWER_LIMIT: u64 = 0x0000_FFFF_FFFF_FFFF;
    // HIGHER_BASE == HHDM_LIMIT
    pub const HIGHER_LIMIT: u64 = 0xFFFF_FFFF_FFFF_FFFF;

    base: u64,
    limit: u64,

    regions: Region.Map,
    head: ?Region.Id,

    lock: mem.RwLock,

    pub fn init(base: u64, limit: u64) @This() {
        return .{
            .base = base,
            .limit = limit,
            .regions = .init(),
            .head = null,
            .lock = .{},
        };
    }

    pub fn deinit(self: *@This()) void {
        var curr = self.head;
        while (curr) |id| {
            if (self.regions.get(id)) |reg| {
                if (reg.object) |object| object.release();
                curr = reg.next_sorted;
            } else {
                break;
            }
        }

        self.regions.deinit();
    }

    // lock_shared !!!!
    pub fn findRegion(self: *@This(), addr: u64) ?*Region {
        var curr = self.head;
        while (curr) |id| {
            const region = self.regions.get(id).?;
            if (addr >= region.start and addr < region.start + region.size) {
                return region;
            }
            if (region.start > addr) break;
            curr = region.next_sorted;
        }
        return null;
    }

    pub fn alloc(self: *@This(), size: u64, align_size: u64, object: ?*Object, offset: u64) !u64 {
        if (size == 0) return 0;

        const lock_flags = self.lock.lockExclusive();
        defer self.lock.unlockExclusive(lock_flags);

        const actual_align = @max(align_size, PAGE_SIZE);
        const actual_size = std.mem.alignForward(u64, size, PAGE_SIZE);

        var current_candidate = std.mem.alignForward(u64, self.base, actual_align);

        var prev_id: ?Region.Id = null;
        var curr_id = self.head;

        while (curr_id) |id| {
            const region = self.regions.get(id).?;

            if (current_candidate + actual_size <= region.start) {
                break;
            }

            const next_possible = region.start + region.size;
            current_candidate = std.mem.alignForward(u64, next_possible, actual_align);

            prev_id = id;
            curr_id = region.next_sorted;
        }

        const end_addr, const overflowed = @addWithOverflow(current_candidate, actual_size);
        if (overflowed == 1 or end_addr > self.limit) return Error.OutOfVirtualMemory;

        const new_region = Region{
            .start = current_candidate,
            .size = actual_size,
            .next_sorted = curr_id,
            .object = object,
            .offset = offset,
        };

        const new_id = try self.regions.insert(new_region);

        if (prev_id) |p_id| {
            self.regions.get(p_id).?.next_sorted = new_id;
        } else {
            self.head = new_id;
        }

        return current_candidate;
    }

    pub fn allocAt(self: *@This(), address: u64, size: u64, object: ?*Object, offset: u64) !void {
        const lock_flags = self.lock.lockExclusive();
        defer self.lock.unlockExclusive(lock_flags);

        if (!std.mem.isAligned(address, PAGE_SIZE)) {
            return Error.NotPageAligned;
        }

        const actual_size = std.mem.alignForward(u64, size, PAGE_SIZE);

        const req_end, const overflowed = @addWithOverflow(address, actual_size);
        if (overflowed or req_end > self.limit) return Error.OutOfRange;
        if (address < self.base) return Error.OutOfRange;
        if (size == 0) return;

        var prev_id: ?Region.Id = null;
        var curr_id = self.head;

        while (curr_id) |id| {
            const region = self.regions.get(id).?;

            const region_end = region.start + region.size;

            if (address < region_end and req_end > region.start) {
                return Error.AddressAlreadyInUse;
            }

            if (region.start >= req_end) {
                break;
            }

            prev_id = id;
            curr_id = region.next_sorted;
        }

        const new_region = Region{
            .start = address,
            .size = actual_size,
            .next_sorted = curr_id,
            .object = object,
            .offset = offset,
        };

        const new_id = try self.regions.insert(new_region);

        if (prev_id) |p_id| {
            self.regions.get(p_id).?.next_sorted = new_id;
        } else {
            self.head = new_id;
        }
    }

    pub fn free(self: *@This(), address: u64) !struct { object: ?*Object, size: u64 } {
        const lock_flags = self.lock.lockExclusive();
        defer self.lock.unlockExclusive(lock_flags);

        var prev_id: ?Region.Id = null;
        var curr_id = self.head;

        while (curr_id) |id| {
            const region = self.regions.get(id).?;

            if (region.start == address) {
                if (prev_id) |p_id| {
                    self.regions.get(p_id).?.next_sorted = region.next_sorted;
                } else {
                    self.head = region.next_sorted;
                }

                self.regions.remove(id);
                return .{ .object = region.object, .size = region.size };
            }

            if (region.start > address) {
                return Error.InvalidAddress;
            }

            prev_id = id;
            curr_id = region.next_sorted;
        }

        return Error.InvalidAddress;
    }
};

pub const Paging = struct {
    pub const Flags = struct {
        type: enum {
            writeback,
            writethrough,
            non_cacheable,
            device,
        } = .writeback,
        shareability: enum {
            /// The strongest available shareability.
            strong,
            /// Balance between core contention and shareability.
            balanced,
            /// Not shared with others CPUs.
            local,
        } = .balanced,
        writable: bool = false,
        executable: bool = false,
        user: bool = false,
    };

    table_phys: u64,

    pub fn init(table_phys: ?u64) !@This() {
        return .{
            .table_phys = table_phys orelse try phys.allocPage(.l4K, true),
        };
    }

    pub fn deinit(self: *@This()) void {
        impl.freeTable(self.table_phys, 0);
    }

    pub fn map(
        self: *@This(),
        virtual_start: u64,
        physical_start: u64,
        page_count: usize,
        page_level: mem.PageLevel,
        flags: Flags,
    ) !void {
        const size = page_count << page_level.shift();

        var offset: u64 = 0;
        while (offset < size) : (offset += page_level.size()) {
            const virtual_address = virtual_start + offset;
            const physical_address = physical_start + offset;

            try impl.mapPage(
                self.table_phys,
                virtual_address,
                physical_address,
                page_level,
                flags,
            );
        }
    }

    pub fn unmap(
        self: *@This(),
        virtual_start: u64,
        page_count: usize,
        page_level: mem.PageLevel,
    ) void {
        const size = page_count << page_level.shift();

        var offset: u64 = 0;
        while (offset < size) : (offset += page_level.size()) {
            const virtual_address = virtual_start + offset;

            impl.unmapPage(
                self.table_phys,
                virtual_address,
            );
        }
    }

    pub const Mapping = struct {
        phys_addr: u64,
    };

    pub fn get(self: *@This(), virtual_address: u64) ?Mapping {
        return impl.getPage(self.table_phys, virtual_address);
    }
};

pub const Space = struct {
    pub const Error = error{
        InvalidObject,
        SegmentationFault,
    };

    pub const Level = enum { lower, higher };
    const PAGE_SIZE = mem.PageLevel.l4K.size();

    allocator: Allocator,
    paging: Paging,
    is_user: bool,

    pub fn init(level: Level, table_phys: ?u64, is_user: bool) !@This() {
        return .{
            .allocator = if (level == .lower)
                .init(Allocator.LOWER_BASE, Allocator.LOWER_LIMIT)
            else
                .init(boot.hhdm_limit, Allocator.HIGHER_LIMIT),

            .paging = try .init(table_phys),

            .is_user = is_user,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.paging.deinit();
        self.allocator.deinit();
    }

    pub fn apply(self: *@This()) void {
        _ = self;
        @panic("TODO Space.apply");
    }

    pub fn map(
        self: *@This(),
        object_id: Object.Id,
        size: u64,
        offset: u64,
    ) !u64 {
        const object = Object.acquire(object_id) orelse return Error.InvalidObject;
        errdefer object.release();

        const vaddr = try self.allocator.alloc(size, PAGE_SIZE, object, offset);

        return vaddr;
    }

    pub fn unmap(self: *@This(), addr: u64) !void {
        const info = try self.allocator.free(addr);
        self.paging.unmap(addr, info.size / PAGE_SIZE, .l4K);
        if (info.object) |object| object.release();
    }

    pub fn resolveFault(self: *@This(), fault_addr: u64) !struct { phys_addr: u64, flags: Paging.Flags } {
        const lock_flags = self.allocator.lock.lockShared();
        defer self.allocator.lock.unlockShared(lock_flags);

        const region = self.allocator.findRegion(fault_addr) orelse return Error.SegmentationFault;

        if (region.object) |object| {
            const offset_in_region = fault_addr - region.start;
            const total_offset = region.offset + offset_in_region;
            const page_index = @as(u32, @intCast(total_offset / PAGE_SIZE));

            const phys_addr = try object.commit(page_index);

            return .{ .phys_addr = phys_addr, .flags = .{
                .writable = object.flags.writable,
                .executable = object.flags.executable,
                .user = self.is_user,
            } };
        } else {
            return Error.SegmentationFault;
        }
    }
};

pub const Object = struct {
    pub const Map = heap.SlotMap(Object);
    pub const Id = Map.Key;

    var objects_map: Map = .init();
    var objects_map_lock: mem.RwLock = .{};

    pub const Flags = packed struct(u8) {
        writable: bool = false,
        executable: bool = false,
        _reserved0: u6 = 0,
    };

    const PAGE_SIZE = mem.PageLevel.l4K.size();

    id: Id,

    flags: Flags,
    size: u64,
    pages: heap.List(u64),

    lock: mem.RwLock,
    ref_count: std.atomic.Value(u32),

    pub fn commit(self: *Object, page_index: u32) !u64 {
        {
            const flags = self.lock.lockShared();
            defer self.lock.unlockShared(flags);

            const physical_address = self.pages.get(page_index).*;
            if (physical_address != 0) return physical_address;
        }

        const flags = self.lock.lockExclusive();
        defer self.lock.unlockExclusive(flags);

        // double check (race condition)
        const physical_address = self.pages.get(page_index).*;
        if (physical_address != 0) {
            return physical_address;
        }

        const new_phys = try phys.allocPage(.l4K, true);
        self.pages.get(page_index).* = new_phys;

        return new_phys;
    }

    pub fn create(size: u64, flags: Flags) !Id {
        var object: Object = undefined;

        object.flags = flags;
        object.size = std.mem.alignForward(u64, size, mem.PageLevel.l4K.size());
        object.pages = .init();

        const needed_slots = object.size / PAGE_SIZE;
        while (object.pages.capacity() < needed_slots) {
            try object.pages.grow();
        }

        object.lock = .{};
        object.ref_count = .init(0);

        const lock_flags = objects_map_lock.lockExclusive();
        defer objects_map_lock.unlockExclusive(lock_flags);

        const id = try objects_map.insert(object);
        const object_ptr = objects_map.get(id) orelse unreachable;

        object_ptr.id = id;

        return id;
    }

    fn destroy(self: *Object) void {
        const lock_flags = objects_map_lock.lockExclusive();
        defer objects_map_lock.unlockExclusive(lock_flags);

        if (self.ref_count.load(.acquire) > 0) {
            return;
        }

        defer objects_map.remove(self.id);

        var i: u32 = 0;
        while (i < (self.size / PAGE_SIZE)) : (i += 1) {
            const phys_addr = self.pages.get(i).*;
            if (phys_addr != 0) {
                phys.freePage(phys_addr, .l4K);
            }
        }

        self.pages.deinit();
    }

    pub fn acquire(id: Id) ?*Object {
        const lock_flags = objects_map_lock.lockShared();
        defer objects_map_lock.unlockShared(lock_flags);

        const object: *Object = objects_map.get(id) orelse return null;

        _ = object.ref_count.fetchAdd(1, .acq_rel);

        return object;
    }

    pub fn release(self: *Object) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            self.destroy();
        }
    }
};

// ---- //

comptime {
    _ = impl;

    _ = Allocator;
    _ = Space;
    _ = Object;
}
