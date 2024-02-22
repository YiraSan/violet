pub fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
    unreachable;
}
