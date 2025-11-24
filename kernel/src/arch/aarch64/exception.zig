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
const basalt = @import("basalt");
const ark = @import("ark");

const log = std.log.scoped(.exception);

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const syscall = kernel.syscall;
const scheduler = kernel.scheduler;

const phys = mem.phys;
const vmm = mem.vmm;

// --- aarch64/exception.zig --- //

pub fn init() !void {
    const sp_el1_stack = kernel.boot.hhdm_base + (phys.allocPage(false) catch unreachable);
    const sp_el1_stack_size = 0x1000;

    set_sp_el1(sp_el1_stack + sp_el1_stack_size);
    set_vbar_el1(@intFromPtr(&exception_vector_table));
}

// --- old --- //

extern fn set_vbar_el1(addr: u64) callconv(.{ .aarch64_aapcs = .{} }) void;

pub extern fn set_sp_el1(addr: u64) callconv(.{ .aarch64_aapcs = .{} }) void;
pub extern fn set_sp_el0(addr: u64) callconv(.{ .aarch64_aapcs = .{} }) void;

pub extern fn get_sp_el0() callconv(.{ .aarch64_aapcs = .{} }) u64;

extern const exception_vector_table: [2048]u8 linksection(".bss");

pub const ExceptionContext = extern struct {
    lr: u64,
    _: u64 = 0, // padding
    xregs: [30]u64,
    vregs: [32]u128, // TODO optimize that
    fpcr: u64,
    fpsr: u64,
    elr_el1: u64,
    spsr_el1: ark.armv8.registers.SPSR_EL1,

    pub inline fn setArg(self: *@This(), index: usize, value: u64) void {
        self.xregs[index] = value;
    }

    pub inline fn getArg(self: *@This(), index: usize) u64 {
        return self.xregs[index];
    }
};

// TODO dissociate sync_handler depending on EL0/EL1t/EL1h later
fn sync_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    kernel.arch.maskInterrupts();

    const esr_el1 = ark.armv8.registers.ESR_EL1.load();

    switch (esr_el1.ec) {
        .svc_inst_aarch64 => {
            const code = ctx.xregs[0];

            if (code < syscall.registers.len) {
                const syscall_fn_val = syscall.registers[code];
                if (syscall_fn_val != 0) {
                    const syscall_fn: syscall.SyscallFn = @ptrFromInt(syscall_fn_val);

                    ctx.xregs[0] = @bitCast(basalt.syscall.Result{
                        .is_success = false,
                        .code = @intFromEnum(basalt.syscall.ErrorCode.no_result),
                    });

                    return syscall_fn(ctx);
                }
            }

            ctx.xregs[0] = @bitCast(basalt.syscall.Result{
                .is_success = false,
                .code = @intFromEnum(basalt.syscall.ErrorCode.unknown_syscall),
            });

            return;
        },
        .data_abort_lower_el, .data_abort_same_el => {
            const far = ark.armv8.registers.loadFarEl1();
            const iss = esr_el1.iss.data_abort;

            switch (iss.dfsc) {
                .translation_fault_lv0,
                .translation_fault_lv1,
                .translation_fault_lv2,
                .translation_fault_lv3,
                => {
                    const local = scheduler.Local.get();

                    if (local.current_task) |current_task| {
                        const vs = current_task.process.virtualSpace();

                        const res = vs.resolveFault(far) catch |err| switch (err) {
                            vmm.Space.Error.SegmentationFault => {
                                log.err("segmentation fault from task {}:{} at address 0x{x}", .{ current_task.process.id.index, current_task.id.index, far });

                                scheduler.terminateTask(ctx);

                                return;
                            },
                            else => unreachable,
                        };

                        vs.paging.map(
                            far,
                            res.phys_addr,
                            1,
                            switch (iss.dfsc) {
                                .translation_fault_lv0 => unreachable,
                                .translation_fault_lv1 => .l1G,
                                .translation_fault_lv2 => .l2M,
                                .translation_fault_lv3 => .l4K,
                                else => unreachable,
                            },
                            res.flags,
                        ) catch |err| {
                            log.err("failed to commit on 0x{x} at task {}:{}, {}", .{ far, current_task.process.id.index, current_task.id.index, err });
                            ark.cpu.halt();
                        };

                        return;
                    } else {
                        log.err("DataAbort({s}) from {s} on 0x{x}", .{ @tagName(iss.dfsc), @tagName(ctx.spsr_el1.mode), far });
                    }
                },
                else => {
                    log.err("DataAbort({s}) from {s} on 0x{x}", .{ @tagName(iss.dfsc), @tagName(ctx.spsr_el1.mode), far });
                    @panic("unimplemented data abort exception");
                },
            }
        },
        .brk_aarch64 => {
            const iss = esr_el1.iss.brk_aarch64;

            log.debug("Breakpoint({}) from {s} at address 0x{x}", .{ iss.comment, @tagName(ctx.spsr_el1.mode), ctx.elr_el1 });

            ctx.elr_el1 += 4;
            return;
        },
        else => {
            log.err("UNEXPECTED SYNCHRONOUS EXCEPTION from {s}", .{@tagName(ctx.spsr_el1.mode)});
            esr_el1.dump();
        },
    }

    ark.cpu.halt();
}

const gic = @import("gic.zig");

pub const IrqCallback = *const fn (ctx: *ExceptionContext) void;
pub var irq_callbacks: [1024]?IrqCallback linksection(".bss") = undefined;

fn irq_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    kernel.arch.maskInterrupts();

    const irq_id = gic.acknowledge();

    if (irq_id >= 1023) {
        log.warn("Spurious IRQ received (no valid source)", .{});
    } else if (irq_callbacks[irq_id]) |callback| {
        callback(ctx);
    } else {
        log.warn("Unhandled IRQ ID: {}", .{irq_id});
    }

    gic.endOfInterrupt(irq_id);
}

fn fiq_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    log.err("UNEXPECTED FIQ from {s}", .{@tagName(ctx.spsr_el1.mode)});
    ark.cpu.armv8a_64.registers.ESR_EL1.get().dump();
    ark.cpu.halt();
}

fn serror_handler(ctx: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    log.err("UNEXPECTED SERROR from {s}", .{@tagName(ctx.spsr_el1.mode)});
    ark.cpu.armv8a_64.registers.ESR_EL1.get().dump();
    ark.cpu.halt();
}

export const el1t_sync = sync_handler;
export const el1t_irq = irq_handler;
export const el1t_fiq = unexpected_exception;
export const el1t_serror = unexpected_exception;

export const el1h_sync = sync_handler;
export const el1h_irq = irq_handler;
export const el1h_fiq = unexpected_exception;
export const el1h_serror = unexpected_exception;

export const el0_sync = sync_handler;
export const el0_irq = irq_handler;
export const el0_fiq = unexpected_exception;
export const el0_serror = unexpected_exception;

fn unexpected_exception(_: *ExceptionContext) callconv(.{ .aarch64_aapcs = .{} }) void {
    log.err("unexpected exception", .{});
    ark.armv8.registers.ESR_EL1.load().dump();
    ark.cpu.halt();
}

comptime {
    _ = el1t_sync;
    _ = el1t_irq;
    _ = el1t_fiq;
    _ = el1t_serror;

    _ = el1h_sync;
    _ = el1h_irq;
    _ = el1h_fiq;
    _ = el1h_serror;

    _ = el0_sync;
    _ = el0_irq;
    _ = el0_fiq;
    _ = el0_serror;
}
