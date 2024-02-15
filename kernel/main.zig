const builtin = @import("builtin");
const arch = @import("arch.zig");

comptime {
    @export(arch.main.start, .{ .name = "_start", .linkage = .Strong });
}

const limine = @import("limine");

pub export var framebuffer_request: limine.FramebufferRequest = .{};
pub export var base_revision: limine.BaseRevision = .{ .revision = 1 };

pub fn main() !void {

    arch.serial.print("welcome to violet!\n");

    // check if limine is supported
    if (!base_revision.is_supported()) {
        arch.idle();
    }

    // draw a line if there's a framebuffer
    if (framebuffer_request.response) |framebuffer_response| {
        if (framebuffer_response.framebuffer_count > 0) {
            const framebuffer = framebuffer_response.framebuffers()[0];

            for (0..100) |i| {
                const pixel_offset = i * framebuffer.pitch + i * 4;

                @as(*u32, @ptrCast(@alignCast(framebuffer.address + pixel_offset))).* = 0xFFFFFFFF;
            }
        }
    }
    
}
