const limine = @import("limine");
const std = @import("std");

const arch = @import("arch.zig");

pub export var framebuffer_request: limine.FramebufferRequest = .{};

pub export var base_revision: limine.BaseRevision = .{ .revision = 1 };

export fn _start() callconv(.C) noreturn {

    if (!base_revision.is_supported()) {
        arch.idle();
    }

    if (framebuffer_request.response) |framebuffer_response| {
        if (framebuffer_response.framebuffer_count < 1) {
            arch.idle();
        }

        const framebuffer = framebuffer_response.framebuffers()[0];

        for (0..100) |i| {
            const pixel_offset = i * framebuffer.pitch + i * 4;

            @as(*u32, @ptrCast(@alignCast(framebuffer.address + pixel_offset))).* = 0xFFFFFFFF;
        }
    }

    arch.idle();
}
