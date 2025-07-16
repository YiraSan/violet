// --- imports --- //

const std = @import("std");
const log = std.log.scoped(.mem_virt);

const builtin = @import("builtin");

const kernel = @import("root");
const mem = kernel.mem;
const phys = mem.phys;
const virt = mem.virt;

// --- x86_64/virt.zig --- //

pub fn init() void {
    const cr3: usize = asm volatile (
        \\ mov %%cr3, %[result]
        : [result] "=r" (-> usize),
    );

    const virt_space = virt.AddressSpace.init(cr3, 0) catch @panic("unable to allocate address space in virt.init()");

    virt.kernel_space = virt_space;
}

pub fn flush(virt_addr: u64) void {
    asm volatile (
        \\ invlpg (%[addr])
        :
        : [addr] "r" (virt_addr),
        : "memory"
    );
}

pub fn flush_all() void {
    var cr3_val: usize = 0;
    asm volatile (
        \\ mov %[result], %cr3
        : [result] "=r" (cr3_val),
        :
        : "memory"
    );
    asm volatile (
        \\ mov %cr3, %[input]
        :
        : [input] "r" (cr3_val),
        : "memory"
    );
}

fn ensure_table(table_phys: usize, index: usize) usize {
    const entry_ptr: *u64 = @ptrFromInt(mem.hhdm_offset + table_phys + index * 8);
    const entry = entry_ptr.*;

    if ((entry & 0x1) != 0) {
        return entry & 0x000fffff_fffff000;
    }

    const new_table = phys.alloc_page(.l4K) catch @panic("unable to allocate new page table");

    const new_table_ptr: [*]u8 = @ptrFromInt(mem.hhdm_offset + new_table);
    @memset(new_table_ptr[0..phys.PageLevel.l4K.size()], 0);

    entry_ptr.* = new_table | 0b11;

    return new_table;
}

pub fn free_table_recursive(table_phys: usize, level: u8) void {
    if (level == 4) return; // niveau PT max

    for (0..512) |entry_index| {
        const entry_ptr: *u64 = @ptrFromInt(mem.hhdm_offset + table_phys + entry_index * 8);
        const entry = entry_ptr.*;

        if ((entry & 1) == 0) continue; // invalid

        if ((entry & (1 << 1)) != 0) {
            free_table_recursive(entry & 0x000fffff_fffff000, level + 1);
        } else {
            phys.free_page(entry & 0x000fffff_fffff000, .l4K);
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
    _ = contiguous_segment;

    const pml4_index = (virt_addr >> 39) & 0x1FF;
    const pdpt_index = (virt_addr >> 30) & 0x1FF;
    const pd_index = (virt_addr >> 21) & 0x1FF;
    const pt_index = (virt_addr >> 12) & 0x1FF;

    var page_descriptor = PageTableEntry{
        .present = true,
        .addr = @truncate(phys_addr >> 12),
        .rw = if (flags.writable) .read_write else .read_only,
        .user = if (flags.user) .user_accessible else .supervisor_only,
        .nx = !flags.executable,
        .cache_disable = flags.no_cache or flags.device,
    };

    var table_phys = space.root_table_phys;

    table_phys = ensure_table(table_phys, @intCast(pml4_index));

    if (page_level == .l1G) {
        const entry: *PageTableEntry = @ptrFromInt(mem.hhdm_offset + table_phys + pdpt_index * 8);

        if (entry.present) {
            if (entry.large_page) {
                phys.free_page(entry.addr << 12, .l1G);
            } else {
                free_table_recursive(entry.addr << 12, 2);
            }
        }

        page_descriptor.large_page = true;
        entry.* = page_descriptor;
        return;
    }

    table_phys = ensure_table(table_phys, @intCast(pdpt_index));

    if (page_level == .l2M) {
        const entry: *PageTableEntry = @ptrFromInt(mem.hhdm_offset + table_phys + pd_index * 8);

        if (entry.present) {
            if (entry.large_page) {
                phys.free_page(entry.addr << 12, .l2M);
            } else {
                free_table_recursive(entry.addr << 12, 3);
            }
        }

        page_descriptor.large_page = true;
        entry.* = page_descriptor;
        return;
    }

    table_phys = ensure_table(table_phys, @intCast(pd_index));

    const entry: *PageTableEntry = @ptrFromInt(mem.hhdm_offset + table_phys + pt_index * 8);
    entry.* = page_descriptor;
}

// --- structs --- //

const PageTableEntry = packed struct(u64) {
    present: bool = false, // bit 0
    rw: enum(u1) { // bit 1
        read_only = 0,
        read_write = 1,
    } = .read_only,
    user: enum(u1) { // bit 2
        supervisor_only = 0,
        user_accessible = 1,
    } = .supervisor_only,
    write_through: bool = false, // bit 3
    cache_disable: bool = false, // bit 4
    accessed: bool = false, // bit 5
    dirty: bool = false, // bit 6 : ignoré sauf au niveau PT
    large_page: bool = false, // bit 7 : ignoré sauf PDPT et PD
    global: bool = false, // bit 8 : ignoré sauf PT
    _available: u3 = 0, // bits 9-11
    addr: u40 = 0, // bits 12–51
    _reserved: u11 = 0, // bits 52–62
    nx: bool = true, // bit 63
};
