// --- imports --- //

const std = @import("std");
const builtin = @import("builtin");

// --- bootloader requests --- //

const limine = @import("limine");

export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};
export var executable_address_request: limine.ExecutableAddressRequest linksection(".limine_requests") = .{};
export var paging_mode_request: limine.PagingModeRequest linksection(".limine_requests") = .{ .mode = .@"4lvl", .min_mode = .@"4lvl", .max_mode = .@"4lvl" };

pub var hhdm_offset: u64 = undefined;
pub var kernel_address_phys: u64 = undefined;
pub var kernel_address_virt: u64 = undefined;

// --- mem.zig --- //

pub fn init() void {
    if (hhdm_request.response) |hhdm_response| {
        hhdm_offset = hhdm_response.offset;
    } else @panic("unable to get hhdm address");

    if (executable_address_request.response) |executable_address_response| {
        kernel_address_phys = executable_address_response.physical_base;
        kernel_address_virt = executable_address_response.virtual_base;
    } else @panic("unable to get kernel address");
}

// --- phys --- //

pub const phys = @import("phys.zig");

// --- virt --- //

pub const virt = @import("virt.zig");
