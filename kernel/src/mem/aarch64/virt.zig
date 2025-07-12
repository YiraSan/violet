// --- imports --- //

const std = @import("std");
const log = std.log.scoped(.mem_virt);

const builtin = @import("builtin");

const kernel = @import("root");
const mem = kernel.mem;
const phys = mem.phys;
const virt = mem.virt;

// --- aarch64/virt.zig --- //

pub fn init() void {
    virt.kernel_space = virt.AddressSpace.init(null) catch @panic("failed to acquire a page for kernel_space");

    init_mair();
    set_ttbr0_el1(virt.kernel_space.root_table_phys);
}

pub fn flush(virt_addr: u64) void {
    const va = virt_addr >> phys.PageLevel.l4K.shift();

    asm volatile (
        \\ tlbi vae1is, %[va]
        \\ dsb ish
        \\ isb
        :
        : [va] "r" (va),
        : "memory"
    );
}

pub fn flush_all() void {
    asm volatile (
        \\ dsb ish
        \\ tlbi vmalle1
        \\ dsb ish
        \\ isb
        ::: "memory");
}

fn get_table(table_phys: u64, index: u64) ?u64 {
    const entry: *BlockDescriptor = @ptrFromInt(mem.hhdm_offset + table_phys + index * 8);

    if (entry.valid and entry.block_type == .table_page) {
        return entry.output_addr << 12;
    }

    return null;
}

fn ensure_table(table_phys: u64, index: u64) u64 {
    const entry: *BlockDescriptor = @ptrFromInt(mem.hhdm_offset + table_phys + index * 8);

    if (entry.valid and entry.block_type == .table_page) {
        return entry.output_addr << 12;
    }

    const new_table = phys.alloc_page(.l4K) catch @panic("unable to allocate new page table on AArch64");
    @memset(@as([*]u8, @ptrFromInt(mem.hhdm_offset + new_table))[0..4096], 0);

    entry.* = BlockDescriptor{
        .block_type = .table_page,
        .output_addr = @truncate(new_table >> 12),
    };

    return new_table;
}

pub fn free_table_recursive(table_phys: u64, level: u8) void {
    for (0..512) |i| {
        const e_ptr: *BlockDescriptor = @ptrFromInt(mem.hhdm_offset + table_phys + i * 8);
        const entry = e_ptr.*;

        if (!entry.valid) continue;

        if (entry.block_type == .table_page and level != 3) {
            free_table_recursive(entry.output_addr << 12, level + 1);
        } else {
            phys.free_page(entry.output_addr << 12, .l4K);
        }
    }

    phys.free_page(table_phys, .l4K);
}

pub fn map_page(
    space: *virt.AddressSpace,
    virt_addr: u64,
    phys_addr: u64,
    page_level: phys.PageLevel,
    flags: virt.MapFlags,
    contiguous_segment: bool,
) void {
    const l0 = (virt_addr >> 39) & 0x1FF;
    const l1 = (virt_addr >> 30) & 0x1FF;
    const l2 = (virt_addr >> 21) & 0x1FF;
    const l3 = (virt_addr >> 12) & 0x1FF;

    var block_descriptor = BlockDescriptor{
        .block_type = .table_page,
        .attr_index = if (flags.device) .device_ngnrne else .normal,
        .ap = if (flags.user)
            if (flags.writable) .rw_el0 else .ro_el0
        else if (flags.writable) .rw_el1 else .ro_el1,
        .output_addr = @truncate(phys_addr >> 12),
        .pxn = !flags.user and flags.executable,
        .uxn = flags.user and flags.executable,
        .contiguous = contiguous_segment,
    };

    var tp = space.root_table_phys;
    tp = ensure_table(tp, l0);
    switch (page_level) {
        .l1G => {
            const p: *BlockDescriptor = @ptrFromInt(mem.hhdm_offset + tp + l1 * 8);
            if (p.valid and p.block_type == .table_page) {
                free_table_recursive(p.output_addr << 12, 1);
            }
            block_descriptor.block_type = .block;
            p.* = block_descriptor;
        },
        .l2M => {
            tp = ensure_table(tp, l1);
            const p: *BlockDescriptor = @ptrFromInt(mem.hhdm_offset + tp + l2 * 8);
            if (p.valid and p.block_type == .table_page) {
                free_table_recursive(p.output_addr << 12, 2);
            }
            block_descriptor.block_type = .block;
            p.* = block_descriptor;
        },
        .l4K => {
            tp = ensure_table(tp, l1);
            tp = ensure_table(tp, l2);
            const p: *BlockDescriptor = @ptrFromInt(mem.hhdm_offset + tp + l3 * 8);
            p.* = block_descriptor;
        },
    }

    asm volatile (
        \\ dsb sy
        \\ isb
    );
}

