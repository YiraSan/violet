// Copyright (c) 2024-2025 The violetOS authors
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

const arch = kernel.arch;
const mem = kernel.mem;
const syscall = kernel.syscall;
const scheduler = kernel.scheduler;

const heap = mem.heap;
const phys = mem.phys;
const vmm = mem.vmm;

// --- aarch64/exception.zig --- //

pub extern fn extend_frame(frame: *arch.GeneralFrame) callconv(.{ .aarch64_aapcs = .{} }) *arch.ExtendedFrame;

extern fn restore_general_via_eret(frame: *arch.GeneralFrame, kernel_stack_reset: u64) callconv(.{ .aarch64_aapcs = .{} }) noreturn;
extern fn restore_extended_via_eret(frame: *arch.ExtendedFrame, kernel_stack_reset: u64) callconv(.{ .aarch64_aapcs = .{} }) noreturn;

extern fn restore_general_via_ret(frame: *arch.GeneralFrame, kernel_stack_reset: u64) callconv(.{ .aarch64_aapcs = .{} }) noreturn;
extern fn restore_extended_via_ret(frame: *arch.ExtendedFrame, kernel_stack_reset: u64) callconv(.{ .aarch64_aapcs = .{} }) noreturn;

export fn internal_entry(frame: *arch.GeneralFrame) callconv(.{ .aarch64_aapcs = .{} }) void {
    const sched_local = scheduler.Local.get();

    if (sched_local.current_task) |current_task| {
        current_task.exception = false;
        current_task.suspended = false;
        current_task.is_extended = false;

        current_task.stack_pointer = .{
            .general = frame,
        };
    }
}

export fn internal_exit(old_frame: *arch.GeneralFrame) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    const cpu = arch.Cpu.get();
    const kernel_stack_top = cpu.kernel_stack_top;

    const sched_local = scheduler.Local.get();

    if (sched_local.current_task) |current_task| {
        ark.armv8.registers.storeTpidrroEl0(current_task.kernel_locals_userland);

        if (current_task.exception) {
            if (current_task.is_extended) {
                _ = @as(*volatile arch.ExtendedFrame, @ptrCast(current_task.stack_pointer.extended)).*;
                current_task.exception_data.restore();
                restore_extended_via_eret(current_task.stack_pointer.extended, kernel_stack_top);
            } else {
                _ = @as(*volatile arch.GeneralFrame, @ptrCast(current_task.stack_pointer.general)).*;
                current_task.exception_data.restore();
                restore_general_via_eret(current_task.stack_pointer.general, kernel_stack_top);
            }
        } else {
            if (current_task.is_extended) {
                restore_extended_via_ret(current_task.stack_pointer.extended, kernel_stack_top);
            } else {
                restore_general_via_ret(current_task.stack_pointer.general, kernel_stack_top);
            }
        }
    } else {
        restore_general_via_ret(old_frame, kernel_stack_top);
    }
}

