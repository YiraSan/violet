// --- dependencies --- //

const std = @import("std");
const ark = @import("ark");
const builtin = @import("builtin");
const basalt = @import("basalt");

// --- imports --- //

const kernel = @import("root");

const acpi = kernel.drivers.acpi;
const mem = kernel.mem;

const exception = @import("exception.zig");
const gic = @import("gic.zig");
const generic_timer = @import("generic_timer.zig");
const psci = @import("psci.zig");

// --- aarch64/root.zig --- //

pub fn initCpus(xsdt: *acpi.Xsdt) !void {
    for (&cpus) |*cpu| cpu.* = null;

    var xsdt_iter = xsdt.iter();
    while (xsdt_iter.next()) |xsdt_entry| {
        switch (xsdt_entry) {
            .madt => |madt| {
                var madt_iter = madt.iter();
                while (madt_iter.next()) |madt_entry| {
                    switch (madt_entry) {
                        .gicc => |gicc| {
                            const mpidr: ark.cpu.armv8a_64.registers.MPIDR_EL1 = @bitCast(gicc.mpidr);
                            if (mpidr.aff1 != 0 or mpidr.aff2 != 0 or mpidr.aff3 != 0) continue;

                            const cpu_ptr: *Cpu = @ptrFromInt(kernel.hhdm_base + try mem.phys.allocContiguousPages(1, .l2M, false));
                            cpus[mpidr.aff0] = cpu_ptr;

                            cpu_ptr.mpidr = gicc.mpidr;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    var reg = ark.cpu.armv8a_64.registers.CPACR_EL1.get();
    reg.fpen = .el0_el1;
    reg.set();

    const cpu = cpus[Cpu.id()].?;
    asm volatile (
        \\ msr tpidr_el1, %[in]
        :
        : [in] "r" (cpu),
        : "memory"
    );
}

pub fn init(xsdt: *acpi.Xsdt) !void {
    try exception.init();
    try gic.init(xsdt);
    try generic_timer.init(xsdt);
    try generic_timer.enableCpu();
    try psci.init(xsdt);
}

/// takes 256*8 = 2048 bytes so less than a page, doesn't make sense to allocate dynamically until violetOS supports multi-cluster.
var cpus: [256]?*Cpu = undefined;

pub fn bootCpus() !void {
    const l0_page = try kernel.mem.phys.allocPage(.l4K, false);
    var ttbr0_space = kernel.mem.virt.Space.init(.lower, l0_page);

    const trampoline_ptr = @intFromPtr(&trampoline);
    const trampoline_page = kernel.mem.virt.kernel_space.getPage(trampoline_ptr).?;
    const trampoline_addr = trampoline_page.phys_addr | (trampoline_ptr & 0xfff);

    var res = kernel.mem.virt.Reservation{
        .space = &ttbr0_space,
        .virt = trampoline_page.phys_addr,
        .size = 1,
    };

    res.map(trampoline_page.phys_addr, .{
        .executable = true,
        .writable = true,
    }, .no_hint);

    cpu_setup_data.ttbr0 = ttbr0_space.l0_table;
    cpu_setup_data.ttbr1 = kernel.mem.virt.kernel_space.l0_table;

    cpu_setup_data.tcr = @bitCast(ark.cpu.armv8a_64.registers.TCR_EL1.get());
    cpu_setup_data.mair = @bitCast(ark.cpu.armv8a_64.registers.MAIR_EL1.get());

    cpu_setup_data.entry_virt = @intFromPtr(&initSecondary);

    for (cpus) |cpu_nptr| {
        if (cpu_nptr) |cpu| {
            if (cpu.mpidr == Cpu.id()) continue;

            cpu_setup_data.stack_top_virt = kernel.hhdm_base + try kernel.mem.phys.allocPage(.l2M, false) + mem.PageLevel.l2M.size();
            cpu_setup_data.setup_done = 0;

            asm volatile ("dsb ish ; isb" ::: "memory");

            try psci.cpuOn(cpu.mpidr, trampoline_addr, 0);

            while (cpu_setup_data.setup_done != 1) {
                asm volatile ("wfe");
                asm volatile ("dsb ish ; isb" ::: "memory");
            }
        }
    }

    // TODO free PTEs
}

extern var cpu_setup_data: extern struct {
    ttbr0: u64 align(1),
    ttbr1: u64 align(1),
    tcr: u64 align(1),
    mair: u64 align(1),
    stack_top_virt: u64 align(1),
    entry_virt: u64 align(1),
    setup_done: u64 align(1),
};

fn trampoline() align(0x1000) linksection(".data") callconv(.naked) noreturn {
    asm volatile (
        \\ ic iallu
        \\ dsb ish
        \\ isb
        \\
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
        \\ tlbi vmalle1
        \\ dsb ish
        \\ isb
        \\
        \\ mrs x7, sctlr_el1
        \\ orr x7, x7, #1 // enable MMU
        \\ msr sctlr_el1, x7
        \\
        \\ mov x7, #0
        \\ msr spsel, x7
        \\ mov sp, x5
        \\
        \\ mov x7, #1
        \\ str x7, [x0, #48]
        \\ dsb ish
        \\ sev
        \\
        \\ br x6
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
        \\    .quad 0 // setup_done
    );
}

fn initSecondary() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    var reg = ark.cpu.armv8a_64.registers.CPACR_EL1.get();
    reg.fpen = .el0_el1;
    reg.set();

    const cpu = cpus[Cpu.id()].?;
    asm volatile (
        \\ msr tpidr_el1, %[in]
        :
        : [in] "r" (cpu),
        : "memory"
    );

    mem.phys.initCpu() catch unreachable;
    kernel.boot_space.apply();

    exception.init() catch {};
    gic.initCpu(kernel.xsdt) catch unreachable;
    generic_timer.enableCpu() catch unreachable;

    kernel.scheduler.initCpu() catch unreachable;

    unmaskInterrupts();

    // jump to scheduler.
    kernel.drivers.Timer.arm(._5ms);

    while (true) {
        asm volatile ("wfi");
    }
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

// TODO move arch-independent part into arch/root.zig

pub const Cpu = struct {
    mpidr: u64,

    // -- physical memory -- //

    primary_4k_cache: [128]u64,
    primary_4k_cache_pos: usize,
    recycle_4k_cache: [128]u64,
    recycle_4k_cache_num: usize,

    // -- virtual memory -- //

    user_space: *mem.virt.Space,

    // -- scheduler -- //

    current_task: ?*kernel.scheduler.Task,

    queue_tasks: mem.Queue(*kernel.scheduler.Task),
    cycle_done: usize,

    pub fn id() usize {
        switch (builtin.cpu.arch) {
            .aarch64 => {
                const mpidr = ark.cpu.armv8a_64.registers.MPIDR_EL1.get();
                // NOTE the primary core should not even start a core from another cluster.
                if (mpidr.aff1 != 0 or mpidr.aff2 != 0 or mpidr.aff3 != 0) unreachable;
                return mpidr.aff0;
            },
            else => unreachable,
        }
    }

    pub fn get() *Cpu {
        return switch (builtin.cpu.arch) {
            .aarch64 => asm volatile (
                \\ mrs %[out], tpidr_el1
                : [out] "=r" (-> *Cpu),
            ),
            else => unreachable,
        };
    }

    comptime {
        if (@sizeOf(Cpu) > mem.PageLevel.l2M.size()) @compileError("Cpu should be less than or equal to 2 MiB.");
    }
};

pub const Context = struct {
    // operational registers
    lr: u64,
    xregs: [30]u64,
    vregs: [32]u128,
    fpcr: u64,
    fpsr: u64,
    elr_el1: u64,
    spsr_el1: ark.cpu.armv8a_64.registers.SPSR_EL1,
    tpidr_el0: ark.cpu.armv8a_64.registers.TPIDR_EL0,
    sp: u64,

    pub fn init() @This() {
        var context: @This() = undefined;
        context.lr = 0;
        @memset(&context.xregs, 0);
        @memset(&context.vregs, 0);
        context.fpcr = 0;
        context.fpsr = 0;
        context.elr_el1 = 0;
        context.spsr_el1 = .{ .mode = .el0 };
        context.tpidr_el0 = @bitCast(@as(u64, 0));
        context.sp = 0;

        return context;
    }

    pub fn setExecutionAddress(self: *@This(), address: u64) void {
        self.elr_el1 = address;
    }

    pub fn getExecutionAddress(self: *@This()) u64 {
        return self.elr_el1;
    }

    pub fn setStackPointer(self: *@This(), address: u64) void {
        self.sp = address + kernel.scheduler.Task.STACK_SIZE;
    }

    pub fn getStackPointer(self: *@This()) u64 {
        return self.sp;
    }

    pub fn setExecutionLevel(self: *@This(), execution_level: basalt.process.ExecutionLevel) void {
        self.spsr_el1.mode = switch (execution_level) {
            .kernel, .system => .el1t,
            .user => .el0,
        };
    }

    pub fn setDataContext(self: *@This(), data_context: u64) void {
        self.xregs[0] = data_context;
    }

    pub fn store(
        task: *kernel.scheduler.Task,
        arch_data: *anyopaque,
    ) void {
        const exception_ctx: *exception.ExceptionContext = @ptrCast(@alignCast(arch_data));

        task.arch_context.lr = exception_ctx.lr;
        task.arch_context.xregs = exception_ctx.xregs;
        task.arch_context.vregs = exception_ctx.vregs;
        task.arch_context.fpcr = exception_ctx.fpcr;
        task.arch_context.fpsr = exception_ctx.fpsr;
        task.arch_context.elr_el1 = exception_ctx.elr_el1;
        task.arch_context.spsr_el1 = exception_ctx.spsr_el1;

        task.arch_context.sp = exception.get_sp_el0();

        task.arch_context.tpidr_el0 = .get();
    }

    pub fn load(
        task: *kernel.scheduler.Task,
        arch_data: *anyopaque,
    ) void {
        const exception_ctx: *exception.ExceptionContext = @ptrCast(@alignCast(arch_data));

        exception_ctx.lr = task.arch_context.lr;
        exception_ctx.xregs = task.arch_context.xregs;
        exception_ctx.vregs = task.arch_context.vregs;
        exception_ctx.fpcr = task.arch_context.fpcr;
        exception_ctx.fpsr = task.arch_context.fpsr;
        exception_ctx.elr_el1 = task.arch_context.elr_el1;
        exception_ctx.spsr_el1 = task.arch_context.spsr_el1;

        exception.set_sp_el0(task.arch_context.sp);

        task.arch_context.tpidr_el0.set();
    }
};
