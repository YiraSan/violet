// Copyright (c) 2024-2025 The violetOS authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// --- dependencies --- //

const std = @import("std");
const basalt = @import("basalt");

const log = std.log.scoped(.pcie);

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const acpi = kernel.drivers.acpi;

// --- pcie/root.zig --- //

pub const Segment = struct {
    id: u16,
    phys_addr: u64,
    virt_addr: u64,
    start_bus: u8,
    end_bus: u8,
};

pub const Device = struct {
    segment: *Segment,
    bus: u8,
    device: u5,

    pub fn function(self: @This(), id: u3) *Function {
        return fnAddress(self.segment, self.bus, self.device, id);
    }

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        return std.fmt.format(writer, "{x:0>4}:{x:0>2}:{x:0>2}", .{ self.segment.id, self.bus, self.device });
    }
};

pub const BarHeader = packed struct(u32) {
    region_type: enum(u1) {
        memory_mapped = 0b0,
        io_port = 0b1,
    },
    bar_type: enum(u2) {
        b32 = 0b00,
        b64 = 0b10,
    },
    prefetchable: bool,
    _reserved: u28,
};

pub const Capability = extern struct {
    /// PCI Capability Vendor ID.
    vendor_id: u8 align(1),
    /// PCI Capability Next Offset.
    next_offset: u8 align(1),
};

pub const Function = extern struct {
    config_space: ConfigurationSpace align(1),

    pub const ConfigurationSpace = extern struct {
        vendor_id: u16 align(1),
        device_id: u16 align(1),
        command: packed struct(u16) {
            /// IO Space Enable.
            iose: bool, // bit 0
            /// Memory Space Enable.
            mse: bool, // bit 1
            /// Bus Master Enable.
            bme: bool, // bit 2
            /// Special Cycle Enable. DEPRECATED. Default to Zero.
            sce: bool, // bit 3
            /// Mem. Write & Invalidate Enable.
            mwie: bool, // bit 4
            /// VGA Palette Snoop.
            vga: bool, // bit 5
            /// Parity Error Response.
            per: bool, // bit 6
            _reserved0: u1, // bit 7
            /// System Error Enable.
            see: bool, // bit 8
            /// Fast Back-to-Back Enable.
            fbe: bool, // bit 9
            /// Interrupt Disable.
            id: bool, // bit 10
            _reserved1: u5, // bit 11-15
        } align(1),
        status: u16 align(1),

        revision: u8 align(1),
        programming_interface: u8 align(1),
        subclass: u8 align(1),
        class_code: ClassCode align(1),

        cache_line_size: u8 align(1),
        latency_timer: u8 align(1),
        header_type: packed struct(u8) {
            type: u7,
            multi_function: bool,
        } align(1),
        builtin_in_self_test: u8 align(1),

        bar: [6]u32 align(1),

        cardbus_cis_pointer: u32 align(1),
        subsystem_vendor_id: u16 align(1),
        subsystem_id: u16 align(1),
        expansion_rom_base_addr: u32 align(1),
        capabilities_ptr: u8 align(1),
        reserved: [7]u8 align(1),
        interrupt_line: u8 align(1),
        interrupt_pin: u8 align(1),
        min_grant: u8 align(1),
        max_latency: u8 align(1),

        pub const ClassCode = enum(u8) {
            unclassified = 0x00,
            mass_storage = 0x01,
            network_controller = 0x02,
            display_controller = 0x03,
            multimedia_controller = 0x04,
            memory_controller = 0x05,
            bridge_device = 0x06,
            simple_communication = 0x07,
            base_system_peripheral = 0x08,
            input_device = 0x09,
            docking_station = 0x0a,
            processor = 0x0b,
            serial_bus_controller = 0x0c,
            wireless_controller = 0x0d,
            intelligent_io_controller = 0x0e,
            satellite_communication = 0x0f,
            encryption_controller = 0x10,
            signal_processing_controller = 0x11,
            miscellaneous = 0x12,
            reserved = 0xff,
        };

        pub fn readBar(self: *@This(), index: usize) u64 {
            const bar = self.bar[index];
            const header: BarHeader = @bitCast(bar);

            if (header.region_type == .memory_mapped) {
                if (header.bar_type == .b32) {
                    return bar & 0xfffffff0;
                } else {
                    const low_address = bar & 0xfffffff0;
                    const high_address = self.bar[index + 1];

                    return @as(u64, @intCast(high_address)) << 32 | low_address;
                }
            } else {
                @panic("TODO BAR PCI I/O PORT");
            }
        }

        pub fn capabilities(self: *@This()) CapabilityIter {
            return .{
                .config_space = self,
                ._next = if (self.capabilities_ptr == 0) 0 else @intFromPtr(self) + self.capabilities_ptr,
            };
        }

        pub const CapabilityIter = struct {
            config_space: *ConfigurationSpace,
            _next: u64,

            pub fn next(self: *@This()) ?*volatile Capability {
                if (self._next == 0) return null;

                const capability: *volatile Capability = @ptrFromInt(self._next);

                if (capability.next_offset == 0) {
                    self._next = 0;
                } else {
                    self._next = @intFromPtr(self.config_space) + capability.next_offset;
                }

                return capability;
            }
        };
    };
};

