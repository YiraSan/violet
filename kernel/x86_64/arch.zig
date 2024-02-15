pub fn idle() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}
