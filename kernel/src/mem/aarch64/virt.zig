// --- dependencies --- //

const std = @import("std");
const builtin = @import("builtin");
const ark = @import("ark");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const phys = mem.phys;
const virt = mem.virt;

// --- mem/virt.zig --- //

pub fn init(hhdm_limit: u64) !void {
    virt.user_space = @constCast(&virt.Space.init(.lower, switch (builtin.cpu.arch) {
        .aarch64 => ark.cpu.armv8a_64.registers.TTBR0_EL1.get().l0_table,
        else => unreachable,
    }));

    virt.kernel_space = .init(.higher, switch (builtin.cpu.arch) {
        .aarch64 => ark.cpu.armv8a_64.registers.TTBR1_EL1.get().l0_table,
        else => unreachable,
    });

    virt.kernel_space.last_addr = hhdm_limit;
}

pub fn flush(virt_addr: u64) void {
    const va = virt_addr >> mem.PageLevel.l4K.shift();

    asm volatile (
        \\ tlbi vae1is, %[va]
        \\ dsb ish
        \\ isb
        :
        : [va] "r" (va),
        : "memory"
    );
}

pub fn flushAll() void {
    asm volatile (
        \\ dsb ish
        \\ tlbi vmalle1
        \\ dsb ish
        \\ isb
        ::: "memory");
}

pub fn mapPage(
    space: *virt.Space,
    virt_addr: u64,
    phys_addr: u64,
    page_level: mem.PageLevel,
    flags: virt.MemoryFlags,
    /// NOTE this is an hint
    contiguous_segment: bool,
) void {
    const l0 = (virt_addr >> 39) & 0x1FF;
    const l1 = (virt_addr >> 30) & 0x1FF;
    const l2 = (virt_addr >> 21) & 0x1FF;
    const l3 = (virt_addr >> 12) & 0x1FF;

    var block_descriptor = BlockDescriptor{
        .block_type = .table_page,
        .attr_index = if (flags.device) .device else if (flags.writethrough) .writethrough else .writeback,
        .ap = if (flags.writable and !flags.user) .rw_el1 else if (flags.writable and flags.user) .rw_el0 else if (!flags.writable and !flags.user) .ro_el1 else .ro_el0,
        .output_addr = @truncate(phys_addr >> 12),
        .pxn = !flags.executable or flags.user,
        .uxn = !flags.executable or !flags.user,
        .contiguous = contiguous_segment,
        .access_flag = phys_addr != 0,
        ._os_available = if (phys_addr == 0) .access_flag_for_heap else .undefined,
    };

    var tp = space.l0_table;
    tp = ensure_table(tp, l0);

    switch (page_level) {
        .l1G => {
            const p: *BlockDescriptor = @ptrFromInt(kernel.hhdm_base + tp + l1 * 8);
            if (p.valid and p.block_type == .table_page) {
                free_table_recursive(p.output_addr << 12, 1);
            }
            block_descriptor.block_type = .block;
            p.* = block_descriptor;
        },
        .l2M => {
            tp = ensure_table(tp, l1);
            const p: *BlockDescriptor = @ptrFromInt(kernel.hhdm_base + tp + l2 * 8);
            if (p.valid and p.block_type == .table_page) {
                free_table_recursive(p.output_addr << 12, 2);
            }
            block_descriptor.block_type = .block;
            p.* = block_descriptor;
        },
        .l4K => {
            tp = ensure_table(tp, l1);
            tp = ensure_table(tp, l2);
            const p: *BlockDescriptor = @ptrFromInt(kernel.hhdm_base + tp + l3 * 8);
            p.* = block_descriptor;
        },
    }

    asm volatile (
        \\ dsb sy
        \\ isb
    );
}

