// --- dependencies --- //

const std = @import("std");
const basalt = @import("basalt");

// --- imports --- //

const kernel = @import("root");

// --- syscall/root.zig --- //

pub const SyscallFn = *const fn (*kernel.arch.ExceptionContext) callconv(basalt.task.call_conv) void;

pub var registers: [basalt.syscall.MAX_CODE]u64 = undefined;

pub fn init() !void {
    @memset(&registers, 0);

    register(.null, &null_syscall);
}

pub fn register(code: basalt.syscall.Code, syscall_fn: SyscallFn) void {
    registers[@intFromEnum(code)] = @intFromPtr(syscall_fn);
}

fn null_syscall(context: *kernel.arch.ExceptionContext) callconv(basalt.task.call_conv) void {
    context.setArg(0, @bitCast(basalt.syscall.Result{
        .is_success = true,
    }));
}
