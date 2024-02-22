const std = @import("std");

const int = @import("int.zig");

pub const Spinlock = struct {
    lock_bits: std.atomic.Value(u32) = .{ .raw = 0 },
    refcount: std.atomic.Value(usize) = .{ .raw = 0 },
    interrupts: bool = false,

    pub fn lock(self: *Spinlock) void {
        _ = self.refcount.fetchAdd(1, .Monotonic);

        const current = int.is_enabled();
        int.disable();

        while (true) {
            if (self.lock_bits.swap(1, .Acquire) == 0)
                break;

            while (self.lock_bits.fetchAdd(0, .Monotonic) != 0) {
                if (int.is_enabled()) {
                    int.enable();
                } else {
                    int.disable();
                }
                std.atomic.spinLoopHint();
                int.disable();
            }
        }

        _ = self.refcount.fetchSub(1, .Monotonic);
        @fence(.Acquire);
        self.interrupts = current;
    }

    pub fn unlock(self: *Spinlock) void {
        self.lock_bits.store(0, .Release);
        @fence(.Release);

        if (self.interrupts) {
            int.enable();
        } else {
            int.disable();
        }
    }
};
