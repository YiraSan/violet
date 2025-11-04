// --- dependencies --- //

const std = @import("std");
const ark = @import("ark");

// --- imports --- //

const kernel = @import("root");

const acpi = kernel.drivers.acpi;

const exception = @import("exception.zig");
const gic = @import("gic.zig");
const generic_timer = @import("generic_timer.zig");
const psci = @import("psci.zig");

// --- aarch64/root.zig --- //

pub fn init(xsdt: *acpi.Xsdt) !void {
    try exception.init();
    try gic.init(xsdt);
    try generic_timer.init(xsdt);
    try psci.init(xsdt);

    const l0_page = kernel.mem.phys.alloc_page(.l4K, false) catch unreachable;
    var ttbr0_space = kernel.mem.virt.Space.init(.lower, l0_page);

    const trampoline_ptr = @intFromPtr(&trampoline);
    const trampoline_page = kernel.mem.virt.kernel_space.getPage(trampoline_ptr).?;
    const trampoline_addr = trampoline_page.phys_addr | (trampoline_ptr & 0xfff);

    var res = kernel.mem.virt.Reservation {
        .space = &ttbr0_space,
        .virt = trampoline_page.phys_addr,
        .size = 1,
    };

    res.map(trampoline_page.phys_addr, .{
        .executable = true,
    });

    cpu_setup_data.ttbr0 = ttbr0_space.l0_table;
    cpu_setup_data.ttbr1 = kernel.mem.virt.kernel_space.l0_table;

    cpu_setup_data.tcr = @bitCast(ark.cpu.armv8a_64.registers.TCR_EL1.get());
    cpu_setup_data.mair = @bitCast(ark.cpu.armv8a_64.registers.MAIR_EL1.get());

    cpu_setup_data.entry_virt = @intFromPtr(&cpuMain);
    
    for (1..2) |_| {
        cpu_setup_data.stack_top_virt = kernel.hhdm_base + (kernel.mem.phys.alloc_page(.l4K, false) catch unreachable);    
        psci.cpuOn(1, trampoline_addr, 0) catch unreachable;
    }
}

export fn cpuMain() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    var reg = ark.cpu.armv8a_64.registers.CPACR_EL1.get();
    reg.fpen = .el0_el1;
    reg.set();

    exception.init() catch {};

    std.log.info("hello from a secondary cpu !!", .{});

    asm volatile("brk #0");

    while (true) {}
}

extern var cpu_setup_data: extern struct {
    ttbr0: u64 align(1),
    ttbr1: u64 align(1),
    tcr: u64 align(1),
    mair: u64 align(1),
    stack_top_virt: u64 align(1),
    entry_virt: u64 align(1),
};

/// the alignment is necessary to make sure that everything is on one single page.
/// 
/// the linksection is `.data` (read-write) in the higher-half mapping, in the lower-half identity mapping this is read-execute mapped (technically not even a thing because this is read outside the MMU).
fn trampoline() align(0x1000) linksection(".data") callconv(.naked) noreturn {
    asm volatile (
        \\ adr x0, cpu_setup_data
        \\ ldr x1, [x0, #0]  // ttbr0
        \\ ldr x2, [x0, #8]  // ttbr1
        \\ ldr x3, [x0, #16] // tcr
        \\ ldr x4, [x0, #24] // mair
        \\ ldr x5, [x0, #32] // stack_top_virt
        \\ ldr x6, [x0, #40] // entry_virt
        \\
        \\ msr mair_el1, x4
        \\ msr tcr_el1,  x3
        \\ msr ttbr0_el1, x1
        \\ msr ttbr1_el1, x2
        \\ dsb ish
        \\ isb
        \\
        \\ mrs x7, sctlr_el1
        \\ orr x7, x7, #1 // enable MMU
        \\ msr sctlr_el1, x7
        \\
        \\ dsb ish
        \\ tlbi vmalle1
        \\ dsb ish
        \\ isb
        \\
        \\ mov x7, #0
        \\ msr spsel, x7
        \\ mov sp, x5
        \\
        \\ br x6
        \\
        \\ halt:
        \\    wfi
        \\    b halt
        \\
        \\ .align 3
        \\ .global cpu_setup_data
        \\ cpu_setup_data:
        \\    .quad 0 // ttbr0
        \\    .quad 0 // ttbr1
        \\    .quad 0 // tcr
        \\    .quad 0 // mair
        \\    .quad 0 // stack_top_virt
        \\    .quad 0 // entry_virt
    );
}

pub fn maskInterrupts() void {
    asm volatile (
        \\ msr daifset, #0b1111
        \\ isb
    );
}

pub fn unmaskInterrupts() void {
    asm volatile (
        \\ msr daifclr, #0b1111
        \\ isb
    );
}

pub const ProcessContext = struct {};

pub const TaskContext = struct {
    // operational registers
    lr: u64,
    xregs: [30]u64,
    vregs: [32]u128,
    fpcr: u64,
    fpsr: u64,
    elr_el1: u64,
    spsr_el1: ark.cpu.armv8a_64.registers.SPSR_EL1,
    sp: u64,
};

pub fn storeContext(
    arch_data: *anyopaque,
    process_ctx: ?*kernel.arch.ProcessContext,
    task_ctx: ?*kernel.arch.TaskContext,
) void {
    const exception_ctx: *exception.ExceptionContext = @ptrCast(@alignCast(arch_data));

    if (process_ctx) |process| {
        _ = process;
    }

    if (task_ctx) |task| {
        task.lr = exception_ctx.lr;
        task.xregs = exception_ctx.xregs;
        task.vregs = exception_ctx.vregs;
        task.fpcr = exception_ctx.fpcr;
        task.fpsr = exception_ctx.fpsr;
        task.elr_el1 = exception_ctx.elr_el1;
        task.spsr_el1 = exception_ctx.spsr_el1;

        task.sp = exception.get_sp_el0();
    }
}

pub fn loadContext(
    arch_data: *anyopaque,
    process_ctx: ?*kernel.arch.ProcessContext,
    task_ctx: ?*kernel.arch.TaskContext,
) void {
    const exception_ctx: *exception.ExceptionContext = @ptrCast(@alignCast(arch_data));

    if (process_ctx) |process| {
        _ = process;
    }

    if (task_ctx) |task| {
        exception_ctx.lr = task.lr;
        exception_ctx.xregs = task.xregs;
        exception_ctx.vregs = task.vregs;
        exception_ctx.fpcr = task.fpcr;
        exception_ctx.fpsr = task.fpsr;
        exception_ctx.elr_el1 = task.elr_el1;
        exception_ctx.spsr_el1 = task.spsr_el1;

        exception.set_sp_el0(task.sp);
    }
}
