pub fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
    unreachable;
}

/// stall the current core for a given number of cycles
pub fn wait(count: usize) void {
    for (0..count) |_| {
        asm volatile ("mov w0, w0");
    }
}
