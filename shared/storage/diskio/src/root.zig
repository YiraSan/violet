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