extern fn call_system(_: basalt.syscall.Code, _: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(.{ .aarch64_aapcs = .{} }) void;

pub fn init() !void {
    const cpu = arch.Cpu.get();

    const kernel_stack = @intFromPtr(try heap.allocContiguous(64));
    const kernel_stack_size = 0x1000 * 64;

    cpu.kernel_stack_top = kernel_stack + kernel_stack_size;

    ark.armv8.registers.storeSpEl1(cpu.kernel_stack_top);
    ark.armv8.registers.storeVbarEl1(@intFromPtr(&exception_vector_table));

    syscall.kernel_indirection_table.call_system = @ptrCast(&call_system);

    asm volatile (
        \\ dsb sy
        \\ isb
    );
}

extern const exception_vector_table: [2048]u8 linksection(".text");

inline fn saveFrameToTask(frame: *arch.GeneralFrame, saved_spsr: ark.armv8.registers.SPSR_EL1) void {
    const sched_local = scheduler.Local.get();

    if (sched_local.current_task) |current_task| {
        current_task.exception = true;
        current_task.suspended = false;
        current_task.is_extended = false;

        current_task.exception_data.save(saved_spsr);

        current_task.stack_pointer = .{
            .general = frame,
        };
    }
}

inline fn getCurrentFrame(old_frame: *arch.GeneralFrame) *arch.GeneralFrame {
    const sched_local = scheduler.Local.get();

    if (sched_local.current_task) |current_task| {
        if (current_task.is_extended) {
            return &current_task.stack_pointer.extended.general_frame;
        } else {
            return current_task.stack_pointer.general;
        }
    } else {
        return old_frame;
    }
}

inline fn exitException(old_frame: *arch.GeneralFrame, spsr: ark.armv8.registers.SPSR_EL1) noreturn {
    const sched_local = scheduler.Local.get();

    const cpu = arch.Cpu.get();
    const kernel_stack_top = cpu.kernel_stack_top;

    arch.maskInterrupts();

    if (sched_local.current_task) |current_task| {
        ark.armv8.registers.storeTpidrroEl0(current_task.kernel_locals_userland);

        // NOTE reading the frame before the restore makes sure no nested exception overwrites the SPSR.
        if (current_task.is_extended) {
            _ = @as(*volatile arch.ExtendedFrame, @ptrCast(current_task.stack_pointer.extended)).*;
            current_task.exception_data.restore();
            restore_extended_via_eret(current_task.stack_pointer.extended, kernel_stack_top);
        } else {
            _ = @as(*volatile arch.GeneralFrame, @ptrCast(current_task.stack_pointer.general)).*;
            current_task.exception_data.restore();
            restore_general_via_eret(current_task.stack_pointer.general, kernel_stack_top);
        }
    } else {
        spsr.store(); // NOTE that allows for nested exceptions to occur outside a task without overwritting the SPSR.
        restore_general_via_eret(old_frame, kernel_stack_top);
    }
}

fn sync_handler(old_frame: *arch.GeneralFrame, saved_spsr: ark.armv8.registers.SPSR_EL1) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    arch.maskInterrupts();

    saveFrameToTask(old_frame, saved_spsr);

    const esr_el1 = ark.armv8.registers.ESR_EL1.load();

    switch (esr_el1.ec) {
        .svc_inst_aarch64 => {
            kernel.syscall.internal_call_system(old_frame);
        },
        .data_abort_lower_el, .data_abort_same_el, .inst_abort_lower_el, .inst_abort_same_el => {
            const iss = esr_el1.iss.data_abort;
            const far = ark.armv8.registers.loadFarEl1();

            switch (iss.dfsc) {
                .translation_fault_lv0,
                .translation_fault_lv1,
                .translation_fault_lv2,
                .translation_fault_lv3,
                => {
                    const local = scheduler.Local.get();
                    const vs = if (local.current_task) |current_task| current_task.process.virtualSpace() else &vmm.kernel_space;

                    const res = vs.resolveFault(far) catch |err| switch (err) {
                        vmm.Space.Error.SegmentationFault => {
                            if (local.current_task) |current_task| {
                                log.err("segmentation fault from task {}:{} at address 0x{x}", .{ current_task.process.id.index, current_task.id.index, far });

                                scheduler.process_terminate(old_frame) catch {};
                                exitException(old_frame, saved_spsr);
                            } else {
                                log.err("segmentation fault from kernel at address 0x{x}", .{far});
                            }
                            ark.cpu.halt();
                        },
                        else => unreachable,
                    };

                    vs.paging.map(
                        far,
                        res.phys_addr,
                        1,
                        .l4K,
                        res.flags,
                    ) catch |err| {
                        log.err("failed to commit on 0x{x}, {}", .{ far, err });
                        ark.cpu.halt();
                    };

                    mem.vmm.invalidate(far, .l4K);
                },
                else => {
                    log.err("DataAbort({s}) on 0x{x}", .{ @tagName(iss.dfsc), far });
                    @panic("unimplemented data abort exception");
                },
            }
        },
        .brk_aarch64 => {
            const frame = getCurrentFrame(old_frame);

            const iss = esr_el1.iss.brk_aarch64;
            log.debug("Breakpoint({}) at address 0x{x}", .{ iss.comment, frame.program_counter });

            frame.program_counter += 4;
        },
        else => {
            log.err("UNEXPECTED SYNCHRONOUS EXCEPTION\n{}", .{old_frame});
            esr_el1.dump();
            ark.cpu.halt();
        },
    }

    exitException(old_frame, saved_spsr);
}

const gic = @import("gic.zig");

pub const IrqCallback = *const fn () void;
pub var irq_callbacks: [1022]?IrqCallback = .{null} ** 1022;

