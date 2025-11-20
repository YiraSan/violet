// Copyright (c) 2025 The violetOS authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// --- dependencies --- //

const std = @import("std");
const ark = @import("ark");
const builtin = @import("builtin");
const build_options = @import("build_options");
const basalt = @import("basalt");

// --- imports --- //

const kernel = @import("root");

const acpi = kernel.drivers.acpi;
const mem = kernel.mem;

const exception = @import("exception.zig");
const gic = @import("gic.zig");
const generic_timer = @import("generic_timer.zig");
const psci = @import("psci.zig");

comptime {
    _ = exception;
    _ = gic;
    _ = generic_timer;
    _ = psci;
}

// --- aarch64/root.zig --- //

pub fn initCpus() !void {
    for (&cpus) |*cpu| cpu.* = null;

    var gicc_found = false;
    var xsdt_iter = kernel.boot.xsdt.iter();
    while (xsdt_iter.next()) |xsdt_entry| {
        switch (xsdt_entry) {
            .madt => |madt| {
                var madt_iter = madt.iter();
                while (madt_iter.next()) |madt_entry| {
                    switch (madt_entry) {
                        .gicc => |gicc| {
                            gicc_found = true;

                            const mpidr: ark.armv8.registers.MPIDR_EL1 = @bitCast(gicc.mpidr);
                            if (mpidr.aff1 != 0 or mpidr.aff2 != 0 or mpidr.aff3 != 0) continue;

                            const cpu_ptr: *kernel.arch.Cpu = @ptrFromInt(kernel.boot.hhdm_base + try mem.phys.allocContiguousPages(1, .l2M, false));
                            cpus[mpidr.aff0] = cpu_ptr;
                            cpu_ptr.cpuid = gicc.mpidr;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    if (!gicc_found) asm volatile ("brk #0"); // TODO brk so it produces a visible exception for QEMU

    const cpu = cpus[kernel.arch.Cpu.id()].?;
    asm volatile (
        \\ msr tpidr_el1, %[in]
        :
        : [in] "r" (cpu),
        : "memory"
    );
}

pub fn init() !void {
    try exception.init();
    try gic.init();
    try generic_timer.init();
    try generic_timer.enableCpu();
    try psci.init();
}

/// takes 256*8 = 2048 bytes so less than a page, doesn't make sense to allocate dynamically until violetOS supports multi-cluster.
var cpus: [256]?*kernel.arch.Cpu align(@alignOf(u128)) = undefined;

pub fn bootCpus() !void {
    if (build_options.platform == .rpi4) return;

    const pfr0 = ark.armv8.registers.ID_AA64PFR0_EL1.load();

    const l0_page = try kernel.mem.phys.allocPage(.l4K, false);
    var ttbr0_space = kernel.mem.virt.Space.init(.lower, l0_page);

    const trampoline_ptr = if (pfr0.el2 == .not_implemented) @intFromPtr(&trampoline_el1) else @intFromPtr(&trampoline_el2);
    const trampoline_page = kernel.mem.virt.kernel_space.getPage(trampoline_ptr).?;
    const trampoline_addr = trampoline_page.phys_addr | (trampoline_ptr & 0xfff);

    if (pfr0.el2 == .not_implemented) {
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

        var tcr_el1 = ark.armv8.registers.TCR_EL1.load();
        tcr_el1.epd0 = false;
        cpu_setup_data.tcr = @bitCast(tcr_el1);
    } else {
        cpu_setup_data.ttbr0 = @bitCast(ark.armv8.registers.SPSR_EL2{
            .mode = .el1t,
            .d = false,
            .a = false,
            .i = true,
            .f = true,
        });

        cpu_setup_data.hcr_el2 = @bitCast(ark.armv8.registers.HCR_EL2{
            .rw = .el1_is_aa64,
        });

        cpu_setup_data.tcr = @bitCast(ark.armv8.registers.TCR_EL1.load());
    }

    cpu_setup_data.mair = @bitCast(ark.armv8.registers.MAIR_EL1.load());

    cpu_setup_data.sctlr_el1 = @bitCast(ark.armv8.registers.SCTLR_EL1.load());

    cpu_setup_data.ttbr1 = kernel.mem.virt.kernel_space.l0_table;

    cpu_setup_data.entry_virt = @intFromPtr(&initSecondary);

    for (cpus) |cpu_nptr| {
        if (cpu_nptr) |cpu| {
            if (cpu.cpuid == kernel.arch.Cpu.id()) continue;

            cpu_setup_data.stack_top_virt = kernel.boot.hhdm_base + try kernel.mem.phys.allocPage(.l2M, false) + mem.PageLevel.l2M.size();
            cpu_setup_data.setup_done = 0;

            asm volatile ("dsb ish ; isb" ::: "memory");

            try psci.cpuOn(cpu.cpuid, trampoline_addr, 0);

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
    hcr_el2: u64 align(1),
    sctlr_el1: u64 align(1),
};

fn trampoline_el1() align(0x1000) linksection(".data") callconv(.naked) noreturn {
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
        \\ ldr x8, [x0, #64] // sctlr_el1
        \\
        \\ msr mair_el1, x4
        \\ msr tcr_el1, x3
        \\ msr ttbr0_el1, x1
        \\ msr ttbr1_el1, x2
        \\ dsb ish
        \\ isb
        \\
        \\ tlbi vmalle1
        \\ dsb ish
        \\ isb
        \\
        \\ msr sctlr_el1, x8
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
        \\    .quad 0 // ttbr0 / spsr_el2
        \\    .quad 0 // ttbr1
        \\    .quad 0 // tcr
        \\    .quad 0 // mair
        \\    .quad 0 // stack_top_virt
        \\    .quad 0 // entry_virt
        \\    .quad 0 // setup_done
        \\    .quad 0 // hcr_el2
        \\    .quad 0 // sctlr_el1
    );
}

fn trampoline_el2() linksection(".data") callconv(.naked) noreturn {
    asm volatile (
        \\ ic iallu
        \\ dsb ish
        \\ isb
        \\
        \\ adr x0, cpu_setup_data
        \\ ldr x1, [x0, #0]  // spsr_el2
        \\ ldr x2, [x0, #8]  // ttbr1
        \\ ldr x3, [x0, #16] // tcr
        \\ ldr x4, [x0, #24] // mair
        \\ ldr x5, [x0, #32] // stack_top_virt
        \\ ldr x6, [x0, #40] // entry_virt
        \\ ldr x7, [x0, #56] // hcr_el2
        \\ ldr x8, [x0, #64] // sctlr_el1
        \\
        \\ msr spsr_el2, x1
        \\ msr ttbr1_el1, x2
        \\ msr tcr_el1,  x3
        \\ msr mair_el1, x4
        \\ msr sp_el0, x5
        \\ msr elr_el2, x6
        \\ msr hcr_el2, x7
        \\ msr sctlr_el1, x8
        \\ dsb ish
        \\ isb
        \\
        \\ tlbi vmalle1
        \\ dsb ish
        \\ isb
        \\
        \\ mov x8, #1
        \\ str x8, [x0, #48]
        \\ dsb ish
        \\ sev
        \\
        \\ eret
    );
}

fn initSecondary() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    var reg = ark.armv8.registers.CPACR_EL1.load();
    reg.fpen = .el0_el1;
    reg.store();

    const cpu = cpus[kernel.arch.Cpu.id()].?;
    asm volatile (
        \\ msr tpidr_el1, %[in]
        :
        : [in] "r" (cpu),
        : "memory"
    );

    mem.phys.initCpu() catch unreachable;
    exception.init() catch {};
    gic.initCpu() catch unreachable;
    generic_timer.enableCpu() catch unreachable;
    kernel.prism.initCpu() catch unreachable;
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
        \\ msr daifset, #0b0011
        \\ isb
    );
}

pub fn unmaskInterrupts() void {
    asm volatile (
        \\ msr daifclr, #0b0011
        \\ isb
    );
}

pub fn maskAndSave() u64 {
    return asm volatile (
        \\ mrs %[flags], daif
        \\ msr daifset, #0b0011
        : [flags] "=r" (-> u64),
        :
        : "memory"
    );
}

pub fn restoreSaved(saved: u64) void {
    asm volatile (
        \\ msr daif, %[flags]
        :
        : [flags] "r" (saved),
        : "memory"
    );
}

// TODO move arch-independent part into arch/root.zig

pub const ExceptionContext = exception.ExceptionContext;

pub const TaskContext = struct {
    // operational registers
    lr: u64,
    xregs: [30]u64,
    vregs: [32]u128,
    fpcr: u64,
    fpsr: u64,
    elr_el1: u64,
    spsr_el1: ark.armv8.registers.SPSR_EL1,
    tpidr_el0: u64,
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
            .kernel => .el1t,
            .user => .el0,
        };
    }

    pub fn setDataContext(self: *@This(), data_context: u64) void {
        self.xregs[0] = data_context;
    }

    pub fn store(
        task: *kernel.scheduler.Task,
        exception_ctx: *kernel.arch.ExceptionContext,
    ) void {
        task.arch_context.lr = exception_ctx.lr;
        task.arch_context.xregs = exception_ctx.xregs;
        task.arch_context.vregs = exception_ctx.vregs;
        task.arch_context.fpcr = exception_ctx.fpcr;
        task.arch_context.fpsr = exception_ctx.fpsr;
        task.arch_context.elr_el1 = exception_ctx.elr_el1;
        task.arch_context.spsr_el1 = exception_ctx.spsr_el1;

        task.arch_context.sp = exception.get_sp_el0();

        task.arch_context.tpidr_el0 = ark.armv8.registers.loadTpidrEL0();
    }

    pub fn load(
        task: *kernel.scheduler.Task,
        exception_ctx: *kernel.arch.ExceptionContext,
    ) void {
        exception_ctx.lr = task.arch_context.lr;
        exception_ctx.xregs = task.arch_context.xregs;
        exception_ctx.vregs = task.arch_context.vregs;
        exception_ctx.fpcr = task.arch_context.fpcr;
        exception_ctx.fpsr = task.arch_context.fpsr;
        exception_ctx.elr_el1 = task.arch_context.elr_el1;
        exception_ctx.spsr_el1 = task.arch_context.spsr_el1;

        exception.set_sp_el0(task.arch_context.sp);

        ark.armv8.registers.storeTpidrEL0(task.arch_context.tpidr_el0);
    }
};
