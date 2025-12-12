// Copyright (c) 2024-2025 The violetOS Authors
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

pub const extend_frame = exception.extend_frame;

comptime {
    _ = exception;
    _ = gic;
    _ = generic_timer;
    _ = psci;
}

// --- aarch64/root.zig --- //

pub fn initCpus() !void {
    for (&kernel.arch.cpus) |*cpu| cpu.* = null;

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

                            const cpu_ptr: *kernel.arch.Cpu = @ptrFromInt(kernel.boot.hhdm_base + try mem.phys.allocContiguous(64, true));
                            kernel.arch.cpus[mpidr.aff0] = cpu_ptr;
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

    const cpu = kernel.arch.Cpu.getCpu(kernel.arch.Cpu.id());
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

// NOTE I know that there's a lot of potential memory leaks there, don't worry.
pub fn bootCpus() !void {
    if (comptime build_options.platform == .rpi4) return;

    const pfr0 = ark.armv8.registers.ID_AA64PFR0_EL1.load();

    const trampoline_ptr = if (pfr0.el2 == .not_implemented) @intFromPtr(&trampoline_el1) else @intFromPtr(&trampoline_el2);
    const trampoline_page = kernel.mem.vmm.kernel_space.paging.get(trampoline_ptr).?;
    const trampoline_addr = trampoline_page.phys_addr | (trampoline_ptr & 0xfff);

    var setup_data: SetupData = undefined;

    if (pfr0.el2 == .not_implemented) {
        var ttbr0_space = try kernel.mem.vmm.Space.init(.lower, null, false);

        try ttbr0_space.paging.map(
            trampoline_page.phys_addr,
            trampoline_page.phys_addr,
            1,
            .l4K,
            .{ .executable = true },
        );

        setup_data.level_specific.el1.ttbr0_el1 = ttbr0_space.paging.table_phys;

        var tcr_el1 = ark.armv8.registers.TCR_EL1.load();
        tcr_el1.epd0 = false;
        setup_data.tcr_el1 = tcr_el1;
    } else {
        setup_data.level_specific.el2.spsr_el2 = ark.armv8.registers.SPSR_EL2{
            .mode = .el1t,
            .d = false,
            .a = false,
            .i = true,
            .f = true,
        };

        setup_data.level_specific.el2.hcr_el2 = ark.armv8.registers.HCR_EL2{
            .rw = .el1_is_aa64,
        };

        setup_data.tcr_el1 = ark.armv8.registers.TCR_EL1.load();
    }

    setup_data.mair_el1 = ark.armv8.registers.MAIR_EL1.load();
    setup_data.sctlr_el1 = ark.armv8.registers.SCTLR_EL1.load();
    setup_data.ttbr1_el1 = kernel.mem.vmm.kernel_space.paging.table_phys;
    setup_data.entry_virt = @intFromPtr(&cpu_entry);

    for (kernel.arch.cpus) |cpu_nptr| {
        if (cpu_nptr) |cpu| {
            if (cpu.cpuid == kernel.arch.Cpu.id()) continue;

            const setup_data_phys = try mem.phys.allocPage(true);
            const setup_data_virt: *SetupData = @ptrFromInt(kernel.boot.hhdm_base + setup_data_phys);

            setup_data_virt.* = setup_data;
            setup_data_virt.stack_top_virt = kernel.boot.hhdm_base + try kernel.mem.phys.allocContiguous(64, false) + mem.PageLevel.l4K.size() * 64;

            cleanCache(@intFromPtr(setup_data_virt), @sizeOf(SetupData));

            try psci.cpuOn(cpu.cpuid, trampoline_addr, setup_data_phys);
        }
    }
}

pub fn cleanCache(virt_start: u64, size: usize) void {
    var i: usize = 0;
    while (i < size) : (i += 64) {
        asm volatile ("dc cvac, %[addr]"
            :
            : [addr] "r" (virt_start + i),
        );
    }

    asm volatile ("dsb ish");
}

const SetupData = extern struct {
    tcr_el1: ark.armv8.registers.TCR_EL1, // offset 0
    mair_el1: ark.armv8.registers.MAIR_EL1, // offset 8
    sctlr_el1: ark.armv8.registers.SCTLR_EL1, // offset 16

    ttbr1_el1: u64, // offset 24

    stack_top_virt: u64, // offset 32
    entry_virt: u64, // offset 40

    level_specific: extern union {
        el1: extern struct {
            ttbr0_el1: u64, // offset 48
        },
        el2: extern struct {
            hcr_el2: ark.armv8.registers.HCR_EL2, // offset 48
            spsr_el2: ark.armv8.registers.SPSR_EL2, // offset 56
        },
    },

    comptime {
        if (@sizeOf(SetupData) > 0x1000) @compileError("SetupData should be less than 4 KiB");
    }
};

fn trampoline_el1() align(0x1000) callconv(.naked) noreturn {
    asm volatile (
        \\ msr daifset, #0b1111
        \\ isb
        \\
        \\ ic iallu
        \\ dsb ish
        \\
        \\ ldr x1, [x0, #0] // tcr_el1
        \\ ldr x2, [x0, #8] // mair_el1
        \\ ldr x3, [x0, #16] // sctlr_el1
        \\ 
        \\ ldr x4, [x0, #24] // ttbr1_el1
        \\
        \\ ldr x5, [x0, #32] // stack_top_virt
        \\ ldr x6, [x0, #40] // entry_virt
        \\
        \\ ldr x7, [x0, #48] // ttbr0_el1
        \\
        \\ msr tcr_el1, x1
        \\ msr mair_el1, x2
        \\ msr ttbr0_el1, x7
        \\ msr ttbr1_el1, x4
        \\
        \\ dsb ish
        \\ isb
        \\
        \\ msr sctlr_el1, x3
        \\ isb
        \\
        \\ mov x9, #0
        \\ msr spsel, x9
        \\ mov sp, x5
        \\
        \\ br x6
    );
}

fn trampoline_el2() align(0x1000) callconv(.naked) noreturn {
    asm volatile (
        \\ msr daifset, #0b1111
        \\ isb
        \\
        \\ ic iallu
        \\ dsb ish
        \\
        \\ ldr x1, [x0, #0] // tcr_el1
        \\ ldr x2, [x0, #8] // mair_el1
        \\ ldr x3, [x0, #16] // sctlr_el1
        \\ 
        \\ ldr x4, [x0, #24] // ttbr1_el1
        \\
        \\ ldr x5, [x0, #32] // stack_top_virt
        \\ ldr x6, [x0, #40] // entry_virt
        \\
        \\ ldr x7, [x0, #48] // hcr_el2
        \\ ldr x8, [x0, #56] // spsr_el2
        \\
        \\ msr tcr_el1, x1
        \\ msr mair_el1, x2
        \\ msr ttbr1_el1, x4
        \\ msr sctlr_el1, x3
        \\ msr hcr_el2, x7
        \\ msr spsr_el2, x8
        \\ msr elr_el2, x6
        \\
        \\ dsb ish
        \\ isb
        \\
        \\ msr sp_el0, x5
        \\
        \\ eret
    );
}

fn cpu_entry() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    var reg = ark.armv8.registers.CPACR_EL1.load();
    reg.fpen = .el0_el1;
    reg.store();

    const cpu = kernel.arch.Cpu.getCpu(kernel.arch.Cpu.id());
    asm volatile (
        \\ msr tpidr_el1, %[in]
        :
        : [in] "r" (cpu),
        : "memory"
    );

    mem.phys.initCpu() catch unreachable;
    exception.init() catch unreachable;
    gic.initCpu() catch unreachable;
    generic_timer.enableCpu() catch unreachable;
    kernel.scheduler.initCpu() catch unreachable;
    kernel.drivers.Timer.initCpu() catch unreachable;

    kernel.drivers.Timer.arm(1 * std.time.ns_per_ms);
    unmaskInterrupts();
    ark.cpu.halt();
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

pub const ExceptionData = struct {
    spsr_el1: ark.armv8.registers.SPSR_EL1,

    pub fn init(self: *ExceptionData, task: *kernel.scheduler.Task) void {
        self.* = ExceptionData{ .spsr_el1 = .{
            .mode = switch (task.process.execution_level) {
                .system, .module => .el1t,
                .user => .el0,
            },
        } };
    }

    pub fn save(self: *ExceptionData) void {
        self.* = ExceptionData{
            .spsr_el1 = .load(),
        };
    }

    pub fn restore(self: *ExceptionData) void {
        self.spsr_el1.store();
    }
};

pub const GeneralFrame = extern struct {
    xregs: [30]u64, // x0..x29
    link_register: u64, // x30
    program_counter: u64,
    tpidr_el0: u64,
    stack_pointer: u64,

    pub fn setArg(self: *GeneralFrame, comptime index: usize, value: u64) void {
        self.xregs[index] = value;
    }

    pub fn getArg(self: *GeneralFrame, comptime index: usize) u64 {
        return self.xregs[index];
    }
};

pub const ExtendedFrame = extern struct {
    qregs: [32]u128, // q0..q31
    fpcr: u64,
    fpsr: u64,
    general_frame: GeneralFrame,
};
