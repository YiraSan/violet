//! Generally, the whole virtual memory managment needs to be entirely re-designed and re-coded from scratch.
//! Things todo :
//! - Instaure a limit on overcommitment.

// --- dependencies --- //

const std = @import("std");
const builtin = @import("builtin");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;

const impl = switch (builtin.cpu.arch) {
    .aarch64 => @import("aarch64/virt.zig"),
    else => unreachable,
};

// --- mem/virt.zig --- //

pub var user_space: *Space = undefined;
pub var kernel_space: Space = undefined;

pub fn init(hhdm_limit: u64) !void {
    try impl.init(hhdm_limit);
}

pub fn flush(virt_addr: u64) void {
    impl.flush(virt_addr);
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

    pub fn init(half: MemoryLocation, l0_table: u64) @This() {
        return .{
            .half = half,
            .l0_table = l0_table,
            .last_addr = if (half == .lower) 0x1000 else 0,
            .lock = .{},
        };
    }

    pub fn base(self: *Space) u64 {
        return switch (self.half) {
            .higher => 0xFFFF_8000_0000_0000,
            .lower => 0x0000_0000_0000_0000,
        };
    }

    pub fn reserve(self: *Space, count: usize) Reservation {
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
    pub fn getPage(self: *Space, virt_addr: u64) ?Mapping {
        self.lock.lock();
        defer self.lock.unlock();

        return impl.getPage(self, virt_addr);
    }

    /// Returns `null` if no modification has been made.
    pub fn setPage(self: *Space, virt_addr: u64, mapping: Mapping) ?void {
        self.lock.lock();
        defer self.lock.unlock();

        return impl.setPage(self, virt_addr, mapping);
    }
};

pub const Mapping = struct {
    tocommit_heap: bool,
    phys_addr: u64,
    level: mem.PageLevel,
    flags: MemoryFlags,
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
    pub fn map(self: @This(), phys_addr: u64, flags: MemoryFlags) void {
        self.space.lock.lock();
        defer self.space.lock.unlock();

        const virt_addr = self.address();

        var offset: usize = 0;
        for (0..self.size) |_| {
            const virta = virt_addr + offset;
            const physa = if (phys_addr != 0) phys_addr + offset else phys_addr;

            switch (builtin.cpu.arch) {
                .aarch64 => impl.mapPage(self.space, virta, physa, .l4K, flags, false), // TODO implement contiguous mapping
                else => unreachable,
            }
            offset += 0x1000;
        }
    }

    // fn unmap
};

pub const MemoryFlags = struct {
    writable: bool = false,
    executable: bool = false,
    user: bool = false,
    no_cache: bool = false,
    device: bool = false,
    writethrough: bool = false,
};