// --- TTBRx_ELx --- //

fn get_ttbr0_el0() virt.VirtualSpace {
    const ttbr0_el0: u64 = asm volatile (
        \\ mrs %[result], ttbr0_el0
        : [result] "=r" (-> u64),
    );
    return .{ .root_table_phys = ttbr0_el0 };
}

fn get_ttbr1_el0() virt.VirtualSpace {
    const ttbr1_el0: u64 = asm volatile (
        \\ mrs %[result], ttbr1_el0
        : [result] "=r" (-> u64),
    );
    return .{ .root_table_phys = ttbr1_el0 };
}

fn get_ttbr0_el1() virt.VirtualSpace {
    const ttbr0_el1: u64 = asm volatile (
        \\ mrs %[result], ttbr0_el1
        : [result] "=r" (-> u64),
    );
    return .{ .root_table_phys = ttbr0_el1 };
}

fn get_ttbr1_el1() virt.VirtualSpace {
    const ttbr1_el1: u64 = asm volatile (
        \\ mrs %[result], ttbr1_el1
        : [result] "=r" (-> u64),
    );
    return .{ .root_table_phys = ttbr1_el1 };
}

fn set_ttbr0_el0(addr: u64) void {
    asm volatile (
        \\ msr ttbr0_el0, %[input]
        :
        : [input] "r" (addr),
        : "memory"
    );
}

fn set_ttbr1_el0(addr: u64) void {
    asm volatile (
        \\ msr ttbr1_el0, %[input]
        :
        : [input] "r" (addr),
        : "memory"
    );
}

fn set_ttbr0_el1(addr: u64) void {
    asm volatile (
        \\ msr ttbr0_el1, %[input]
        :
        : [input] "r" (addr),
        : "memory"
    );
}

fn set_ttbr1_el1(addr: u64) void {
    asm volatile (
        \\ msr ttbr1_el1, %[input]
        :
        : [input] "r" (addr),
        : "memory"
    );
}

// --- MAIR --- //

const MAIR_NORMAL_CACHEABLE = 0xff;
const MAIR_NORMAL_NONCACHEABLE = 0x44;
const MAIR_DEVICE_nGnRnE = 0x00;
const MAIR_DEVICE_nGnRE = 0x04;

fn init_mair() void {
    const mair_value: u64 =
        (MAIR_NORMAL_CACHEABLE << 0) | // index 0
        (MAIR_NORMAL_NONCACHEABLE << 8) | // index 1
        (MAIR_DEVICE_nGnRnE << 16) | // index 2
        (MAIR_DEVICE_nGnRE << 24); // index 3

    asm volatile (
        \\ msr mair_el1, %[val]
        :
        : [val] "r" (mair_value),
        : "memory"
    );
}

// --- struct --- //

const BlockDescriptor = packed struct(u64) {
    valid: bool = true, // bit 0
    block_type: enum(u1) { // bit 1
        block = 0,
        table_page = 1,
    },
    attr_index: enum(u3) { // bit 2-4
        normal = 0,
        normal_no_caching = 1,
        device_ngnrne = 2,
        device_ngnre = 3,
    } = .normal,
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
    _available: u4 = 0, // bit 55-58
    impl_def: u4 = 0, // bit 59-62
    _reserved3: u1 = 0, // bit 63
};