fn fnAddress(segment: *Segment, bus: u8, device: u5, function: u3) *Function {
    return @ptrFromInt(segment.virt_addr + (@as(u64, @intCast((bus - segment.start_bus))) << 20) + (@as(u64, @intCast(device)) << 15) + (@as(u64, @intCast(function)) << 12));
}

var segments: []Segment = undefined;

pub fn init() !void {
    segments.len = 0;

    var xsdt_iterator = kernel.boot.xsdt.iter();
    while (xsdt_iterator.next()) |xsdt_entry| {
        switch (xsdt_entry) {
            .mcfg => |mcfg| {
                const entries = mcfg.entries();
                const page_count = std.mem.alignForward(usize, entries.len * @sizeOf(Segment), mem.PageLevel.l4K.size()) >> mem.PageLevel.l4K.shift();
                segments.ptr = @ptrFromInt(mem.heap.alloc(
                    &mem.virt.kernel_space,
                    .l4K,
                    @intCast(page_count),
                    .{ .writable = true },
                    false,
                ));
                segments.len = entries.len;

                for (entries) |entry| {
                    const segment = &segments[entry.segment];
                    segment.id = entry.segment;
                    segment.phys_addr = entry.address;
                    segment.virt_addr = 0;
                    segment.start_bus = entry.start_bus;
                    segment.end_bus = entry.end_bus;
                }
            },
            else => {},
        }
    }

    // map virtually segments
    for (segments) |*segment| {
        const _1MiB = 1024 * 1024;
        const segment_size = @as(usize, @intCast((segment.end_bus - segment.start_bus))) * _1MiB + _1MiB;
        const segment_page_count = std.mem.alignForward(usize, segment_size, mem.PageLevel.l4K.size()) >> mem.PageLevel.l4K.shift();
        const reservation = mem.virt.kernel_space.reserve(segment_page_count);
        reservation.map(
            segment.phys_addr,
            .{ .writable = true, .device = true },
            .no_hint,
        );
        segment.virt_addr = reservation.address();
    }

    try discoverDevices();

    // -- create a task -- //

    const process_id = try kernel.scheduler.Process.create(.{
        .execution_level = .kernel,
        .kernel_space_only = true,
    });

    const task_id = try kernel.scheduler.Task.create(process_id, .{
        .entry_point = @intFromPtr(&pcie_task),
        .timer_precision = .disabled,
    });

    try kernel.scheduler.register(task_id);
}

fn pcie_task() callconv(basalt.task.call_conv) noreturn {
    const interface = basalt.prism.Interface.register(.{
        .description = .{
            .class = .reserved,
            .sub_class = @intFromEnum(basalt.prism.Interface.ReservedSubClass.pcie),
            .semver_major = 0,
            .semver_minor = 1,
            .flags = .{
                .priviledged = true,
            },
        },
    }) catch |err| {
        std.log.err("{}", .{err});
        unreachable;
    };

    std.log.info("{}", .{interface});

    basalt.task.terminate();
}

fn discoverDevices() !void {
    for (segments) |*segment| {
        var bus: usize = segment.start_bus;
        while (bus <= segment.end_bus) : (bus += 1) {
            for (0..32) |device| {
                const function0 = fnAddress(segment, @intCast(bus), @intCast(device), 0);
                if (function0.config_space.vendor_id != 0xffff) {
                    // ...
                }
            }
        }
    }
}

// fn handleDevice(segment: *Segment, bus: u8, device: u5) !void {
//     const function0 = fnAddress(segment, bus, device, 0);

//     const idevice = Device{
//         .segment = segment,
//         .bus = bus,
//         .device = device,
//     };