fn irq_handler(old_frame: *arch.GeneralFrame, saved_spsr: ark.armv8.registers.SPSR_EL1) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    arch.maskInterrupts();

    const sched_local = scheduler.Local.get();
    const begin_uptime = kernel.drivers.Timer.getUptime();
    const begin_task = sched_local.current_task;

    saveFrameToTask(old_frame, saved_spsr);

    const irq_id = gic.acknowledge();

    if (irq_id >= 1023) {
        log.warn("Spurious IRQ received (no valid source)", .{});
    } else if (irq_callbacks[irq_id]) |callback| {
        callback();
    } else {
        log.warn("Unhandled IRQ ID: {}", .{irq_id});
    }

    if (irq_id < 1023) gic.endOfInterrupt(irq_id);

    const elapsed = kernel.drivers.Timer.getUptime() - begin_uptime;

    if (begin_task) |task| {
        task.uptime_schedule += elapsed;
    }

    // log.debug("IRQ on cpu{} elapsed time: {} ns", .{ kernel.arch.Cpu.id(), elapsed });

    exitException(old_frame, saved_spsr);
}

// when an exception happens inside of an handler :p
fn nested_sync_handler(esr_el1: ark.armv8.registers.ESR_EL1, far_el1: u64) callconv(.{ .aarch64_aapcs = .{} }) void {
    arch.maskInterrupts();

    switch (esr_el1.ec) {
        .data_abort_same_el, .data_abort_lower_el => {
            const iss = esr_el1.iss.data_abort;

            switch (iss.dfsc) {
                .translation_fault_lv0,
                .translation_fault_lv1,
                .translation_fault_lv2,
                .translation_fault_lv3,
                => {
                    const local = scheduler.Local.get();
                    const vs = if (far_el1 >= 0xffff_8000_0000_0000) &vmm.kernel_space else if (local.current_task) |current_task| current_task.process.virtualSpace() else &vmm.kernel_space;

                    const res = vs.resolveFault(far_el1) catch |err| switch (err) {
                        vmm.Space.Error.SegmentationFault => {
                            if (local.current_task) |current_task| {
                                log.err("nested segmentation fault from task {}:{} at address 0x{x}", .{ current_task.process.id.index, current_task.id.index, far_el1 });

                                scheduler.process_terminate(undefined) catch {};
                                if (local.current_task != null) {
                                    exitException(undefined, undefined);
                                }
                            } else {
                                log.err("nested segmentation fault from kernel at address 0x{x}", .{far_el1});
                            }
                            ark.cpu.halt();
                        },
                        else => unreachable,
                    };

                    vs.paging.map(
                        far_el1,
                        res.phys_addr,
                        1,
                        .l4K,
                        res.flags,
                    ) catch |err| {
                        log.err("failed to commit on 0x{x}, {}", .{ far_el1, err });
                        ark.cpu.halt();
                    };
                },
                else => {
                    log.err("Nested::DataAbort({s}) on 0x{x}", .{ @tagName(iss.dfsc), far_el1 });
                    ark.cpu.halt();
                },
            }
        },
        else => {
            log.err("UNEXPECTED NESTED SYNCHRONOUS EXCEPTION", .{});
            esr_el1.dump();
            ark.cpu.halt();
        },
    }
}

export const el1t_sync = sync_handler;
export const el1t_irq = irq_handler;
export const el1t_fiq = unexpected_exception;
export const el1t_serror = unexpected_exception;

export const el1h_sync = nested_sync_handler;
export const el1h_irq = unexpected_nested_exception;
export const el1h_fiq = unexpected_nested_exception;
export const el1h_serror = unexpected_nested_exception;

export const el0_sync = sync_handler;
export const el0_irq = irq_handler;
export const el0_fiq = unexpected_exception;
export const el0_serror = unexpected_exception;

fn unexpected_exception(_: *arch.GeneralFrame, _: ark.armv8.registers.SPSR_EL1) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    log.err("unexpected exception", .{});
    ark.armv8.registers.ESR_EL1.load().dump();
    ark.cpu.halt();
}

fn unexpected_nested_exception(_: ark.armv8.registers.ESR_EL1, _: u64) callconv(.{ .aarch64_aapcs = .{} }) void {
    log.err("unexpected nested exception", .{});
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
