const Self = @This();

bits: [*]u8,
size: usize,

pub fn set(self: Self, bit: u64) void {
    self.bits[bit / 8] |= @as(u8, 1) << @as(u3, @truncate(bit % 8));
}

pub fn unset(self: Self, bit: u64) void {
    self.bits[bit / 8] &= ~(@as(u8, 1) << @as(u3, @truncate(bit % 8)));
}

pub fn check(self: Self, bit: u64) bool {
    return (self.bits[bit / 8] & (@as(u8, 1) << @as(u3, @truncate(bit % 8)))) != 0;
}
