const std = @import("std");

base_address: u64,

pub fn init(self: *@This(), base_address: u64) void {
    self.base_address = base_address;
}
