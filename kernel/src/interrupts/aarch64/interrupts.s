.section .text

// --- set_sp_el1 --- //

    .global set_sp_el1
    .type set_sp_el1, %function
set_sp_el1:
    mov x1, #1
    msr spsel, x1
    isb

    mov sp, x0
    isb

    mov x1, #0
    msr spsel, x1
    isb

    ret

// --- set_vbar_el1 --- //

    .global set_vbar_el1
    .type set_vbar_el1, %function

set_vbar_el1:
    msr vbar_el1, x0
    isb

    ret

// --- exception_vector_table --- //

.equ CONTEXT_SIZE, 264

.macro EXCEPTION_HANDLER handler
    sub sp, sp, #CONTEXT_SIZE

    stp x0, x1, [sp, #16 * 0]
    stp x2, x3, [sp, #16 * 1]
    stp x4, x5, [sp, #16 * 2]
    stp x6, x7, [sp, #16 * 3]
    stp x8, x9, [sp, #16 * 4]
    stp x10, x11, [sp, #16 * 5]
    stp x12, x13, [sp, #16 * 6]
    stp x14, x15, [sp, #16 * 7]
    stp x16, x17, [sp, #16 * 8]
    stp x18, x19, [sp, #16 * 9]
    stp x20, x21, [sp, #16 * 10]
    stp x22, x23, [sp, #16 * 11]
    stp x24, x25, [sp, #16 * 12]
    stp x26, x27, [sp, #16 * 13]
    stp x28, x29, [sp, #16 * 14]

    mrs x0, elr_el1
    mrs x1, spsr_el1
    stp x0, x1, [sp, #16 * 15]

    str x30, [sp, #16 * 16]

    mov x0, sp
    bl \handler

    b .exit_exception
.endm

.balign 0x800
.globl exception_vector_table
exception_vector_table:

_el1t_sync:
    EXCEPTION_HANDLER el1t_sync
.balign 0x80
_el1t_irq:
    EXCEPTION_HANDLER el1t_irq
.balign 0x80
_el1t_fiq:
    EXCEPTION_HANDLER el1t_fiq
.balign 0x80
_el1t_serror:
    EXCEPTION_HANDLER el1t_serror

.balign 0x80
_el1h_sync:
    EXCEPTION_HANDLER el1h_sync
.balign 0x80
_el1h_irq:
    EXCEPTION_HANDLER el1h_irq
.balign 0x80
_el1h_fiq:
    EXCEPTION_HANDLER el1h_fiq
.balign 0x80
_el1h_serror:
    EXCEPTION_HANDLER el1h_serror

.balign 0x80
_el0_sync:
    EXCEPTION_HANDLER el0_sync
.balign 0x80
_el0_irq:
    EXCEPTION_HANDLER el0_irq
.balign 0x80
_el0_fiq:
    EXCEPTION_HANDLER el0_fiq
.balign 0x80
_el0_serror:
    EXCEPTION_HANDLER el0_serror

.balign 0x80
_el0_32_sync:
    b .
.balign 0x80
_el0_32_irq:
    b .
.balign 0x80
_el0_32_fiq:
    b .
.balign 0x80
_el0_32_serror:
    b .
.balign 0x80

.exit_exception:
    ldr x30, [sp, #16 * 16]

    ldp x0, x1, [sp, #16 * 15]
    msr elr_el1, x0
    msr spsr_el1, x1

    ldp x28, x29, [sp, #16 * 14]
    ldp x26, x27, [sp, #16 * 13]
    ldp x24, x25, [sp, #16 * 12]
    ldp x22, x23, [sp, #16 * 11]
    ldp x20, x21, [sp, #16 * 10]
    ldp x18, x19, [sp, #16 * 9]
    ldp x16, x17, [sp, #16 * 8]
    ldp x14, x15, [sp, #16 * 7]
    ldp x12, x13, [sp, #16 * 6]
    ldp x10, x11, [sp, #16 * 5]
    ldp x8, x9, [sp, #16 * 4]
    ldp x6, x7, [sp, #16 * 3]
    ldp x4, x5, [sp, #16 * 2]
    ldp x2, x3, [sp, #16 * 1]
    ldp x0, x1, [sp, #16 * 0]

    add sp, sp, #CONTEXT_SIZE
    eret
