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

pub const invalidate = impl.invalidate;

// --- mem/vmm.zig --- //

pub var kernel_space: Space = undefined;

pub fn init() !void {
    try impl.init();
}

pub const Allocator = struct {
    pub const Error = error{
        OutOfVirtualMemory,
        InvalidAlignment,
        OutOfRange,
        AddressAlreadyInUse,
        InvalidAddress,
    };

    const Region = struct {
        start: u64,
        end: u64,

        object: ?*Object,
        offset: u64,
        flags: ?Object.Flags,

        /// NOTE fetching can be done under lockShared, but loading should be done under lockExclusive.
        syscall_pinned: std.atomic.Value(usize),

        const Tree = heap.RedBlackTree(u64, Region, compareRegion);

        inline fn compareRegion(address: u64, region: Region) std.math.Order {
            if (address < region.start) return .lt;
            if (address >= region.end) return .gt;
            return .eq;
        }
    };

    pub const LOWER_BASE: u64 = 0x0000_0000_0001_0000;
    pub const LOWER_LIMIT: u64 = 0x0000_FFFF_FFFF_FFFF;
    pub const HIGHER_LIMIT: u64 = 0xFFFF_FFFF_FFFF_FFFF;

    base: u64,
    limit: u64,
    regions: Region.Tree,
    lock: mem.RwLock,

    cached_hole_start: u64,

    pub fn init(base: u64, limit: u64) @This() {
        return .{
            .base = base,
            .limit = limit,
            .regions = .init(),
            .lock = .{},
            .cached_hole_start = 0,
        };
    }

    pub fn deinit(self: *@This()) void {
        var curr_id = self.regions.first();
        while (curr_id) |id| {
            const region = self.regions.get(id).?;
            if (region.object) |object| object.release();
            curr_id = self.regions.next(id);
        }
        self.regions.deinit();
    }

    pub fn alloc(
        self: *@This(),
        size: u64,
        alignment: u64,
        object: ?*Object,
        offset: u64,
        flags: ?Object.Flags,
        syscall_protect: bool,
    ) !u64 {
        if (size == 0) return 0;

        const lock_flags = self.lock.lockExclusive();
        defer self.lock.unlockExclusive(lock_flags);

        const actual_align = @max(alignment, mem.PageLevel.l4K.size());
        const actual_size = std.mem.alignForward(u64, size, mem.PageLevel.l4K.size());

        const start_search = @max(self.base, self.cached_hole_start);

        var candidate_start = std.mem.alignForward(u64, start_search, actual_align);
        var curr_id = self.regions.first();

        while (curr_id) |id| {
            const region = self.regions.get(id).?;
            if (region.end <= candidate_start) {
                curr_id = self.regions.next(id);
                continue;
            }

            if (candidate_start + actual_size <= region.start) {
                if (candidate_start + actual_size <= self.limit) {
                    break;
                }
            }

            _, const overflow = @addWithOverflow(region.end, 0);
            if (overflow == 1) return Error.OutOfVirtualMemory;

            candidate_start = std.mem.alignForward(u64, region.end, actual_align);

            if (candidate_start < region.end) return Error.OutOfVirtualMemory;
            if (candidate_start >= self.limit) return Error.OutOfVirtualMemory;

            curr_id = self.regions.next(id);
        }

        const end_addr, const overflowed = @addWithOverflow(candidate_start, actual_size);

        if (overflowed == 1 or end_addr > self.limit) {
            return Error.OutOfVirtualMemory;
        }

        const new_region = Region{
            .start = candidate_start,
            .end = end_addr,
            .object = object,
            .offset = offset,
            .flags = flags,
            .syscall_pinned = .init(if (syscall_protect) 1 else 0),
        };

        _ = try self.regions.insert(candidate_start, new_region);

        self.cached_hole_start = end_addr;

        return candidate_start;
    }

    pub fn allocAt(
        self: *@This(),
        address: u64,
        size: u64,
        object: ?*Object,
        offset: u64,
        flags: ?Object.Flags,
        syscall_protect: bool,
    ) !void {
        if (size == 0) return;

        const lock_flags = self.lock.lockExclusive();
        defer self.lock.unlockExclusive(lock_flags);

        if (!std.mem.isAligned(address, mem.PageLevel.l4K.size())) return Error.InvalidAlignment;

        const actual_size = std.mem.alignForward(u64, size, mem.PageLevel.l4K.size());
        const end_addr, const overflowed = @addWithOverflow(address, actual_size);

        if (overflowed == 1 or end_addr > self.limit or address < self.base) {
            return Error.OutOfRange;
        }

        var curr_id = self.regions.first();
        while (curr_id) |id| {
            const region = self.regions.get(id).?;

            if (region.start >= end_addr) break;

            if (region.end > address) {
                return Error.AddressAlreadyInUse;
            }

            curr_id = self.regions.next(id);
        }

        const new_region = Region{
            .start = address,
            .end = end_addr,
            .object = object,
            .offset = offset,
            .flags = flags,
            .syscall_pinned = .init(if (syscall_protect) 1 else 0),
        };

        _ = try self.regions.insert(address, new_region);

        if (address == self.cached_hole_start) {
            self.cached_hole_start = end_addr;
        }
    }

    pub fn free(self: *@This(), address: u64, is_syscall: bool) Error!struct { object: ?*Object, size: u64 } {
        const lock_flags = self.lock.lockExclusive();
        defer self.lock.unlockExclusive(lock_flags);

        const region_id = self.regions.find(address) orelse return Error.InvalidAddress;

        const region_ptr = self.regions.get(region_id).?;

        if (is_syscall) if (region_ptr.syscall_pinned.load(.acquire) > 0) return Error.InvalidAddress;

        if (region_ptr.start != address) {
            return Error.InvalidAddress;
        }

        if (region_ptr.object) |object| {
            object.release();
        }

        const region = self.regions.remove(region_id).?;

        if (address < self.cached_hole_start) {
            self.cached_hole_start = address;
        }

        return .{
            .object = region.object,
            .size = region.end - region.start,
        };
    }

    pub fn splitAndAssign(
        self: *@This(),
        address: u64,
        size: u64,
        new_object: Object.Id,
        new_offset: u64,
        new_flags: ?Object.Flags,
    ) !void {
        if (size == 0) return;

        const lock_flags = self.lock.lockExclusive();
        defer self.lock.unlockExclusive(lock_flags);

        if (!std.mem.isAligned(address, mem.PageLevel.l4K.size()) or
            !std.mem.isAligned(size, mem.PageLevel.l4K.size()))
        {
            return Error.InvalidAlignment;
        }

        const end_addr = address + size;

        var target_id: ?Region.Tree.Id = null;
        var curr = self.regions.first();

        while (curr) |id| {
            const r = self.regions.get(id).?;
            if (address >= r.start and address < r.end) {
                target_id = id;
                break;
            }
            if (r.start > address) break;
            curr = self.regions.next(id);
        }

        const region_id = target_id orelse return Error.InvalidAddress;
        const old_region = self.regions.get(region_id).?;

        if (end_addr > old_region.end) {
            return Error.OutOfRange;
        }

        const old_start = old_region.start;
        const old_end = old_region.end;
        const old_obj = old_region.object;
        const old_base_offset = old_region.offset;
        const old_flags = old_region.flags;
        const old_pinned = old_region.syscall_pinned.load(.acquire);

        _ = self.regions.remove(region_id);

        if (address > old_start) {
            if (old_obj) |o| {
                _ = Object.acquire(o.id);
            }

            const left_region = Region{
                .start = old_start,
                .end = address,
                .object = old_obj,
                .offset = old_base_offset,
                .flags = old_flags,
                .syscall_pinned = .init(old_pinned),
            };
            _ = try self.regions.insert(old_start, left_region);
        }

        {
            const center_region = Region{
                .start = address,
                .end = end_addr,
                .object = if (Object.acquire(new_object)) |obj| obj else null,
                .offset = new_offset,
                .flags = new_flags,
                .syscall_pinned = .init(old_pinned),
            };
            _ = try self.regions.insert(address, center_region);
        }

        if (end_addr < old_end) {
            if (old_obj) |o| {
                _ = Object.acquire(o.id);
            }
            const offset_delta = end_addr - old_start;
            const right_offset = old_base_offset + offset_delta;

            const right_region = Region{
                .start = end_addr,
                .end = old_end,
                .object = old_obj,
                .offset = right_offset,
                .flags = old_flags,
                .syscall_pinned = .init(old_pinned),
            };
            _ = try self.regions.insert(end_addr, right_region);
        }

        if (old_obj) |o| o.release();
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
            .table_phys = table_phys orelse try phys.allocPage(true),
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
        alignment: u64,
        offset: u64,
        flags: ?Object.Flags,
        syscall_protect: bool,
    ) !u64 {
        const object = Object.acquire(object_id) orelse return Error.InvalidObject;
        errdefer object.release();

        const vaddr = try self.allocator.alloc(size, alignment, object, offset, flags, syscall_protect);

        return vaddr;
    }

    pub fn unmap(self: *@This(), addr: u64, is_syscall: bool) !void {
        const info = try self.allocator.free(addr, is_syscall);
        self.paging.unmap(addr, info.size / PAGE_SIZE, .l4K);
    }

    pub fn resolveFault(self: *@This(), fault_addr: u64) !struct { phys_addr: u64, flags: Paging.Flags } {
        const lock_flags = self.allocator.lock.lockShared();
        defer self.allocator.lock.unlockShared(lock_flags);

        const region_id = self.allocator.regions.find(fault_addr) orelse return Error.SegmentationFault;

        const region = self.allocator.regions.get(region_id).?;

        if (region.object) |object| {
            const offset_in_vma = fault_addr - region.start;
            const total_offset = region.offset + offset_in_vma;
            const page_index = @as(u32, @intCast(total_offset / PAGE_SIZE));
            const phys_addr = try object.commit(page_index);
            const effective_flags = region.flags orelse object.flags;

            return .{ .phys_addr = phys_addr, .flags = .{
                .writable = effective_flags.writable,
                .executable = effective_flags.executable,
                .user = self.is_user,
            } };
        }

        return Error.SegmentationFault;
    }
};

