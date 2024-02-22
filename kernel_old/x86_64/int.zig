pub inline fn is_enabled() bool {
    const eflags = asm volatile (
        \\pushf
        \\pop %[result]
        : [result] "=r" (-> u64),
    );

    return ((eflags & 0x200) != 0);
}

pub inline fn enable() void {
    asm volatile ("sti");
}

pub inline fn disable() void {
    asm volatile ("cli");
}
