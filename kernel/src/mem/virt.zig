//! Generally, the whole virtual memory managment needs to be entirely re-designed and re-coded from scratch.
//! Things todo :
//! - Instaure a limit on overcommitment.

// --- dependencies --- //

const std = @import("std");
const builtin = @import("builtin");
const ark = @import("ark");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;

const impl = switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64/virt.zig"),
    else => unreachable,
};

// --- mem/virt.zig --- //

pub var kernel_space: Space = undefined;

pub fn init(hhdm_limit: u64) !void {
    try impl.init(hhdm_limit);
}

pub fn flush(virt_addr: u64, page_level: mem.PageLevel) void {
    impl.flush(virt_addr, page_level);
}

pub fn flushAll() void {
    impl.flushAll();
}

pub const Space = struct {
    pub const MemoryLocation = enum { lower, higher };

    half: MemoryLocation,
    l0_table: u64,
    last_addr: u64,
    lock: mem.SpinLock,

    /// SHOULD NEVER BE APPLIED ON KERNEL_SPACE
    /// NOTE on x86_64 this will be used to copy kernel_space onto the space
    pub fn apply(self: *Space) void {
        const cpu = kernel.arch.Cpu.get();
        cpu.user_space = self;

        impl.applySpace(self);

        impl.flushAll();
    }

    pub fn init(half: MemoryLocation, l0_table: u64) @This() {
        return .{
            .half = half,
            .l0_table = l0_table,
            .last_addr = if (half == .lower) 0x1000 else 0,
            .lock = .{},
        };
    }

    pub fn free(self: *@This()) void {
        std.log.warn("(todo) free heap and stack from space", .{});
        impl.free_table_recursive(self.l0_table, 0);
    }

    pub fn base(self: *Space) u64 {
        return switch (self.half) {
            .higher => 0xFFFF_8000_0000_0000,
            .lower => 0x0000_0000_0000_0000,
        };
    }

    pub fn reserve(self: *@This(), count: usize) Reservation {
        self.lock.lock();
        defer self.lock.unlock();

        const reservation = Reservation{
            .space = self,
            .virt = self.last_addr,
            .size = count,
        };

        self.last_addr = std.mem.alignForward(u64, self.last_addr + (count << 12), 0x1000);

        return reservation;
    }

    /// Returns current state of a page, `null` if there's no mapping.
    pub fn getPage(self: *@This(), virt_addr: u64) ?Mapping {
        self.lock.lock();
        defer self.lock.unlock();

        return impl.getPage(self, virt_addr);
    }

    /// Returns `null` if no modification has been made.
    pub fn setPage(self: *@This(), virt_addr: u64, mapping: Mapping) ?void {
        self.lock.lock();
        defer self.lock.unlock();

        return impl.setPage(self, virt_addr, mapping);
    }

    pub fn unmapPage(self: *@This(), virt_addr: u64) void {
        self.lock.lock();
        defer self.lock.unlock();

        return impl.unmapPage(self, virt_addr);
    }
};

pub const MappingHint = enum(u4) {
    no_hint = 0b0000,
    heap_begin = 0b0001,
    heap_inbetween = 0b0010,
    heap_end = 0b0011,
    heap_single = 0b0100,
    heap_stack = 0b0101,
    heap_begin_stack = 0b0111,
    stack_begin_guard_page = 0b1000,
    stack_end_guard_page = 0b1001,
};

pub const Mapping = struct {
    /// `0` means "uncommited page".
    phys_addr: u64,
    level: mem.PageLevel,
    flags: MemoryFlags,
    hint: MappingHint = .no_hint,
};

pub const Reservation = struct {
    space: *Space,
    virt: u64,
    size: usize,

    pub fn address(self: Reservation) u64 {
        return self.space.base() | self.virt;
    }

    pub fn unreserve(self: Reservation) void {
        _ = self;
        unreachable;
    }

    /// if `phys_addr` == 0 it won't commit physical pages, but will commit-on-use.
    pub fn map(self: @This(), phys_addr: u64, flags: MemoryFlags, hint: MappingHint) void {
        self.space.lock.lock();
        defer self.space.lock.unlock();

        const virt_addr = self.address();

        var offset: usize = 0;
        for (0..self.size) |_| {
            const virta = virt_addr + offset;
            const physa = if (phys_addr != 0) phys_addr + offset else phys_addr;

            switch (builtin.cpu.arch) {
                .aarch64 => impl.mapPage(
                    self.space,
                    virta,
                    physa,
                    .l4K,
                    flags,
                    hint,
                ),
                else => unreachable,
            }

            impl.flush(virt_addr, .l4K);

            offset += 0x1000;
        }
    }
};

pub const MemoryFlags = ark.mem.MemoryFlags;