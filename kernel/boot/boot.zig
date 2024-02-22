const arch = @import("../arch/arch.zig");
const main = @import("../main.zig").main;

const limine = @import("limine");

export var base_revision: limine.BaseRevision = .{ .revision = 1 };

export var framebuffer_request: limine.FramebufferRequest = .{};
export var memmap_request: limine.MemoryMapRequest = .{};
export var hhdm_request: limine.HhdmRequest = .{};
export var dtb_request: limine.DeviceTreeBlobRequest = .{};
export var boot_time_request: limine.BootTimeRequest = .{};

pub var framebuffer: limine.FramebufferResponse = undefined;
pub var memmap: limine.MemoryMapResponse = undefined;
pub var hhdm: limine.HhdmResponse = undefined;
pub var dtb: limine.DeviceTreeBlobResponse = undefined;
pub var boot_time: limine.BootTimeResponse = undefined;

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

        if (dtb_request.response) |dt| {
            dtb = dt.*;
        }

        if (boot_time_request.response) |bt| {
            boot_time = bt.*;
        }

        // TODO parse device tree

        main() catch arch.cpu.halt();

        arch.cpu.halt();
        unreachable;

    }
};
