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

pub const Gas = extern struct {
    address_space_id: u8 align(1),
    register_bit_width: u8 align(1),
    register_bit_offset: u8 align(1),
    access_size: u8 align(1),
    address: u64 align(1),

    comptime {
        if (@sizeOf(Gas) != 12) @compileError("Gas should have a size of 12.");
    }
};

pub const Rsdp = extern struct {
    signature: [8]u8 align(1),
    checksum: u8 align(1),
    oemid: [6]u8 align(1),
    revision: u8 align(1),
    rsdt_addr: u32 align(1),

    // available ONLY if revision >= 2.0
    length: u32 align(1),
    xsdt_addr: u64 align(1),
    extended_checksum: u8 align(1),
    _reserved0: [3]u8 align(1),

    comptime {
        if (@sizeOf(Rsdp) != 36) @compileError("Rsdp should have a size of 36.");
    }
};

pub const SdtHeader = extern struct {
    signature: [4]u8 align(1),
    length: u32 align(1),
    revision: u8 align(1),
    checksum: u8 align(1),
    oemid: [6]u8 align(1),
    oem_table_id: u64 align(1),
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),

    comptime {
        if (@sizeOf(SdtHeader) != 36) @compileError("SdtHeader should have a size of 36.");
    }
};

pub const Xsdt = extern struct {
    header: SdtHeader align(1),

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

pub const MadtEntryHeader = extern struct {
    type: MadtEntryType align(1),
    length: u8 align(1),
};

pub const Madt = extern struct {
    header: SdtHeader align(1),
    local_interrupt_controller_address: u32 align(1),
    flags: u32 align(1),

    pub fn iter(self: *@This()) MadtIterator {
        return .{ .madt = self };
    }
};

pub const MadtIterator = struct {
    madt: *Madt,
    offset: usize = 0,

    pub fn next(self: *@This()) ?MadtEntry {
        @setRuntimeSafety(false);

        if (self.offset >= self.madt.header.length) return null;

        const entry_header: *MadtEntryHeader = @ptrFromInt(@intFromPtr(self.madt) + @sizeOf(Madt) + self.offset);
        self.offset += entry_header.length;

        return switch (entry_header.type) {
            .gicd => .{ .gicd = @ptrCast(entry_header) },
            .gicc => .{ .gicc = @ptrCast(entry_header) },
            .multiprocessor_wakeup => .{ .multiprocessor_wakeup = @ptrCast(entry_header) },
            else => next(self),
        };
    }
};

pub const MadtEntry = union(enum) {
    gicd: *MadtGicd,
    gicc: *MadtGicc,
    multiprocessor_wakeup: *MadtMultiprocessorWakeup,
};

pub const MadtGicd = extern struct {
    header: MadtEntryHeader align(1),
    _reserved0: u16 align(1),
    id: u32 align(1),
    address: u64 align(1),
    system_vector_base: u32 align(1),
    gic_version: u8 align(1),
    _reserved1: [3]u8 align(1),

    comptime {
        if (@sizeOf(MadtGicd) != 24) @compileError("MadtGicd should have a size of 24.");
    }
};

pub const MadtGiccInterruptMode = enum(u1) {
    level = 0b0,
    edge = 0b1,
};

pub const MadtGicc = extern struct {
    header: MadtEntryHeader align(1),
    _reserved0: u16 align(1),
    interface_number: u32 align(1),
    acpi_id: u32 align(1),
    flags: packed struct(u32) {
        enabled: bool,
        perf_interrupt_mode: MadtGiccInterruptMode,
        vgic_maintenance_interrupt_mode: MadtGiccInterruptMode,
        online_capable: bool,
        _reserved0: u28,
    } align(1),
    parking_protocol_version: u32 align(1),
    perf_interrupt_gsiv: u32 align(1),
    parked_address: u64 align(1),
    address: u64 align(1),
    gicv: u64 align(1),
    gich: u64 align(1),
    vgic_maitenante_interrupt: u32 align(1),
    gicr_base_address: u64 align(1),
    mpidr: u64 align(1),
    power_efficiency_class: u8 align(1),
    _reserved1: u8 align(1),
    spe_overflow_interrupt: u16 align(1),
    trbe_interrupt: u16 align(1),

    comptime {
        if (@sizeOf(MadtGicc) != 82) @compileError("MadtGicc should have a size of 82.");
    }
};

pub const MadtMultiprocessorWakeup = extern struct {
    header: MadtEntryHeader align(1),
    mailbox_version: u16 align(1),
    _reserved0: u32 align(1),
    mailbox_address: u64 align(1),

    comptime {
        if (@sizeOf(MadtMultiprocessorWakeup) != 16) @compileError("MadtMultiprocessorWakeup should have a size of 82.");
    }
};

pub const Fadt = extern struct {
    header: SdtHeader align(1),
    firmware_ctrl: u32 align(1),
    dsdt: u32 align(1),
    int_model: u8 align(1),
    preferred_pm_profile: u8 align(1),
    sci_int: u16 align(1),
    smi_cmd: u32 align(1),
    acpi_enable: u8 align(1),
    acpi_disable: u8 align(1),
    s4bios_req: u8 align(1),
    pstate_cnt: u8 align(1),
    pm1a_evt_blk: u32 align(1),
    pm1b_evt_blk: u32 align(1),
    pm1a_cnt_blk: u32 align(1),
    pm1b_cnt_blk: u32 align(1),
    pm2_cnt_blk: u32 align(1),
    pm_tmr_blk: u32 align(1),
    gpe0_blk: u32 align(1),
    gpe1_blk: u32 align(1),
    pm1_evt_len: u8 align(1),
    pm1_cnt_len: u8 align(1),
    pm2_cnt_len: u8 align(1),
    pm_tmr_len: u8 align(1),
    gpe0_blk_len: u8 align(1),
    gpe1_blk_len: u8 align(1),
    gpe1_base: u8 align(1),
    cst_cnt: u8 align(1),
    p_lvl2_lat: u16 align(1),
    p_lvl3_lat: u16 align(1),
    flush_size: u16 align(1),
    flush_stride: u16 align(1),
    duty_offset: u8 align(1),
    duty_width: u8 align(1),
    day_alrm: u8 align(1),
    mon_alrm: u8 align(1),
    century: u8 align(1),
    iapc_boot_arch: u16 align(1),
    _reserved0: u8 align(1),
    flags: packed struct(u32) {
        wbinvd: bool,
        wbinvd_flush: bool,
        proc_c1: bool,
        p_lvl2_up: bool,
        pwr_button: bool,
        slp_button: bool,
        fix_rtc: bool,
        rtc_s4: bool,
        tmr_val_ext: bool,
        dck_cap: bool,
        reset_reg_sup: bool,
        sealed_case: bool,
        headless: bool,
        cpu_sw_slp: bool,
        pci_exp_wak: bool,
        use_platform_clock: bool,
        s4_rtc_sts_valid: bool,
        remote_power_on_capable: bool,
        force_apic_cluster_model: bool,
        force_apic_phys_dest_mode: bool,
        hw_reduced_acpi: bool,
        low_power_s0_idle_capable: bool,
        _reserved0: u10,
    } align(1),
    reset_reg: Gas align(1),
    reset_value: u8 align(1),
    arm_boot_arch: packed struct(u16) {
        psci_compliant: bool,
        psci_use_hvc: bool,
        _reserved0: u14,
    } align(1),
    fadt_minor_version: u8 align(1),
    x_firmware_ctrl: u64 align(1),
    x_dsdt: u64 align(1),
    x_pm1a_evt_blk: Gas align(1),
    x_pm1b_evt_blk: Gas align(1),
    x_pm1a_cnt_blk: Gas align(1),
    x_pm1b_cnt_blk: Gas align(1),
    x_pm2_cnt_blk: Gas align(1),
    x_pm_tmr_blk: Gas align(1),
    x_gpe0_blk: Gas align(1),
    x_gpe1_blk: Gas align(1),
    sleep_control_reg: Gas align(1),
    sleep_status_reg: Gas align(1),
    hypervisor_vendor_identity: u64 align(1),

    comptime {
        if (@sizeOf(Fadt) != 276) @compileError("Fadt should have a size of 276.");
    }
};

pub const Pptt = extern struct {
    header: SdtHeader align(1),
    // TODO
};

pub const Gtdt = extern struct {
    header: SdtHeader align(1),
    cnt_control_base: u64 align(1),
    _reserved0: u32 align(1),
    el1_secure_gsiv: u32 align(1),
    el1_secure_flags: u32 align(1),
    el1_non_secure_gsiv: u32 align(1),
    el1_non_secure_flags: u32 align(1),
    el1_virtual_gsiv: u32 align(1),
    el1_virtual_flags: u32 align(1),
    el2_gsiv: u32 align(1),
    el2_flags: u32 align(1),
    cnt_read_base: u64 align(1),
    platform_timer_count: u32 align(1),
    platform_timer_offset: u32 align(1),

    // revision >= 3
    el2_virtual_gsiv: u32 align(1),
    el2_virtual_flags: u32 align(1),
};

pub const McfgAllocation = extern struct {
    address: u64 align(1),
    segment: u16 align(1),
    start_bus: u8 align(1),
    end_bus: u8 align(1),
    _reserved0: u32 align(1),
};

pub const Mcfg = extern struct {
    header: SdtHeader align(1),
    _reserved0: u64 align(1),
    _entries: McfgAllocation align(1),

    pub fn entries(self: *@This()) []McfgAllocation {
        const count = (self.header.length - @sizeOf(u64) - @sizeOf(SdtHeader)) / @sizeOf(McfgAllocation);
        return @as([*]McfgAllocation, @ptrCast(&self._entries))[0..count];
    }
};

pub const Spcr = extern struct {
    header: SdtHeader align(1),
    // TODO
};

pub const Dbg2 = extern struct {
    header: SdtHeader align(1),
    offset: u32 align(1),
    number: u32 align(1),

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

pub const Dbg2DeviceInfo = extern struct {
    revision: u8 align(1),
    length: u16 align(1),
    number_generic_address_registers: u8 align(1),
    namespace_string_length: u16 align(1),
    namespace_string_offset: u16 align(1),
    oem_data_length: u16 align(1),
    oem_data_offset: u16 align(1),
    port_type: enum(u16) {
        serial = 0x8000,
        _1394 = 0x8001,
        usb = 0x8002,
        net = 0x8003,
    } align(1),
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
    } align(1),
    rsvd: u16 align(1),
    base_address_register_offset: u16 align(1),
    address_size_offset: u16 align(1),

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

pub const Iort = extern struct {
    header: SdtHeader align(1),
    // TODO
};

pub const Bgrt = extern struct {
    header: SdtHeader align(1),
    // TODO
};
