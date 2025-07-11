.globl gdt_update
gdt_update:
    lgdt (%rdi)
    mov $0x10, %ax
    mov %ax, %ss
    mov %ax, %ds
    mov %ax, %es

    leaq .trampoline(%rip), %rax

    pushq $0x8
    pushq %rax
    lretq

.trampoline:
    ret