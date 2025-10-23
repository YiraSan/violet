const std = @import("std");

const RSDP_SIGNATURE = "RSD PTR ";
const RSDT_SIGNATURE = "RSDT";
const XSDT_SIGNATURE = "XSDT";
const MADT_SIGNATURE = "APIC";
const FADT_SIGNATURE = "FACP";
const FACS_SIGNATURE = "FACS";
const MCFG_SIGNATURE = "MCFG";
const HPET_SIGNATURE = "HPET";
const SRAT_SIGNATURE = "SRAT";
const SLIT_SIGNATURE = "SLIT";
const DSDT_SIGNATURE = "DSDT";
const SSDT_SIGNATURE = "SSDT";
const PSDT_SIGNATURE = "PSDT";
const ECDT_SIGNATURE = "ECDT";
const RHCT_SIGNATURE = "RHCT";
const PPTT_SIGNATURE = "PPTT";
const GTDT_SIGNATURE = "GTDT";
const SPCR_SIGNATURE = "SPCR";
const DBG2_SIGNATURE = "DBG2";
const IORT_SIGNATURE = "IORT";
const BGRT_SIGNATURE = "BGRT";

pub const Gas = packed struct {
    address_space_id: u8,
    register_bit_width: u8,
    register_bit_offset: u8,
    access_size: u8,
    address: u64,
};

pub const Rsdp = packed struct {
    signature: u64,
    checksum: u8,
    oemid: u48,
    revision: u8,
    rsdt_addr: u32,

    // available ONLY if revision >= 2.0
    length: u32,
    xsdt_addr: u64,
    extended_checksum: u8,
    rsvd: u24,
};

