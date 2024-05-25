const boot = @import("../../../boot/boot.zig");

pub fn read(comptime T: type, address: usize) T {
    @fence(.seq_cst);
    return @as(*volatile T, @ptrFromInt(boot.hhdm.offset + address)).*;
}

pub fn write(comptime T: type, address: usize, data: T) void {
    @fence(.seq_cst);
    @as(*volatile T, @ptrFromInt(boot.hhdm.offset + address)).* = data;
}
