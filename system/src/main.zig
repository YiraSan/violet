const builtin = @import("builtin");

pub fn main() !void {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            asm volatile ("svc #0");
        },
        .x86_64 => {},
        else => unreachable,
    }
}