//     switch (function0.config_space.vendor_id) {
//         @intFromEnum(VendorID.@"Red Hat, Inc. 1af4") => {
//             const device_id: DeviceID.@"1af4" = @enumFromInt(function0.config_space.device_id);
//             switch (device_id) {
//                 .virtio_1_0_block_device => try kernel.drivers.virtio.block.handle(idevice),
//                 else => {
//                     log.warn("({}) \"{s}\" is not implemented.", .{ idevice, @tagName(device_id) });
//                 },
//             }
//         },
//         @intFromEnum(VendorID.@"Red Hat, Inc. 1b36") => {
//             const device_id: DeviceID.@"1b36" = @enumFromInt(function0.config_space.device_id);
//             switch (device_id) {
//                 else => {
//                     log.warn("({}) \"{s}\" is not implemented.", .{ idevice, @tagName(device_id) });
//                 },
//             }
//         },
//         else => log.warn("({}) unknown VendorID {x}", .{ idevice, function0.config_space.vendor_id }),
//     }
// }

// --- pci.ids --- //

pub const VendorID = enum(u16) {
    @"Red Hat, Inc. 1af4" = 0x1af4,
    @"Red Hat, Inc. 1b36" = 0x1b36,
};

pub const DeviceID = struct {
    pub const @"1af4" = enum(u16) {
        virtio_network_device = 0x1000,
        virtio_block_device = 0x1001,
        virtio_memory_balloon = 0x1002,
        virtio_console = 0x1003,
        virtio_scsi = 0x1004,
        virtio_rng = 0x1005,
        virtio_filesystem = 0x1009,

        virtio_1_0_network_device = 0x1041,
        virtio_1_0_block_device = 0x1042,
        virtio_1_0_console = 0x1043,
        virtio_1_0_rng = 0x1044,
        virtio_1_0_balloon = 0x1045,
        virtio_1_0_io_memory = 0x1046,
        virtio_1_0_remote_processor_messaging = 0x1047,
        virtio_1_0_scsi = 0x1048,
        virtio_9p_transport = 0x1049,
        virtio_1_0_wlan_mac = 0x104a,
        virtio_1_0_remoteproc_serial_link = 0x104b,
        virtio_1_0_memory_balloon = 0x104d,
        virtio_1_0_gpu = 0x1050,
        virtio_1_0_clock_timer = 0x1051,
        virtio_1_0_input = 0x1052,
        virtio_1_0_socket = 0x1053,
        virtio_1_0_crypto = 0x1054,
        virtio_1_0_signal_distribution_device = 0x1055,
        virtio_1_0_pstore_device = 0x1056,
        virtio_1_0_iommu = 0x1057,
        virtio_1_0_mem = 0x1058,
        virtio_1_0_sound = 0x1059,
        virtio_1_0_file_system = 0x105a,
        virtio_1_0_pmem = 0x105b,
        virtio_1_0_rpmb = 0x105c,
        virtio_1_0_mac80211_hwsim = 0x105d,
        virtio_1_0_video_encoder = 0x105e,
        virtio_1_0_video_decoder = 0x105f,
        virtio_1_0_scmi = 0x1060,
        virtio_1_0_nitro_secure_module = 0x1061,
        virtio_1_0_i2c_adapter = 0x1062,
        virtio_1_0_watchdog = 0x1063,
        virtio_1_0_can = 0x1064,
        virtio_1_0_dmabuf = 0x1065,
        virtio_1_0_parameter_server = 0x1066,
        virtio_1_0_audio_policy = 0x1067,
        virtio_1_0_bluetooth = 0x1068,
        virtio_1_0_gpio = 0x1069,
        qemu_inter_vm_shared_memory_device = 0x1110,
    };

    pub const @"1b36" = enum(u16) {
        qemu_pci_pci_bridge = 0x0001,
        qemu_pci_16550a_adapter = 0x0002,
        qemu_pci_dual_port_16550a_adapter = 0x0003,
        qemu_pci_quad_port_16550a_adapter = 0x0004,
        qemu_pci_test_device = 0x0005,
        pci_rocker_ethernet_switch_device = 0x0006,
        pci_sd_card_host_controller_interface = 0x0007,
        qemu_pcie_host_bridge = 0x0008,
        qemu_pci_expander_bridge = 0x0009,
        pci_pci_bridge_multiseat = 0x000a,
        qemu_pcie_expander_bridger = 0x000b,
        qemu_pcie_root_port = 0x000c,
        qemu_xhci_host_controller = 0x000d,
        qemu_pcie_to_pci_bridge = 0x000e,
        qemu_nvm_express_controller = 0x0010,
        qemu_pvpanic_device = 0x0011,
        qemu_ufs_host_controller = 0x0013,
        qxl_paravirtual_graphic_card = 0x100,
    };
};
