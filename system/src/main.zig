const builtin = @import("builtin");
const basalt = @import("basalt");

pub fn main() !void {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            asm volatile ("svc #0");
        },
        else => unreachable,
    }
}