pub const SdtHeader = packed struct {
    signature: u32,
    length: u32,
    revision: u8,
    checksum: u8,
    oemid: u48,
    oem_table_id: u64,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

pub const Xsdt = packed struct {
    header: SdtHeader,

    pub fn iter(self: *@This()) XsdtIterator {
        return .{ .xsdt = self };
    }
};

pub const XsdtIterator = struct {
    xsdt: *Xsdt,
    index: usize = 0,

    pub fn next(self: *@This()) ?Entry {
        @setRuntimeSafety(false);

        const offset = 36 + @sizeOf(u64) * self.index;
        if (offset >= self.xsdt.header.length) return null;

        const sdt_header: **SdtHeader = @ptrFromInt(@intFromPtr(self.xsdt) + offset);
        const signature = std.mem.toBytes(sdt_header.*.*.signature);
        self.index += 1;

        if (std.mem.eql(u8, MADT_SIGNATURE, &signature)) {
            return Entry{ .madt = @ptrCast(sdt_header.*) };
        } else if (std.mem.eql(u8, FADT_SIGNATURE, &signature)) {
            return Entry{ .fadt = @ptrCast(sdt_header.*) };
        } else if (std.mem.eql(u8, PPTT_SIGNATURE, &signature)) {
            return Entry{ .pptt = @ptrCast(sdt_header.*) };
        } else if (std.mem.eql(u8, GTDT_SIGNATURE, &signature)) {
            return Entry{ .gtdt = @ptrCast(sdt_header.*) };
        } else if (std.mem.eql(u8, MCFG_SIGNATURE, &signature)) {
            return Entry{ .mcfg = @ptrCast(sdt_header.*) };
        } else if (std.mem.eql(u8, SPCR_SIGNATURE, &signature)) {
            return Entry{ .spcr = @ptrCast(sdt_header.*) };
        } else if (std.mem.eql(u8, DBG2_SIGNATURE, &signature)) {
            return Entry{ .dbg2 = @ptrCast(sdt_header.*) };
        } else if (std.mem.eql(u8, IORT_SIGNATURE, &signature)) {
            return Entry{ .iort = @ptrCast(sdt_header.*) };
        } else if (std.mem.eql(u8, BGRT_SIGNATURE, &signature)) {
            return Entry{ .bgrt = @ptrCast(sdt_header.*) };
        }

        std.log.err("ACPI signature to do: {s}", .{signature});
        unreachable;
    }
};

pub const Entry = union(enum) {
    madt: *Madt,
    fadt: *Fadt,
    pptt: *Pptt,
    gtdt: *Gtdt,
    mcfg: *Mcfg,
    spcr: *Spcr,
    dbg2: *Dbg2,
    iort: *Iort,
    bgrt: *Bgrt,
    // TODO.
};

pub const MadtEntryType = enum(u8) {
    lapic = 0x0,
    ioapic = 0x1,
    interrupt_source_override = 0x2,
    nmi_source = 0x3,
    lapic_nmi = 0x4,
    lapic_address_override = 0x5,
    iosapic = 0x6,
    lsapic = 0x7,
    platform_interrupt_sources = 0x8,
    local_x2apic = 0x9,
    local_x2apic_nmi = 0xa,
    gicc = 0xb,
    gicd = 0xc,
    gic_msi_frame = 0xd,
    gicr = 0xe,
    gic_its = 0xf,
    multiprocessor_wakeup = 0x10,
    core_pic = 0x11,
    lio_pic = 0x12,
    ht_pic = 0x13,
    eio_pic = 0x14,
    msi_pic = 0x15,
    bio_pic = 0x16,
    lpc_pic = 0x17,
    rintc = 0x18,
    imsic = 0x19,
    aplic = 0x1a,
    plic = 0x1b,
    // reserved from 0x1c to 0x7f
    // OEM from 0x80 to 0xff
};

pub const EntryHeader = packed struct {
    type: union {
        madt: MadtEntryType,
        // srat
    },
    length: u8,
};

pub const Madt = packed struct {
    header: SdtHeader,
    local_interrupt_controller_address: u32,
    flags: u32,
    // entries: [_]EntryHeader,
};

pub const Fadt = packed struct {
    header: SdtHeader,
    // TODO
};

pub const Pptt = packed struct {
    header: SdtHeader,
    // TODO
};

pub const Gtdt = packed struct {
    header: SdtHeader,
    // TODO
};

pub const Mcfg = packed struct {
    header: SdtHeader,
    // TODO
};

pub const Spcr = packed struct {
    header: SdtHeader,
    // TODO
};

pub const Dbg2 = packed struct {
    header: SdtHeader,
    offset: u32,
    number: u32,

    pub fn iter(self: *@This()) Dbg2Iterator {
        return .{ .dbg2 = self };
    } 
};

pub const Dbg2Iterator = struct {
    dbg2: *Dbg2,
    offset: usize = 0,
    index: usize = 0,

    pub fn next(self: *@This()) ?*Dbg2DeviceInfo {
        @setRuntimeSafety(false);

        if (self.index >= self.dbg2.number) return null;
        self.index += 1;

        const device_info: *Dbg2DeviceInfo = @ptrFromInt(@intFromPtr(self.dbg2) + self.dbg2.offset + self.offset);

        self.offset += device_info.length;

        return device_info;
    }
};

pub const Dbg2DeviceInfo = packed struct {
    revision: u8,
    length: u16,
    number_generic_address_registers: u8,
    namespace_string_length: u16,
    namespace_string_offset: u16,
    oem_data_length: u16,
    oem_data_offset: u16,
    port_type: enum(u16) {
        serial = 0x8000,
        _1394 = 0x8001,
        usb = 0x8002,
        net = 0x8003,
    },
    port_subtype: packed union {
        serial: enum(u16) {
            ns16550 = 0x0,
            ns16550_dbgp1 = 0x1,
            max311xe_spi = 0x2,
            pl011 = 0x3,
            msm8x60 = 0x4,
            ns16550_nvidia = 0x5,
            ti_omap = 0x6,
            apm88xxxx = 0x8,
            msm8974 = 0x9,
            sam5250 = 0xa,
            intel_usif = 0xb,
            imx6 = 0xc,
            arm_sbsa_32bit = 0xd,
            arm_sbsa_generic = 0xe,
            arm_dcc = 0xf,
            bcm2835 = 0x10,
            sdm845_1_8432mhz = 0x11,
            ns16550_gas = 0x12,
            sdm845_7_372mhz = 0x13,
            intel_lpss = 0x14,
            riscv_sbi = 0x15,
        },
        _1394: enum(u16) {
            standard = 0x0,
        },
        usb: enum(u16) {
            xhci_debug = 0x0,
            ehci_debug = 0x1,
        },
    },
    rsvd: u16,
    base_address_register_offset: u16,
    address_size_offset: u16,

    pub fn base_address_registers(self: *Dbg2DeviceInfo) []Gas {
        @setRuntimeSafety(false);
        return @as([*]Gas, @ptrFromInt(@intFromPtr(self) + self.base_address_register_offset))[0..self.number_generic_address_registers];
    }

    pub fn address_sizes(self: *Dbg2DeviceInfo) []u32 {
        @setRuntimeSafety(false);
        return @as([*]u32, @ptrFromInt(@intFromPtr(self) + self.address_size_offset))[0..self.number_generic_address_registers];
    }

    pub fn namespace_string(self: *Dbg2DeviceInfo) []const u8 {
        @setRuntimeSafety(false);
        return @as([*]const u8, @ptrFromInt(@intFromPtr(self) + self.namespace_string_offset))[0..self.namespace_string_length];
    }

    // TODO. oem_data
};

pub const Iort = packed struct {
    header: SdtHeader,
    // TODO
};

pub const Bgrt = packed struct {
    header: SdtHeader,
    // TODO
};