/// Returns current state of a page, `null` if there's no mapping.
pub fn getPage(
    space: *virt.Space,
    virt_addr: u64,
) ?virt.Mapping {
    const l0_index = (virt_addr >> 39) & 0x1FF;
    const l1_index = (virt_addr >> 30) & 0x1FF;
    const l2_index = (virt_addr >> 21) & 0x1FF;
    const l3_index = (virt_addr >> 12) & 0x1FF;

    const l0_entry: *BlockDescriptor = @ptrFromInt(kernel.hhdm_base + space.l0_table + l0_index * 8);
    if (!l0_entry.valid) return null;
    if (l0_entry.block_type != .table_page) unreachable; // should not be possible since 512 GiB allocation is not permitted.

    const l1_table: u64 = l0_entry.output_addr << 12;
    const l1_entry: *BlockDescriptor = @ptrFromInt(kernel.hhdm_base + l1_table + l1_index * 8);
    if (!l1_entry.valid) return null;

    // 1 GiB page
    if (l1_entry.block_type == .block) {
        var mapping = l1_entry.getPageMapping();
        mapping.level = .l1G;
        return mapping;
    }

    const l2_table: u64 = l1_entry.output_addr << 12;
    const l2_entry: *BlockDescriptor = @ptrFromInt(kernel.hhdm_base + l2_table + l2_index * 8);
    if (!l2_entry.valid) return null;

    // 2 MiB page
    if (l2_entry.block_type == .block) {
        var mapping = l2_entry.getPageMapping();
        mapping.level = .l2M;
        return mapping;
    }

    // 4 KiB page
    const l3_table: u64 = l2_entry.output_addr << 12;
    const l3_entry: *BlockDescriptor = @ptrFromInt(kernel.hhdm_base + l3_table + l3_index * 8);
    if (!l3_entry.valid) return null;
    if (l3_entry.block_type != .table_page) unreachable; // if unreachable is reached, then WTF ?

    var mapping = l3_entry.getPageMapping();
    mapping.level = .l4K;
    return mapping;
}

/// Returns `null` if no modification has been made.
pub fn setPage(
    space: *virt.Space,
    virt_addr: u64,
    mapping: virt.Mapping,
) ?void {
    const l0_index = (virt_addr >> 39) & 0x1FF;
    const l1_index = (virt_addr >> 30) & 0x1FF;
    const l2_index = (virt_addr >> 21) & 0x1FF;
    const l3_index = (virt_addr >> 12) & 0x1FF;

    const l0_entry: *BlockDescriptor = @ptrFromInt(kernel.hhdm_base + space.l0_table + l0_index * 8);
    if (!l0_entry.valid) return null;
    if (l0_entry.block_type != .table_page) unreachable; // should not be possible since 512 GiB allocation is not permitted.

    const l1_table: u64 = l0_entry.output_addr << 12;
    const l1_entry: *BlockDescriptor = @ptrFromInt(kernel.hhdm_base + l1_table + l1_index * 8);
    if (!l1_entry.valid) return null;

    // 1 GiB page
    if (l1_entry.block_type == .block) {
        l1_entry.setPageMapping(mapping);
    }

    const l2_table: u64 = l1_entry.output_addr << 12;
    const l2_entry: *BlockDescriptor = @ptrFromInt(kernel.hhdm_base + l2_table + l2_index * 8);
    if (!l2_entry.valid) return null;

    // 2 MiB page
    if (l2_entry.block_type == .block) {
        l2_entry.setPageMapping(mapping);
    }

    // 4 KiB page
    const l3_table: u64 = l2_entry.output_addr << 12;
    const l3_entry: *BlockDescriptor = @ptrFromInt(kernel.hhdm_base + l3_table + l3_index * 8);
    if (!l3_entry.valid) return null;
    if (l3_entry.block_type != .table_page) unreachable; // if unreachable is reached, then WTF ?

    l3_entry.setPageMapping(mapping);
}

// --- mem/aarch64/virt.zig --- //

