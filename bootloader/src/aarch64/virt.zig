// --- dependencies --- //

const std = @import("std");
const build_options = @import("build_options");

const uefi = std.os.uefi;
const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;

const ark = @import("ark");

const Entry = ark.armv8.stage1_pagging.Entry;
const TableDescriptor = ark.armv8.stage1_pagging.TableDescriptor;
const BlockPageDescriptor = ark.armv8.stage1_pagging.BlockPageDescriptor;

// --- imports --- //

const bootloader = @import("root");

const mmap = bootloader.mmap;
const phys = bootloader.phys;
const virt = bootloader.virt;

// --- aarch64/virt.zig --- //

pub fn init(_: *uefi.tables.BootServices) void {
    configureMAIR();
    configureTCR();

    virt.table = phys.allocPages(1);
}

fn configureMAIR() void {
    const mair_el1 = ark.armv8.registers.MAIR_EL1{
        .attr0 = ark.armv8.registers.MAIR_EL1.DEVICE_nGnRnE,
        .attr1 = ark.armv8.registers.MAIR_EL1.NORMAL_NONCACHEABLE,
        .attr2 = ark.armv8.registers.MAIR_EL1.NORMAL_WRITETHROUGH_NONTRANSIENT,
        .attr3 = ark.armv8.registers.MAIR_EL1.NORMAL_WRITEBACK_NONTRANSIENT,
    };
    mair_el1.store();

    asm volatile (
        \\ dsb ish
        \\ dsb sy
        \\ isb
    );
}

fn configureTCR() void {
    const mmfr0 = ark.armv8.registers.ID_AA64MMFR0_EL1.load();
    const currentEL = asm volatile ("mrs %[out], currentEL"
        : [out] "=r" (-> u64),
    );

    var tcr_el1 = ark.armv8.registers.TCR_EL1{
        .t0sz = 16,
        .epd0 = if (currentEL == 0b0100) false else true,
        .irgn0 = .wb_ra_wa,
        .orgn0 = .wb_ra_wa,
        .sh0 = .inner_shareable,
        .tg0 = .@"4kb",

        .a1 = .ttbr0_el1,

        .t1sz = 16,
        .epd1 = false,
        .irgn1 = .wb_ra_wa,
        .orgn1 = .wb_ra_wa,
        .sh1 = .inner_shareable,
        .tg1 = .@"4kb",

        .ips = switch (build_options.platform) {
            .rpi4 => .@"40bits_1tb",
            else => switch (mmfr0.pa_range) {
                .@"32bits_4gb" => .@"32bits_4gb",
                .@"36bits_64gb" => .@"36bits_64gb",
                .@"40bits_1tb" => .@"40bits_1tb",
                .@"42bits_4tb" => .@"42bits_4tb",
                .@"44bits_16tb" => .@"44bits_16tb",
                .@"48bits_256tb" => .@"48bits_256tb",
                .@"52bits_4pb" => .@"52bits_4pb",
                .@"56bits_64pb" => .@"56bits_64pb",
            }
        },

        .tbi0 = .used,
        .tbi1 = .used,
    };

    tcr_el1.store();

    const idmm3 = ark.armv8.registers.ID_AA64MMFR3_EL1.load();
    if (idmm3.s1pie == .supported) {
        var tcr2 = ark.armv8.registers.TCR2_EL1.load();
        tcr2.pie = false;
        tcr2.store();
    }

    asm volatile (
        \\ dsb sy
        \\ dsb ish
        \\ isb
    );
}

// --- impl --- //

pub fn mapPage(
    l0_table: u64,
    virt_addr: u64,
    phys_addr: u64,
    page_level: virt.PageLevel,
    flags: virt.MemoryFlags,
) void {
    const l0 = (virt_addr >> 39) & 0x1FF;
    const l1 = (virt_addr >> 30) & 0x1FF;
    const l2 = (virt_addr >> 21) & 0x1FF;
    const l3 = (virt_addr >> 12) & 0x1FF;

    const bpd = BlockPageDescriptor.build(phys_addr, flags, 0);

    var tp = l0_table;
    tp = ensure_table(tp, l0);

    switch (page_level) {
        .l1G => {
            const p: *Entry = @ptrFromInt(tp + l1 * 8);
            if (p.valid and p.not_a_block) {
                free_table_recursive(p.descriptor.table.next_level_table << 12, 1);
            }

            p.* = .{
                .valid = true,
                .not_a_block = false,
                .descriptor = .{
                    .block_page = bpd,
                },
            };
        },
        .l2M => {
            tp = ensure_table(tp, l1);
            const p: *Entry = @ptrFromInt(tp + l2 * 8);
            if (p.valid and p.not_a_block) {
                free_table_recursive(p.descriptor.table.next_level_table << 12, 2);
            }

            p.* = .{
                .valid = true,
                .not_a_block = false,
                .descriptor = .{
                    .block_page = bpd,
                },
            };
        },
        .l4K => {
            tp = ensure_table(tp, l1);
            tp = ensure_table(tp, l2);
            const p: *Entry = @ptrFromInt(tp + l3 * 8);

            p.* = .{
                .valid = true,
                .not_a_block = true,
                .descriptor = .{
                    .block_page = bpd,
                },
            };
        },
    }

    asm volatile (
        \\ dsb sy
        \\ isb
    );
}

fn get_table(table_addr: u64, index: u64) ?u64 {
    const entry: *Entry = @ptrFromInt(table_addr + index * 8);

    if (entry.valid and entry.not_a_block) {
        return entry.descriptor.table.next_level_table << 12;
    }

    return null;
}

fn ensure_table(table_addr: u64, index: u64) u64 {
    const entry: *Entry = @ptrFromInt(table_addr + index * 8);

    if (entry.valid and entry.not_a_block) {
        return entry.descriptor.table.next_level_table << 12;
    }

    const new_table = phys.allocPages(1);

    entry.* = Entry{
        .valid = true,
        .not_a_block = true,
        .descriptor = .{
            .table = .{
                .next_level_table = @truncate(new_table >> 12),
            },
        },
    };

    return new_table;
}

pub fn free_table_recursive(table_addr: u64, level: u8) void {
    for (0..512) |i| {
        const e_ptr: *Entry = @ptrFromInt(table_addr + i * 8);
        const entry = e_ptr.*;

        if (!entry.valid) continue;

        if (entry.not_a_block and level != 3) {
            free_table_recursive(entry.descriptor.table.next_level_table << 12, level + 1);
        } else {
            phys.freePages(entry.descriptor.block_page.output_address << 12, 1);
        }
    }

    phys.freePages(table_addr, 1);
}
