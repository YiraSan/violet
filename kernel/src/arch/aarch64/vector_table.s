sync_entry:
    stp x0, x1, [sp, #-16]!
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    stp x6, x7, [sp, #-16]!
    stp x8, x9, [sp, #-16]!
    stp x10, x11, [sp, #-16]!
    stp x12, x13, [sp, #-16]!
    stp x14, x15, [sp, #-16]!
    stp x16, x17, [sp, #-16]!
    stp x18, x19, [sp, #-16]!
    stp x20, x21, [sp, #-16]!
    stp x22, x23, [sp, #-16]!
    stp x24, x25, [sp, #-16]!
    stp x26, x27, [sp, #-16]!
    stp x28, x29, [sp, #-16]!
    mrs x0, SP_EL0
    stp x30, x0, [sp, #-16]!
    mov x0, sp
    mrs x18, TPIDR_EL1
    .extern sync_handler
    bl sync_handler

    mrs x0, SPSR_EL1
    and w0, w0, #0x200000
    cbz w0, _sync_cont
    mrs x0, MDSCR_EL1
    orr x0, x0, #1
    msr MDSCR_EL1, x0
    _sync_cont:

    ldp x30, x0, [sp], #16
    msr SP_EL0, x0
    ldp x28, x29, [sp], #16
    ldp x26, x27, [sp], #16
    ldp x24, x25, [sp], #16
    ldp x22, x23, [sp], #16
    ldp x20, x21, [sp], #16
    ldp x18, x19, [sp], #16
    ldp x16, x17, [sp], #16
    ldp x14, x15, [sp], #16
    ldp x12, x13, [sp], #16
    ldp x10, x11, [sp], #16
    ldp x8, x9, [sp], #16
    ldp x6, x7, [sp], #16
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ldp x0, x1, [sp], #16
    eret

fault_entry:
    stp x0, x1, [sp, #-16]!
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    stp x6, x7, [sp, #-16]!
    stp x8, x9, [sp, #-16]!
    stp x10, x11, [sp, #-16]!
    stp x12, x13, [sp, #-16]!
    stp x14, x15, [sp, #-16]!
    stp x16, x17, [sp, #-16]!
    stp x18, x19, [sp, #-16]!
    stp x20, x21, [sp, #-16]!
    stp x22, x23, [sp, #-16]!
    stp x24, x25, [sp, #-16]!
    stp x26, x27, [sp, #-16]!
    stp x28, x29, [sp, #-16]!
    mrs x0, SP_EL0
    stp x30, x0, [sp, #-16]!
    mov x0, sp
    mrs x18, TPIDR_EL1
    .extern fault_handler
    bl fault_handler
    ldp x30, x0, [sp], #16
    msr SP_EL0, x0
    ldp x28, x29, [sp], #16
    ldp x26, x27, [sp], #16
    ldp x24, x25, [sp], #16
    ldp x22, x23, [sp], #16
    ldp x20, x21, [sp], #16
    ldp x18, x19, [sp], #16
    ldp x16, x17, [sp], #16
    ldp x14, x15, [sp], #16
    ldp x12, x13, [sp], #16
    ldp x10, x11, [sp], #16
    ldp x8, x9, [sp], #16
    ldp x6, x7, [sp], #16
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ldp x0, x1, [sp], #16
    eret

irq_entry:
    stp x0, x1, [sp, #-16]!
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    stp x6, x7, [sp, #-16]!
    stp x8, x9, [sp, #-16]!
    stp x10, x11, [sp, #-16]!
    stp x12, x13, [sp, #-16]!
    stp x14, x15, [sp, #-16]!
    stp x16, x17, [sp, #-16]!
    stp x18, x19, [sp, #-16]!
    stp x20, x21, [sp, #-16]!
    stp x22, x23, [sp, #-16]!
    stp x24, x25, [sp, #-16]!
    stp x26, x27, [sp, #-16]!
    stp x28, x29, [sp, #-16]!
    mrs x0, SP_EL0
    stp x30, x0, [sp, #-16]!
    mov x0, sp
    mrs x18, TPIDR_EL1
    .extern irq_handler
    bl irq_handler
    mrs x0, SPSR_EL1
    and w0, w0, #0x200000
    cbz w0, _irq_cont
    mrs x0, MDSCR_EL1
    orr x0, x0, #1
    msr MDSCR_EL1, x0
    _irq_cont:
    ldp x30, x0, [sp], #16
    msr SP_EL0, x0
    ldp x28, x29, [sp], #16
    ldp x26, x27, [sp], #16
    ldp x24, x25, [sp], #16
    ldp x22, x23, [sp], #16
    ldp x20, x21, [sp], #16
    ldp x18, x19, [sp], #16
    ldp x16, x17, [sp], #16
    ldp x14, x15, [sp], #16
    ldp x12, x13, [sp], #16
    ldp x10, x11, [sp], #16
    ldp x8, x9, [sp], #16
    ldp x6, x7, [sp], #16
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ldp x0, x1, [sp], #16
    eret

.globl _vector_table
.balign 0x800
_vector_table:

/* EL1-SP0 */
_exc_sp0_sync:
    b sync_entry /* this will be removed, since EL1 won't be  */
.balign 0x80
_exc_sp0_irq:
    b .
.balign 0x80
_exc_sp0_fiq:
    b .
.balign 0x80
_exc_sp0_serror:
    b .

/* EL1-EL1 */
.balign 0x80
_exc_spx_sync:
    b fault_entry
.balign 0x80
_exc_spx_irq:
    b .
.balign 0x80
_exc_spx_fiq:
    b .
.balign 0x80
_exc_spx_serror:
    b .

/* EL0-EL1 */
.balign 0x80
_exc_lower_sync:
    b sync_entry
.balign 0x80
_exc_lower_irq:
    b irq_entry
.balign 0x80
_exc_lower_fiq:
    b .
.balign 0x80
_exc_lower_serror:
    b .

/* 32-bit is unused */
.balign 0x80
_exc_lower_32_sync:
    b .
.balign 0x80
_exc_lower_32_irq:
    b .
.balign 0x80
_exc_lower_32_fiq:
    b .
.balign 0x80
_exc_lower_32_serror:
    b .
