const std = @import("std");
const uefi = std.os.uefi;

const W = std.unicode.utf8ToUtf16LeStringLiteral;

const PrintError = error{ InvalidUtf8, TooLongSlice };

inline fn dynamicPuts(comptime out: []const u8, stream: ?*uefi.protocol.SimpleTextOutput) uefi.Status {
    if (stream) |str| {
        return str.outputString(W(out));
    }
    return uefi.Status.unsupported;
}

pub fn puts(comptime out: []const u8) uefi.Status {
    return dynamicPuts(out, uefi.system_table.con_out);
}

pub fn putsln(comptime out: []const u8) uefi.Status {
    return puts(out ++ .{ '\r', '\n' });
}

pub fn putsErr(comptime out: []const u8) void {
    _ = dynamicPuts(out, uefi.system_table.std_err);
}

pub fn putslnErr(comptime out: []const u8) void {
    _ = putsErr(out ++ .{ '\r', '\n' });
}

const writer = std.io.GenericWriter(void, error{}, writerCallback){ .context = {} };

fn writerCallback(_: void, out: []const u8) error{}!usize {
    var buffer: [513]u16 = std.mem.zeroes([513]u16);
    var dest_index: usize = 0;
    var actual_dest_index: usize = 0;
    const view = std.unicode.Utf8View.initUnchecked(out); // we rely on ourselves here, however i do not want to mix zig errors with uefi status returns.
    var it = view.iterator();
    while (it.nextCodepoint()) |codepoint| {
        if (codepoint < 0x10000) {
            if (dest_index >= 512) {
                buffer[dest_index] = 0;
                // ptrCast SAFETY: buffer of 513 elements to 512 + 0 sentinel
                _ = uefi.system_table.con_out.?.outputString(@ptrCast(&buffer));
                actual_dest_index += dest_index;
                dest_index = 0;
            }
            buffer[dest_index] = std.mem.nativeToLittle(u16, @intCast(codepoint));
            dest_index += 1;
        } else {
            if (dest_index >= 511) {
                buffer[dest_index] = 0;
                // we might pass a slice here with length 511 (thus still having one free usable slot). however
                // we do not need to pass a subslice as uefi terminates once it encounters a null-terminator
                // which is then set at index 511 instead of 512.
                // ptrCast SAFETY: buffer of 513 elements to 512 + 0 sentinel (0 sentinel may already be at index 511)
                _ = uefi.system_table.con_out.?.outputString(@ptrCast(&buffer));
                actual_dest_index += dest_index;
                dest_index = 0;
            }
            const high = @as(u16, @intCast((codepoint - 0x10000) >> 10)) + 0xD800;
            const low = @as(u16, @intCast(codepoint & 0x3FF)) + 0xDC00;
            buffer[dest_index..][0..2].* = .{ std.mem.nativeToLittle(u16, high), std.mem.nativeToLittle(u16, low) };
            dest_index += 2;
        }
    }
    if (dest_index != 0) {
        buffer[dest_index] = 0;
        // ptrCast SAFETY: buffer of dest_index elements to 512 + 0 sentinel (although actual 0 sentinel already at dest_index)
        _ = uefi.system_table.con_out.?.outputString(@ptrCast(&buffer));
    }
    actual_dest_index += dest_index;
    return actual_dest_index;
}

pub fn print(comptime out: []const u8, args: anytype) void {
    std.fmt.format(writer, out, args) catch unreachable;
}