const BlockDescriptor = packed struct(u64) {
    valid: bool = true, // bit 0
    block_type: enum(u1) { // bit 1
        block = 0,
        table_page = 1,
    },
    attr_index: enum(u3) { // bit 2-4
        device = 0,
        non_cacheable = 1,
        writethrough = 2,
        writeback = 3,
    } = .writeback,
    non_secure: bool = true, // bit 5
    ap: enum(u2) { // bit 6-7
        rw_el1 = 0b00,
        rw_el0 = 0b01,
        ro_el1 = 0b10,
        ro_el0 = 0b11,
    } = .rw_el1,
    sh: enum(u2) { // bit 8-9
        non_shareable = 0b00,
        _reserved = 0b01,
        outer_shareable = 0b10,
        inner_shareable = 0b11,
    } = .outer_shareable,
    access_flag: bool = true, // bit 10
    not_global: bool = false, // bit 11
    output_addr: u36 = 0, // bit 12-47
    _reserved1: u3 = 0, // bit 48-50
    dbm: bool = true, // bit 51
    contiguous: bool = false, // bit 52
    pxn: bool = false, // bit 53
    uxn: bool = false, // bit 54
    _os_available: enum(u4) { // bit 55-58
        undefined = 0b0000,
        access_flag_for_heap = 0b0001,
    } = .undefined,
    impl_def: u4 = 0, // bit 59-62
    _reserved3: u1 = 0, // bit 63

    pub fn setPageMapping(self: *@This(), mapping: virt.Mapping) void {
        self.* = BlockDescriptor{
            .block_type = .table_page,
            .attr_index = if (mapping.flags.device) .device else if (mapping.flags.writethrough) .writethrough else .writeback,
            .ap = if (mapping.flags.writable and !mapping.flags.user) .rw_el1 else if (mapping.flags.writable and mapping.flags.user) .rw_el0 else if (!mapping.flags.writable and !mapping.flags.user) .ro_el1 else .ro_el0,
            .output_addr = @truncate(mapping.phys_addr >> 12),
            .pxn = !mapping.flags.executable or mapping.flags.user,
            .uxn = !mapping.flags.executable or !mapping.flags.user,
            .contiguous = false,
            .access_flag = mapping.phys_addr != 0,
            ._os_available = if (mapping.tocommit_heap) .access_flag_for_heap else .undefined,
        };
    }

    pub fn getPageMapping(self: *@This()) virt.Mapping {
        const phys_addr: u64 = self.output_addr << 12;
        return virt.Mapping{
            .tocommit_heap = self._os_available == .access_flag_for_heap,
            .phys_addr = phys_addr,
            .level = undefined,
            .flags = .{
                .device = self.attr_index == .device,
                .writethrough = self.attr_index == .writethrough,
                .no_cache = self.attr_index == .non_cacheable,
                .writable = self.ap == .rw_el0 or self.ap == .rw_el1,
                .user = self.ap == .ro_el0 or self.ap == .rw_el0,
                .executable = !self.uxn or (!self.pxn and (self.ap == .ro_el1 or self.ap == .rw_el1)),
            },
        };
    }
};

fn get_table(table_addr: u64, index: u64) ?u64 {
    const entry: *BlockDescriptor = @ptrFromInt(kernel.hhdm_base + table_addr + index * 8);

    if (entry.valid and entry.block_type == .table_page) {
        return entry.output_addr << 12;
    }

    return null;
}

fn ensure_table(table_addr: u64, index: u64) u64 {
    const entry: *BlockDescriptor = @ptrFromInt(kernel.hhdm_base + table_addr + index * 8);

    if (entry.valid and entry.block_type == .table_page) {
        return entry.output_addr << 12;
    }

    const new_table = phys.alloc_page(.l4K, true) catch @panic("unable to allocate a page_table");

    entry.* = BlockDescriptor{
        .block_type = .table_page,
        .output_addr = @truncate(new_table >> 12),
    };

    return new_table;
}

fn free_table_recursive(table_addr: u64, level: u8) void {
    for (0..512) |i| {
        const e_ptr: *BlockDescriptor = @ptrFromInt(kernel.hhdm_base + table_addr + i * 8);
        const entry = e_ptr.*;

        if (!entry.valid) continue;

        if (entry.block_type == .table_page and level != 3) {
            free_table_recursive(entry.output_addr << 12, level + 1);
        } else {
            phys.free_page(entry.output_addr << 12, .l4K);
        }
    }

    phys.free_page(table_addr, .l4K);
}
