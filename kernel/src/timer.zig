// --- timer.zig --- //

const gic_v2 = @import("gic_v2.zig");

/// Reads the current system counter frequency from CNTFRQ_EL0.
fn read_cntfrq_el0() u64 {
    var val: u64 = undefined;
    asm volatile (
        \\ mrs %[out], cntfrq_el0
        : [out] "=r" (val),
        :
        : "memory"
    );
    return val;
}

/// Writes a value to CNTP_TVAL_EL0 (Timer Value Register).
fn write_cntp_tval_el0(val: u64) void {
    asm volatile (
        \\ msr cntp_tval_el0, %[in]
        :
        : [in] "r" (val),
        : "memory"
    );
}

/// Writes a value to CNTP_CTL_EL0 (Timer Control Register).
/// Bit 0 = enable, Bit 1 = imask, Bit 2 = ISTATUS (read-only).
fn write_cntp_ctl_el0(val: u32) void {
    asm volatile (
        \\ msr cntp_ctl_el0, %[in]
        :
        : [in] "r" (val),
        : "memory"
    );
}

/// Enables IRQ exceptions by clearing the IRQ bit in DAIF.
fn unmask_irqs() void {
    asm volatile (
        \\ msr DAIFClr, #0b0010
        ::: "memory");
}

/// Initializes the generic timer to trigger IRQs every 100ms.
pub fn init() void {
    const freq = read_cntfrq_el0();
    const interval = freq / 10; // 100ms

    write_cntp_tval_el0(interval); // Load initial timer interval
    write_cntp_ctl_el0(0b0001); // Enable timer (bit 0 = enable)
    unmask_irqs(); // Unmask IRQ exceptions globally
}

/// Acknowledges the timer interrupt and re-arms it.
pub fn ack() void {
    write_cntp_ctl_el0(0); // Disable timer before reloading
    const freq = read_cntfrq_el0();
    const interval = freq / 10;

    write_cntp_tval_el0(interval); // Set next interval
    write_cntp_ctl_el0(0b0001); // Re-enable timer
}