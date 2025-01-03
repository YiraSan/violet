const std = @import("std");

const builtin = @import("builtin");
const limine = @import("limine.zig");

const arch = @import("root").arch;
const com = @import("root").com;
const device = @import("root").device;
const drivers = @import("root").drivers;

export var base_revision: limine.BaseRevision = .{ .revision = 0 };

export var hhdm_request: limine.HhdmRequest = .{};
export var memory_map_request: limine.MemoryMapRequest = .{};
export var framebuffer_request: limine.FramebufferRequest = .{};
export var paging_mode_request: limine.PagingModeRequest = .{};

pub var hhdm: limine.HhdmResponse = std.mem.zeroes(limine.HhdmResponse);
pub var memory_map: limine.MemoryMapResponse = std.mem.zeroes(limine.MemoryMapResponse);
pub var framebuffer: limine.FramebufferResponse = std.mem.zeroes(limine.FramebufferResponse);
pub var paging_mode: limine.PagingModeResponse = std.mem.zeroes(limine.PagingModeResponse);

pub const entry = struct {
    pub fn start() callconv(.C) noreturn {

        if (!base_revision.is_supported()) {
            arch.halt();
        }

        if (hhdm_request.response) |hhdm_response| {
            hhdm = hhdm_response.*;
        }

        if (memory_map_request.response) |memory_map_response| {
            memory_map = memory_map_response.*;
        }

        if (framebuffer_request.response) |framebuffer_response| {
            framebuffer = framebuffer_response.*;
        }

        if (paging_mode_request.response) |paging_mode_response| {
            paging_mode = paging_mode_response.*;
        }

        device.init();

        std.log.info("version 0.0.0", .{});

        arch.init();
        com.memory.init();

        arch.halt();
    }
};
