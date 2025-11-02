ctx: *anyopaque,
readFn: fn (ctx: *anyopaque, lba: u64, buffer: []u8) anyerror!void,
writeFn: fn (ctx: *anyopaque, lba: u64, buffer: []const u8) anyerror!void,
sector_size: usize,
offset_lba: usize,
length_lba: usize,

pub fn read(self: *@This(), lba: u64, buffer: []u8) anyerror!void {
    if (buffer.len != self.sector_size) return error.InvalidBufferSize;
    if (lba >= self.length_lba) return error.OutOfBounds;

    const real_lba = self.offset_lba + lba;

    return self.readFn(self.ctx, real_lba, buffer);
}

pub fn write(self: *@This(), lba: u64, buffer: []const u8) anyerror!void {
    if (buffer.len != self.sector_size) return error.InvalidBufferSize;
    if (lba >= self.length_lba) return error.OutOfBounds;

    const real_lba = self.offset_lba + lba;

    return self.writeFn(self.ctx, real_lba, buffer);
}
