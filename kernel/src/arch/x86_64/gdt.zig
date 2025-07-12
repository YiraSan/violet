// --- imports --- //

const std = @import("std");
const log = std.log.scoped(.gdt);

const kernel = @import("root");
const cpu = kernel.cpu;
const mem = kernel.mem;
const phys = mem.phys;

// --- gdt.zig --- //

var global_descriptor_table: [8]GDTEntry align(0x1000) = undefined;

const IST_STACK_SIZE = 4096 * 5; // 20 KiB

var ist1_stack: [IST_STACK_SIZE]u8 align(0x1000) linksection(".bss") = undefined;

var tss: TSS align(16) = undefined;

extern fn gdt_update(gdt_ptr: *GDTPtr) callconv(.c) void;

pub fn init() void {
    global_descriptor_table[1] = GDT_KERNEL_CODE;
    global_descriptor_table[2] = GDT_KERNEL_DATA;
    global_descriptor_table[4] = GDT_USER_DATA;
    global_descriptor_table[5] = GDT_USER_CODE;

    // TODO define rsp0
    tss = .{
        .ist1 = @intFromPtr(&ist1_stack) + IST_STACK_SIZE,
    };

    @as(*GDTTSSEntry, @ptrCast(&global_descriptor_table[6])).* = makeGDTTSSEntry(@intFromPtr(&tss));

    var gdt_ptr = GDTPtr{
        .limit = @sizeOf(@TypeOf(global_descriptor_table)) - 1,
        .base = @intFromPtr(&global_descriptor_table),
    };

    gdt_update(&gdt_ptr);

    // asm volatile (
    //     \\ movw $0x30, %ax
    //     \\ ltr %ax
    //     ::: "memory"
    // );
}

fn makeGDTTSSEntry(tss_addr: usize) GDTTSSEntry {
    return GDTTSSEntry{
        .length = @sizeOf(TSS),
        .base_low = @intCast(tss_addr & 0xffff),
        .base_middle = @intCast((tss_addr >> 16) & 0xff),
        .flags0 = 0b10001001,
        .flags1 = 0,
        .base_high = @intCast((tss_addr >> 24) & 0xff),
        .base_upper = @intCast(tss_addr >> 32),
        ._reserved = 0,
    };
}

fn makeGDTEntry(base: u32, limit: u32, access: GDTEntryAccess, flags: GDTEntryFlags) GDTEntry {
    return GDTEntry{
        .limit_low = @intCast(limit & 0xFFFF),
        .base_low = @intCast(base & 0xFFFF),
        .base_middle = @intCast((base >> 16) & 0xFF),
        .access = access,
        .limit_high = @intCast((limit >> 16) & 0xF),
        .flags = flags,
        .base_high = @intCast((base >> 24) & 0xFF),
    };
}

// --- structs --- //

const GDTTSSEntry = packed struct {
    length: u16,
    base_low: u16,
    base_middle: u16,
    flags0: u8,
    flags1: u8,
    base_high: u8,
    base_upper: u32,
    _reserved: u32,
};

const TSS = packed struct {
    _reserved0: u32 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    rsp3: u64 = 0,
    _reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    _reserved2: u64 = 0,
    _reserved3: u16 = 0,
    iopb_offset: u16 = 0,
};

const GDTEntryAccess = packed struct(u8) {
    accessed: u1,
    readable_writable: u1,
    conforming_expand_down: u1,
    executable: u1,
    descriptor_type: u1,
    dpl: u2,
    present: u1,
};

const GDTEntryFlags = packed struct(u4) {
    available: u1,
    long_mode: u1,
    default_op_size: u1,
    granularity: u1,
};

const GDTEntry = packed struct(u64) {
    limit_low: u16,
    base_low: u16,
    base_middle: u8,
    access: GDTEntryAccess,
    limit_high: u4,
    flags: GDTEntryFlags,
    base_high: u8,
};

const GDTPtr = packed struct {
    limit: u16,
    base: u64,
};

// --- GDT entries --- //

const GDT_KERNEL_CODE = makeGDTEntry(0, 0, .{
    .accessed = 1,
    .readable_writable = 1,
    .conforming_expand_down = 0,
    .executable = 1,
    .descriptor_type = 1,
    .dpl = 0,
    .present = 1,
}, .{
    .available = 0,
    .long_mode = 1,
    .default_op_size = 0,
    .granularity = 1,
});

const GDT_KERNEL_DATA = makeGDTEntry(0, 0, .{
    .accessed = 1,
    .readable_writable = 1,
    .conforming_expand_down = 0,
    .executable = 0,
    .descriptor_type = 1,
    .dpl = 0,
    .present = 1,
}, .{
    .available = 0,
    .long_mode = 0,
    .default_op_size = 1,
    .granularity = 1,
});

const GDT_USER_DATA = makeGDTEntry(0, 0, .{
    .accessed = 1,
    .readable_writable = 1,
    .conforming_expand_down = 0,
    .executable = 0,
    .descriptor_type = 1,
    .dpl = 3,
    .present = 1,
}, .{
    .available = 0,
    .long_mode = 0,
    .default_op_size = 0,
    .granularity = 1,
});

const GDT_USER_CODE = makeGDTEntry(0, 0, .{
    .accessed = 1,
    .readable_writable = 1,
    .conforming_expand_down = 0,
    .executable = 1,
    .descriptor_type = 1,
    .dpl = 3,
    .present = 1,
}, .{
    .available = 0,
    .long_mode = 1,
    .default_op_size = 0,
    .granularity = 1,
});