pub const Object = struct {
    pub const Map = heap.SlotMap(Object);
    pub const Id = Map.Key;

    var objects_map: Map = .init();
    var objects_map_lock: mem.RwLock = .{};

    pub const Flags = struct {
        writable: bool = false,
        executable: bool = false,
    };

    const PAGE_SIZE = mem.PageLevel.l4K.size();

    id: Id,

    flags: Flags,
    size: u64,
    pages: heap.List(u64),

    lock: mem.RwLock,
    ref_count: std.atomic.Value(u32),

    pub fn commit(self: *Object, page_index: u32) !u64 {
        const max_pages = self.size / PAGE_SIZE;
        if (page_index >= max_pages) return Space.Error.SegmentationFault;

        {
            const flags = self.lock.lockShared();
            defer self.lock.unlockShared(flags);

            const phys_addr = self.pages.get(page_index).*;
            if (phys_addr != 0) return phys_addr;
        }

        const flags = self.lock.lockExclusive();
        defer self.lock.unlockExclusive(flags);

        const slot_ptr = self.pages.get(page_index);
        if (slot_ptr.* != 0) {
            return slot_ptr.*;
        }

        const new_phys = try phys.allocPage(true);
        slot_ptr.* = new_phys;

        return new_phys;
    }

    pub fn create(size: u64, flags: Flags) !Id {
        var object: Object = undefined;

        object.flags = flags;
        object.size = std.mem.alignForward(u64, size, mem.PageLevel.l4K.size());
        object.pages = .init();

        const needed_slots = object.size / PAGE_SIZE;

        try object.pages.ensureTotalCapacity(needed_slots);

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
                phys.freePage(phys_addr);
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
