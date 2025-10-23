.section .text

// --- set_sp_el0 --- // USED FROM SP_EL1

    .global set_sp_el0
    .type set_sp_el0, %function
set_sp_el0:
    mov x1, #0
    msr spsel, x1
    isb

    mov sp, x0
    isb

    mov x1, #1
    msr spsel, x1

    dsb sy
    isb

    ret

// --- set_sp_el1 --- // USED FROM SP_EL0

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

    dsb sy
    isb

    ret

// --- set_vbar_el1 --- //

    .global set_vbar_el1
    .type set_vbar_el1, %function

set_vbar_el1:
    msr vbar_el1, x0
    dsb sy
    isb

    ret

// --- exception_vector_table --- //

// TODO make q0-q31 used only if FP/NEON trap
// NOTE SVE isn't implemented currently; it needs a 128 alignment for the stack!

.equ CONTEXT_SIZE, 800

prepare_exception:
    stp x0, x1, [sp, #16 * 1]
    stp x2, x3, [sp, #16 * 2]
    stp x4, x5, [sp, #16 * 3]
    stp x6, x7, [sp, #16 * 4]
    stp x8, x9, [sp, #16 * 5]
    stp x10, x11, [sp, #16 * 6]
    stp x12, x13, [sp, #16 * 7]
    stp x14, x15, [sp, #16 * 8]
    stp x16, x17, [sp, #16 * 9]
    stp x18, x19, [sp, #16 * 10]
    stp x20, x21, [sp, #16 * 11]
    stp x22, x23, [sp, #16 * 12]
    stp x24, x25, [sp, #16 * 13]
    stp x26, x27, [sp, #16 * 14]
    stp x28, x29, [sp, #16 * 15]

    str q0, [sp, #16 * 16]
    str q1, [sp, #16 * 17]
    str q2, [sp, #16 * 18]
    str q3, [sp, #16 * 19]
    str q4, [sp, #16 * 20]
    str q5, [sp, #16 * 21]
    str q6, [sp, #16 * 22]
    str q7, [sp, #16 * 23]
    str q8, [sp, #16 * 24]
    str q9, [sp, #16 * 25]
    str q10, [sp, #16 * 26]
    str q11, [sp, #16 * 27]
    str q12, [sp, #16 * 28]
    str q13, [sp, #16 * 29]
    str q14, [sp, #16 * 30]
    str q15, [sp, #16 * 31]
    str q16, [sp, #16 * 32]
    str q17, [sp, #16 * 33]
    str q18, [sp, #16 * 34]
    str q19, [sp, #16 * 35]
    str q20, [sp, #16 * 36]
    str q21, [sp, #16 * 37]
    str q22, [sp, #16 * 38]
    str q23, [sp, #16 * 39]
    str q24, [sp, #16 * 40]
    str q25, [sp, #16 * 41]
    str q26, [sp, #16 * 42]
    str q27, [sp, #16 * 43]
    str q28, [sp, #16 * 44]
    str q29, [sp, #16 * 45]
    str q30, [sp, #16 * 46]
    str q31, [sp, #16 * 47]

    mrs x0, fpcr
    str x0, [sp, #(16 * 48) + 0]

    mrs x0, fpsr
    str x0, [sp, #(16 * 48) + 8]

    mrs x0, elr_el1
    str x0, [sp, #(16 * 49) + 0]

    mrs x0, spsr_el1
    str x0, [sp, #(16 * 49) + 8]

    ret

exit_exception:
    ldr x0, [sp, #(16 * 49) + 8]
    msr spsr_el1, x0

    ldr x0, [sp, #(16 * 49) + 0]
    msr elr_el1, x0

    ldr x0, [sp, #(16 * 48) + 8]
    msr fpsr, x0

    ldr x0, [sp, #(16 * 48) + 0]
    msr fpcr, x0

    ldr q31, [sp, #16 * 47]
    ldr q30, [sp, #16 * 46]
    ldr q29, [sp, #16 * 45]
    ldr q28, [sp, #16 * 44]
    ldr q27, [sp, #16 * 43]
    ldr q26, [sp, #16 * 42]
    ldr q25, [sp, #16 * 41]
    ldr q24, [sp, #16 * 40]
    ldr q23, [sp, #16 * 39]
    ldr q22, [sp, #16 * 38]
    ldr q21, [sp, #16 * 37]
    ldr q20, [sp, #16 * 36]
    ldr q19, [sp, #16 * 35]
    ldr q18, [sp, #16 * 34]
    ldr q17, [sp, #16 * 33]
    ldr q16, [sp, #16 * 32]
    ldr q15, [sp, #16 * 31]
    ldr q14, [sp, #16 * 30]
    ldr q13, [sp, #16 * 29]
    ldr q12, [sp, #16 * 28]
    ldr q11, [sp, #16 * 27]
    ldr q10, [sp, #16 * 26]
    ldr q9, [sp, #16 * 25]
    ldr q8, [sp, #16 * 24]
    ldr q7, [sp, #16 * 23]
    ldr q6, [sp, #16 * 22]
    ldr q5, [sp, #16 * 21]
    ldr q4, [sp, #16 * 20]
    ldr q3, [sp, #16 * 19]
    ldr q2, [sp, #16 * 18]
    ldr q1, [sp, #16 * 17]
    ldr q0, [sp, #16 * 16]

    ldp x28, x29, [sp, #16 * 15]
    ldp x26, x27, [sp, #16 * 14]
    ldp x24, x25, [sp, #16 * 13]
    ldp x22, x23, [sp, #16 * 12]
    ldp x20, x21, [sp, #16 * 11]
    ldp x18, x19, [sp, #16 * 10]
    ldp x16, x17, [sp, #16 * 9]
    ldp x14, x15, [sp, #16 * 8]
    ldp x12, x13, [sp, #16 * 7]
    ldp x10, x11, [sp, #16 * 6]
    ldp x8, x9, [sp, #16 * 5]
    ldp x6, x7, [sp, #16 * 4]
    ldp x4, x5, [sp, #16 * 3]
    ldp x2, x3, [sp, #16 * 2]
    ldp x0, x1, [sp, #16 * 1]

    ldr x30, [sp, #16 * 0]

    add sp, sp, #CONTEXT_SIZE
    eret

.macro EXCEPTION_HANDLER handler
    sub sp, sp, #CONTEXT_SIZE

    str x30, [sp, #16 * 0] // bl clobbers x30
    bl prepare_exception

    mov x0, sp
    bl \handler

    b exit_exception
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
