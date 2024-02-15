pub fn idle() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}
