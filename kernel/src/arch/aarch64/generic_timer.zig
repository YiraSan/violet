// --- dependencies --- //

const std = @import("std");
const basalt = @import("basalt");

// --- imports --- //

const gic = @import("gic.zig");
const exception = @import("exception.zig");

const kernel = @import("root");

const acpi = kernel.drivers.acpi;
const Timer = kernel.drivers.Timer;

// --- generic_timer.zig --- //

var gsiv: u32 = undefined;

pub fn init(xsdt: *acpi.Xsdt) !void {
    var xsdt_iter = xsdt.iter();
    xsdt_loop: while (xsdt_iter.next()) |xsdt_entry| {
        switch (xsdt_entry) {
            .gtdt => |gtdt| {
                if (gtdt.el1_non_secure_gsiv == 0) @panic("EL1 Non-Secure GENERIC TIMER not found.");

                exception.irq_callbacks[gtdt.el1_non_secure_gsiv] = &callback;

                gsiv = gtdt.el1_non_secure_gsiv;

                Timer.selected_timer = .generic_timer;

                break :xsdt_loop;
            },
            else => {},
        }
    }
}

pub fn enableCpu() !void {
    gic.enableIRQ(gsiv);
}

pub fn disableCpu() !void {
    gic.disableIRQ(gsiv);
}

fn callback(ctx: *exception.ExceptionContext) void {
    disable();
    kernel.scheduler.acknowledgeTimer(ctx);
}

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

pub inline fn arm(delay: basalt.timer.Delay) void {
    disable();

    const freq = read_cntfrq_el0();
    const interval = switch (delay) {
        ._100ms => freq / 10,
        ._50ms => freq / 20,
        ._10ms => freq / 100,
        ._5ms => freq / 200,
        ._1ms => freq / 1000,
        ._0_5ms => freq / 2000,
    };

    write_cntp_tval_el0(interval);

    enable();
}

pub inline fn enable() void {
    write_cntp_ctl_el0(0b0001);
}

pub inline fn disable() void {
    write_cntp_ctl_el0(0);
}
