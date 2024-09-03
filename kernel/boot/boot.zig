const arch = @import("../arch/arch.zig");
const main = @import("../main.zig").main;

const limine = @import("limine");

export var base_revision: limine.BaseRevision = .{ .revision = 2 };

export var framebuffer_request: limine.FramebufferRequest = .{};
export var memmap_request: limine.MemoryMapRequest = .{};
export var hhdm_request: limine.HhdmRequest = .{};
export var boot_time_request: limine.BootTimeRequest = .{};
export var rsdp_request: limine.RsdpRequest = .{};

pub var framebuffer: limine.FramebufferResponse = undefined;
pub var memmap: limine.MemoryMapResponse = undefined;
pub var hhdm: limine.HhdmResponse = undefined;
pub var boot_time: limine.BootTimeResponse = undefined;
pub var rsdp: limine.RsdpResponse = undefined;

pub const entry = struct {
    pub fn start() callconv(.C) noreturn {

        if (!base_revision.is_supported()) {
            arch.cpu.halt();
        }

        if (framebuffer_request.response) |fb| {
            framebuffer = fb.*;
        }

        if (memmap_request.response) |mm| {
            memmap = mm.*;
        }

        if (hhdm_request.response) |hm| {
            hhdm = hm.*;
        }

        if (boot_time_request.response) |bt| {
            boot_time = bt.*;
        }

        if (rsdp_request.response) |r| {
            rsdp = r.*;
        }

        main() catch arch.cpu.halt();

        arch.cpu.halt();
        unreachable;

    }
};
