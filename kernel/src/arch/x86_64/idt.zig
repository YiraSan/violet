// --- imports --- //

const std = @import("std");
const log = std.log.scoped(.idt);

const kernel = @import("root");
const cpu = kernel.cpu;
const mem = kernel.mem;
const phys = mem.phys;

const gdt = @import("gdt.zig");

// --- idt.zig --- //

var interrupt_descriptor_table: [256]IDTEntry align(0x1000) = undefined;

pub fn init() void {
    const idt_ptr = IDTPtr{
        .limit = @sizeOf(@TypeOf(interrupt_descriptor_table)) - 1,
        .base = @intFromPtr(&interrupt_descriptor_table),
    };

    asm volatile (
        \\ lgdt (%[ptr])
        :
        : [ptr] "r" (&idt_ptr),
        : "memory"
    );
}

fn setEntry(index: usize, handler: u64, selector: u16, ist: u8, type_attr: IDTTypeAttr) void {
    interrupt_descriptor_table[index] = IDTEntry{
        .offset_low = @intCast(handler & 0xFFFF),
        .selector = selector,
        .ist = ist & 0b111,
        .type_attr = type_attr,
        .offset_mid = @intCast((handler >> 16) & 0xFFFF),
        .offset_high = @intCast((handler >> 32) & 0xFFFFFFFF),
        .zero = 0,
    };
}

// --- structs --- //

const IDTTypeAttr = packed struct(u8) {
    gate_type: enum(u4) { // bits 0–3
        interrupt_gate = 0b1110,
        trap_gate = 0b1111,
    } = .interrupt_gate,
    _reserved: u1 = 0, // bit 4
    dpl: u2 = 0, // bits 5–6
    present: bool = true, // bit 7
};

const IDTEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: IDTTypeAttr,
    offset_mid: u16,
    offset_high: u32,
    zero: u32,
};

const IDTPtr = packed struct {
    limit: u16,
    base: u64,
};
