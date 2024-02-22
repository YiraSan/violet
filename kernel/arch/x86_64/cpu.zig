pub fn halt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
    unreachable;
}
