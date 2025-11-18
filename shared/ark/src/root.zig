const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;

pub const mem = struct {
    pub const PageLevel = enum(u2) {
        l4K = 0b00,
        l2M = 0b01,
        l1G = 0b10,

        pub inline fn size(self: @This()) u64 {
            return switch (self) {
                .l4K => 0x0000_1000,
                .l2M => 0x0020_0000,
                .l1G => 0x4000_0000,
            };
        }

        pub inline fn shift(self: @This()) u6 {
            return switch (self) {
                .l4K => 12,
                .l2M => 21,
                .l1G => 30,
            };
        }
    };

    pub const MemoryFlags = struct {
        writable: bool = false,
        executable: bool = false,
        user: bool = false,
        no_cache: bool = false,
        device: bool = false,
        writethrough: bool = false,
    };
};

pub const armv8 = struct {
    pub const CallArgs = struct {
        x0: u64 = 0,
        x1: u64 = 0,
        x2: u64 = 0,
        x3: u64 = 0,
        x4: u64 = 0,
        x5: u64 = 0,
        x6: u64 = 0,
        x7: u64 = 0,

        pub fn hypervisorCall(self: *@This()) u64 {
            return asm volatile (
                \\ hvc #0
                : [out] "={x0}" (-> u64),
                : [in0] "{x0}" (self.x0),
                  [in1] "{x1}" (self.x1),
                  [in2] "{x2}" (self.x2),
                  [in3] "{x3}" (self.x3),
                  [in4] "{x4}" (self.x4),
                  [in5] "{x5}" (self.x5),
                  [in6] "{x6}" (self.x6),
                  [in7] "{x7}" (self.x7),
                : "memory"
            );
        }

        pub fn secureMonitorCall(self: *@This()) u64 {
            return asm volatile (
                \\ smc #0
                : [out] "={x0}" (-> u64),
                : [in0] "{x0}" (self.x0),
                  [in1] "{x1}" (self.x1),
                  [in2] "{x2}" (self.x2),
                  [in3] "{x3}" (self.x3),
                  [in4] "{x4}" (self.x4),
                  [in5] "{x5}" (self.x5),
                  [in6] "{x6}" (self.x6),
                  [in7] "{x7}" (self.x7),
                : "memory"
            );
        }
    };

    pub const stage1_pagging = struct {
        pub const Entry = packed struct(u64) {
            valid: bool, // bit 0
            not_a_block: bool, // bit 1
            descriptor: packed union { // bit 2-63
                table: TableDescriptor,
                block_page: BlockPageDescriptor,
            },
        };

        /// L0-L1-L2 Table.
        pub const TableDescriptor = packed struct(u62) {
            _ignored0: u10 = 0, // bit 2-11

            next_level_table: u36, // bit 12-47

            _reserved0: u3 = 0, // bit 48-50
            _ignored1: u8 = 0, // bit 51-58

            /// Attributes doesn't apply at EL2.
            attributes: packed struct(u5) { // bit 59-63
                /// NOTE if only one priviledge level is supported `pxn_table` is reserved0 and `uxn_table` becomes `xn_table`.
                pxn_table: bool = false, // bit 59
                uxn_table: bool = false, // bit 60

                /// For EL1&0 translations, if the Effective value of HCR_EL2.{NV, NV1} is {1, 1}, then
                /// APTable[0] is treated as 0 regardless of the actual value.
                ///
                /// NOTE could be simplified by interpreting bit0 as "priviledge-only" and bit1 as "read-only".
                ap_table: enum(u2) { // bit 61-62
                    no_effect = 0b00,
                    /// Removes UnprivRead and UnprivWrite.
                    ///
                    /// (In Stage 1) Makes it EL1_READWRITE or EL1_READONLY.
                    priviledge_only = 0b01,
                    /// Removes UnprivWrite and PrivWrite.
                    ///
                    /// (In Stage 1) Makes it EL0_READONLY or EL1_READONLY.
                    read_only = 0b10,
                    /// Removes UnprivRead, UnprivWrite, and PrivWrite.
                    ///
                    /// (In Stage 1) Makes it EL1_READONLY.
                    priviledge_read_only = 0b11,
                } = .no_effect,

                /// Not available using the EL1&0 translation regime. (RES0)
                non_secure_table: bool = false, // bit 63
            } = .{},
        };

        /// L1-L2 Block and L3 Page.
        pub const BlockPageDescriptor = packed struct(u62) {
            attr_index: enum(u3) { // bit 2-4
                device = 0,
                non_cacheable = 1,
                writethrough = 2,
                writeback = 3,
            },

            /// Used only if the access is from Secure state.
            non_secure: bool = false, // bit 5

            permissions: packed union { // bit 6-7
                /// Stage 1 Indirect permissions are disabled.
                ///
                /// NOTE if there's only one privilege level, then priv_rw and priv_rw_unp_rw should not be used.
                direct: enum(u2) {
                    priv_rw = 0b00,
                    priv_rw_unp_rw = 0b01,
                    priv_ro = 0b10,
                    priv_rw_unp_ro = 0b11,
                },
                /// Stage 1 Indirect permissions are enabled.
                indirect: packed struct(u2) {
                    pi_index0: u1,
                    n_dirty: u1,
                },
            } = @bitCast(@as(u2, 0)),

            /// Assuming TCR_EL1.DS = 0
            shareability: enum(u2) { // bit 8-9
                non_shareable = 0b00,
                reserved_unpredictable = 0b01,
                outer_shareable = 0b10,
                inner_shareable = 0b11,
            },

            access_flag: bool, // bit 10

            /// Means `process-specific`.
            not_global: bool, // bit 11

            output_address: u36, // bit 12-47

            _reserved0: u2 = 0, // bit 48-49

            /// When FEAT_BTI is implemented.
            guarded_page: bool = false, // bit 50

            b51: packed union { // bit 51
                /// Stage 1 Indirect permissions are disabled.
                dirty_bit_modifier: u1,
                /// Stage 1 Indirect permissions are enabled.
                pi_index1: u1,
            } = @bitCast(@as(u1, 0)),

            b52: packed union { // bit 52
                /// The Effective value of PnCH is 0.
                contiguous: bool,
                /// The Effective value of PnCH is 1.
                protected: bool,
            } = @bitCast(@as(u1, 0)),

            b53: packed union { // bit 53
                /// Stage 1 Indirect permissions enabled, regardless of other feature settings.
                pi_index2: u1,
                /// The translation regime supports two privilege levels.
                pxn: bool,
                /// - The EL1&0 translation regime and the Effective value of HCR_EL2.{NV, NV1} is {1, 1}.
                /// - The translation regime supports a single privilege level.
                _reserved0: u1,
            } = @bitCast(@as(u1, 0)),

            b54: packed union { // bit 54
                /// The translation regime supports a single privilege level.
                xn: bool,
                /// The translation regime supports two privilege levels.
                uxn: bool,
                /// The EL1&0 translation regime and the Effective value of HCR_EL2.{NV, NV1} is {1, 1}.
                /// The Effective value of UXN is 0.
                pxn: bool,
                /// Stage 1 Indirect permissions enabled, regardless of other feature settings.
                pi_index3: u1,
            } = @bitCast(@as(u1, 0)),

            software_use: u4 = 0, // bit 55-58

            _ignored0: u1 = 0, // bit 59
            _ignored1: u3 = 0, // bit 60-62
            _ignored2: u1 = 0, // bit 63

            pub fn build(phys_addr: u64, flags: mem.MemoryFlags, software_use: u4) BlockPageDescriptor {
                var bpd = BlockPageDescriptor{
                    .attr_index = if (flags.device) .device else if (flags.no_cache) .non_cacheable else if (flags.writethrough) .writethrough else .writeback,
                    .output_address = @truncate(phys_addr >> 12),
                    .access_flag = phys_addr != 0,
                    .shareability = .inner_shareable,
                    .not_global = false, // TODO
                    .software_use = software_use,
                };

                var permission_indirection = false;
                const idmm3 = armv8.registers.ID_AA64MMFR3_EL1.load();
                if (idmm3.s1pie == .supported) {
                    const tcr2 = armv8.registers.TCR2_EL1.load();
                    if (tcr2.pie) {
                        permission_indirection = true;
                        @panic("Permission Indirection is not supported.");
                    }
                }

                if (!permission_indirection) {
                    // NOTE this assumes that there's at least two privilege levels.

                    if (!flags.executable) {
                        bpd.b53.pxn = true;
                        bpd.b54.uxn = true;
                    }

                    if (flags.user) {
                        if (flags.writable) {
                            bpd.permissions.direct = .priv_rw_unp_rw;
                        } else {
                            bpd.permissions.direct = .priv_rw_unp_ro;
                        }
                    } else {
                        bpd.b54.uxn = true;

                        if (flags.writable) {
                            bpd.permissions.direct = .priv_rw;
                        } else {
                            bpd.permissions.direct = .priv_ro;
                        }
                    }
                }

                return bpd;
            }

            pub fn getFlags(self: BlockPageDescriptor) mem.MemoryFlags {
                var memory_flags = mem.MemoryFlags{};

                if (self.attr_index == .device) {
                    memory_flags.device = true;
                } else if (self.attr_index == .non_cacheable) {
                    memory_flags.no_cache = true;
                } else if (self.attr_index == .writethrough) {
                    memory_flags.writethrough = true;
                }

                var permission_indirection = false;
                const idmm3 = armv8.registers.ID_AA64MMFR3_EL1.load();
                if (idmm3.s1pie == .supported) {
                    const tcr2 = armv8.registers.TCR2_EL1.load();
                    if (tcr2.pie) {
                        permission_indirection = true;
                        @panic("Permission Indirection is not supported.");
                    }
                }

                if (!permission_indirection) {
                    switch (self.permissions.direct) {
                        .priv_rw_unp_rw => {
                            memory_flags.user = true;
                            memory_flags.writable = true;
                        },
                        .priv_rw_unp_ro => {
                            memory_flags.user = true;
                        },
                        .priv_rw => {
                            memory_flags.writable = true;
                        },
                        .priv_ro => {},
                    }

                    if (!self.b53.pxn or !self.b54.uxn) {
                        memory_flags.executable = true;
                    }
                }

                return memory_flags;
            }
        };
    };

    pub const registers = struct {
        pub fn loadTtbr0El1() u64 {
            return asm volatile ("mrs %[output], ttbr0_el1"
                : [output] "=r" (-> u64),
            );
        }

        pub fn storeTtbr0El1(l0_table: u64) void {
            asm volatile ("msr ttbr0_el1, %[input]"
                :
                : [input] "r" (l0_table),
            );
        }

        pub fn loadTtbr1El1() u64 {
            return asm volatile ("mrs %[output], ttbr1_el1"
                : [output] "=r" (-> u64),
            );
        }

        pub fn storeTtbr1El1(l0_table: u64) void {
            asm volatile ("msr ttbr1_el1, %[input]"
                :
                : [input] "r" (l0_table),
            );
        }

        pub fn loadVbarEl1() u64 {
            return asm volatile ("mrs %[output], vbar_el1"
                : [output] "=r" (-> u64),
            );
        }

        pub fn storeVbarEl1(l0_table: u64) void {
            asm volatile ("msr vbar_el1, %[input]"
                :
                : [input] "r" (l0_table),
            );
        }

        pub fn loadVbarEl2() u64 {
            return asm volatile ("mrs %[output], vbar_el2"
                : [output] "=r" (-> u64),
            );
        }

        pub fn storeVbarEl2(l0_table: u64) void {
            asm volatile ("msr vbar_el2, %[input]"
                :
                : [input] "r" (l0_table),
            );
        }

        pub fn loadElrEl1() u64 {
            return asm volatile ("mrs %[output], elr_el1"
                : [output] "=r" (-> u64),
            );
        }

        pub fn storeElrEl1(l0_table: u64) void {
            asm volatile ("msr elr_el1, %[input]"
                :
                : [input] "r" (l0_table),
            );
        }

        pub fn loadElrEl2() u64 {
            return asm volatile ("mrs %[output], elr_el2"
                : [output] "=r" (-> u64),
            );
        }

        pub fn storeElrEl2(l0_table: u64) void {
            asm volatile ("msr elr_el2, %[input]"
                :
                : [input] "r" (l0_table),
            );
        }

        pub fn loadFarEl1() u64 {
            return asm volatile ("mrs %[output], far_el1"
                : [output] "=r" (-> u64),
            );
        }

        pub fn storeFarEl1(l0_table: u64) void {
            asm volatile ("msr far_el1, %[input]"
                :
                : [input] "r" (l0_table),
            );
        }

        pub fn loadTpidrEL0() u64 {
            return asm volatile ("mrs %[output], tpidr_el0"
                : [output] "=r" (-> u64),
            );
        }

        pub fn storeTpidrEL0(l0_table: u64) void {
            asm volatile ("msr tpidr_el0, %[input]"
                :
                : [input] "r" (l0_table),
            );
        }

        pub fn loadTpidrroEL0() u64 {
            return asm volatile ("mrs %[output], tpidrro_el0"
                : [output] "=r" (-> u64),
            );
        }

        pub fn storeTpidrroEL0(l0_table: u64) void {
            asm volatile ("msr tpidrro_el0, %[input]"
                :
                : [input] "r" (l0_table),
            );
        }

        pub fn loadTpidrEL1() u64 {
            return asm volatile ("mrs %[output], tpidr_el1"
                : [output] "=r" (-> u64),
            );
        }

        pub fn storeTpidrEL1(l0_table: u64) void {
            asm volatile ("msr tpidr_el1, %[input]"
                :
                : [input] "r" (l0_table),
            );
        }

        /// Translation Control Register (EL1)
        pub const TCR_EL1 = packed struct(u64) {
            /// The size offset of the memory region addressed by TTBR0_EL1. The region size is 2(64-t0sz) bytes.
            t0sz: u6, // bit 0-5

            _reserved0: u1 = 0, // bit 6

            /// Translation table walk disable for translations using TTBR0_EL1.
            epd0: bool, // bit 7

            /// Inner cacheability attribute for memory associated with translation table walks using TTBR0_EL1.
            irgn0: enum(u2) { // bit 8-9
                /// Non-cacheable
                nc = 0b00,
                /// Write-Back Read-Allocate Write-Allocate Cacheable
                wb_ra_wa = 0b01,
                /// Write-Through Read-Allocate No Write-Allocate Cacheable
                wt_ra_nwa = 0b10,
                /// Write-Back Read-Allocate No Write-Allocate Cacheable
                wb_ra_nwa = 0b11,
            },

            /// Outer cacheability attribute for memory associated with translation table walks using TTBR0_EL1.
            orgn0: enum(u2) { // bit 10-11
                /// Non-cacheable
                nc = 0b00,
                /// Write-Back Read-Allocate Write-Allocate Cacheable
                wb_ra_wa = 0b01,
                /// Write-Through Read-Allocate No Write-Allocate Cacheable
                wt_ra_nwa = 0b10,
                /// Write-Back Read-Allocate No Write-Allocate Cacheable
                wb_ra_nwa = 0b11,
            },

            /// Shareability attribute for memory associated with translation table walks using TTBR0_EL1
            sh0: enum(u2) { // bit 12-13
                non_shareable = 0b00,
                _reserved0 = 0b01,
                outer_shareable = 0b10,
                inner_shareable = 0b11,
            },

            /// Granule size for the TTBR0_EL1.
            tg0: enum(u2) { // bit 14-15
                @"4kb" = 0b00,
                @"64kb" = 0b01,
                @"16kb" = 0b10,
                /// Could be implementation defined.
                _reserved0 = 0b11,
            },

            /// The size offset of the memory region addressed by TTBR1_EL1. The region size is 2(64-t1sz) bytes.
            t1sz: u6, // bit 16-21

            /// Selects whether TTBR0_EL1 or TTBR1_EL1 defines the ASID.
            a1: enum(u1) { // bit 22
                ttbr0_el1 = 0b0,
                ttbr1_el1 = 0b1,
            },

            /// Translation table walk disable for translations using TTBR1_EL1.
            epd1: bool, // bit 23

            /// Inner cacheability attribute for memory associated with translation table walks using TTBR1_EL1.
            irgn1: enum(u2) { // bit 24-25
                /// Non-cacheable
                nc = 0b00,
                /// Write-Back Read-Allocate Write-Allocate Cacheable
                wb_ra_wa = 0b01,
                /// Write-Through Read-Allocate No Write-Allocate Cacheable
                wt_ra_nwa = 0b10,
                /// Write-Back Read-Allocate No Write-Allocate Cacheable
                wb_ra_nwa = 0b11,
            },

            /// Outer cacheability attribute for memory associated with translation table walks using TTBR1_EL1.
            orgn1: enum(u2) { // bit 26-27
                /// Non-cacheable
                nc = 0b00,
                /// Write-Back Read-Allocate Write-Allocate Cacheable
                wb_ra_wa = 0b01,
                /// Write-Through Read-Allocate No Write-Allocate Cacheable
                wt_ra_nwa = 0b10,
                /// Write-Back Read-Allocate No Write-Allocate Cacheable
                wb_ra_nwa = 0b11,
            },

            /// Shareability attribute for memory associated with translation table walks using TTBR1_EL1
            sh1: enum(u2) { // bit 28-29
                non_shareable = 0b00,
                _reserved0 = 0b01,
                outer_shareable = 0b10,
                inner_shareable = 0b11,
            },

            /// Granule size for the TTBR1_EL1.
            tg1: enum(u2) { // bit 30-31
                /// Could be implementation defined.
                _reserved0 = 0b00,
                @"16kb" = 0b01,
                @"4kb" = 0b10,
                @"64kb" = 0b11,
            },

            /// Intermediate Physical Address Size.
            ips: enum(u3) { // bit 32-34
                @"32bits_4gb" = 0b000,
                @"36bits_64gb" = 0b001,
                @"40bits_1tb" = 0b010,
                @"42bits_4tb" = 0b011,
                @"44bits_16tb" = 0b100,
                @"48bits_256tb" = 0b101,
                @"52bits_4pb" = 0b110,
                @"56bits_64pb" = 0b111,
            },

            _reserved1: u1 = 0, // bit 35

            /// ASID Size.
            as: enum(u1) { // bit 36
                /// The upper 8 bits of TTBR0_EL1 and TTBR1_EL1 are ignored by hardware for every purpose except reading back the register,
                /// and are treated as if they are all zeros for when used for allocation and matching entries in the TLB.
                u8 = 0b0,
                /// The upper 16 bits of TTBR0_EL1 and TTBR1_EL1 are used for allocation and matching in the TLB.
                u16 = 0b1,
            } = .u8,

            /// Top Byte ignored. Indicates whether the top byte of an address is used for address match for the TTBR0_EL1 region, or ignored and used for tagged addresses.
            tbi0: enum(u1) { // bit 37
                used = 0b0,
                ignored = 0b1,
            },

            /// Top Byte ignored. Indicates whether the top byte of an address is used for address match for the TTBR1_EL1 region, or ignored and used for tagged addresses.
            tbi1: enum(u1) { // bit 38
                used = 0b0,
                ignored = 0b1,
            },

            /// Hardware Access flag update in stage 1 translations from EL0 and EL1.
            ///
            /// When FEAT_HAFDBS is implemented
            ha: bool = false, // bit 39

            /// Hardware management of dirty state in stage 1 translations from EL0 and EL1.
            ///
            /// When FEAT_HAFDBS is implemented
            hd: bool = false, // bit 40

            /// Hierarchical Permission Disables.
            ///
            /// This affects the hierarchical control bits, APTable, PXNTable, and UXNTable, except NSTable, in the translation tables pointed to by TTBR0_EL1.
            ///
            /// When FEAT_HPDS is implemented
            hpd0: enum(u1) { // bit 41
                enabled = 0b0,
                disabled = 0b1,
            } = .enabled,
            /// Hierarchical Permission Disables.
            ///
            /// This affects the hierarchical control bits, APTable, PXNTable, and UXNTable, except NSTable, in the translation tables pointed to by TTBR1_EL1.
            ///
            /// When FEAT_HPDS is implemented
            hpd1: enum(u1) { // bit 42
                enabled = 0b0,
                disabled = 0b1,
            } = .enabled,

            hwu059: u1 = 0, // bit 43
            hwu060: u1 = 0, // bit 44
            hwu061: u1 = 0, // bit 45
            hwu062: u1 = 0, // bit 46

            hwu159: u1 = 0, // bit 47
            hwu160: u1 = 0, // bit 48
            hwu161: u1 = 0, // bit 49
            hwu162: u1 = 0, // bit 50

            /// Controls the use of the top byte of instruction addresses for address matching (TTBR0_EL1).
            ///
            /// When FEAT_PAuth is implemented
            tbid0: u1 = 0, // bit 51
            /// Controls the use of the top byte of instruction addresses for address matching (TTBR1_EL1).
            ///
            /// When FEAT_PAuth is implemented
            tbid1: u1 = 0, // bit 52

            /// Non-Fault translation timing Disable when using TTBR0_EL1.
            ///
            /// When FEAT_SVE is implemented
            nfd0: u1 = 0, // bit 53
            /// Non-Fault translation timing Disable when using TTBR1_EL1.
            ///
            /// When FEAT_SVE is implemented
            nfd1: u1 = 0, // bit 54

            /// Faulting control for unprivileged access to any address translated by TTBR0_EL1.
            ///
            /// When FEAT_E0PD is implemented
            e0pd0: u1 = 0, // bit 55
            /// Faulting control for unprivileged access to any address translated by TTBR1_EL1.
            ///
            /// When FEAT_E0PD is implemented
            e0pd1: u1 = 0, // bit 56

            /// When FEAT_MTE2 is implemented
            tcma0: u1 = 0, // bit 57
            /// When FEAT_MTE2 is implemented
            tcma1: u1 = 0, // bit 58

            /// When FEAT_LPA2 is implemented and (FEAT_D128 is not implemented or TCR2_EL1.D128 == 0)
            ds: u1 = 0, // bit 59

            /// Extended memory tag checking (TTBR0_EL1).
            ///
            /// When FEAT_MTE_NO_ADDRESS_TAGS is implemented or FEAT_MTE_CANONICAL_TAGS is implemented
            mtx0: u1 = 0, // bit 6
            /// Extended memory tag checking (TTBR1_EL1).
            ///
            /// When FEAT_MTE_NO_ADDRESS_TAGS is implemented or FEAT_MTE_CANONICAL_TAGS is implemented
            mtx1: u1 = 0, // bit 61

            _reserved3: u2 = 0, // bit 62-63

            pub fn load() @This() {
                return asm volatile ("mrs %[output], tcr_el1"
                    : [output] "=r" (-> @This()),
                );
            }

            pub fn store(self: @This()) void {
                asm volatile ("msr tcr_el1, %[input]"
                    :
                    : [input] "r" (self),
                );
            }
        };

        /// Extended Translation Control Register (EL1)
        pub const TCR2_EL1 = packed struct(u64) {
            /// Protected attribute enable.
            ///
            /// Enables use of bit[52] of the stage 1 translation table entries as the Protected bit, for translations using TTBRn_EL1.
            pnch: enum(u1) { // bit 0
                contiguous_bit = 0b0,
                protected_bit = 0b1,
            } = .contiguous_bit,

            /// Enables usage of Indirect Permission Scheme.
            pie: bool = false, // bit 1

            _todo: u62, // bit 2-63

            pub fn load() @This() {
                return asm volatile ("mrs %[output], tcr2_el1"
                    : [output] "=r" (-> @This()),
                );
            }

            pub fn store(self: @This()) void {
                asm volatile ("msr tcr2_el1, %[input]"
                    :
                    : [input] "r" (self),
                );
            }
        };

        /// Memory Attribute Indirection Register (EL1)
        pub const MAIR_EL1 = packed struct(u64) {
            attr0: u8 = 0,
            attr1: u8 = 0,
            attr2: u8 = 0,
            attr3: u8 = 0,
            attr4: u8 = 0,
            attr5: u8 = 0,
            attr6: u8 = 0,
            attr7: u8 = 0,

            pub const DEVICE_nGnRnE = 0b0000_00_00;
            pub const DEVICE_nGnRE = 0b0000_01_00;
            pub const DEVICE_nGRE = 0b0000_10_00;
            pub const DEVICE_GRE = 0b0000_11_00;

            pub const NORMAL_WRITEBACK_TRANSIENT = 0b0111_0111;
            pub const NORMAL_WRITEBACK_NONTRANSIENT = 0b1111_1111;
            pub const NORMAL_WRITETHROUGH_TRANSIENT = 0b0011_0011;
            pub const NORMAL_WRITETHROUGH_NONTRANSIENT = 0b1011_1011;
            pub const NORMAL_NONCACHEABLE = 0b0100_0100;

            pub fn load() @This() {
                return asm volatile ("mrs %[output], mair_el1"
                    : [output] "=r" (-> @This()),
                );
            }

            pub fn store(self: @This()) void {
                asm volatile ("msr mair_el1, %[input]"
                    :
                    : [input] "r" (self),
                );
            }
        };

        /// System ConTroL Register (EL1)
        /// TODO rewrite this crapy description
        pub const SCTLR_EL1 = packed struct(u64) {
            /// MMU enable for EL1&0 stage 1 address translation.
            M: bool = false, // bit 0
            /// Alignment check enable. This is the enable bit for Alignment fault checking at EL1 and EL0.
            A: bool = true, // bit 1
            /// Stage 1 Cacheability control, for data accesses.
            C: bool = false, // bit 2
            /// SP Alignment check enable (EL1).
            /// When set to true, if a load or store instruction executed at EL1 uses the SP as the base address
            /// and the SP is not aligned to a 16-byte boundary, then an SP alignment fault exception is generated.
            SA: bool = true, // bit 3
            /// SP Alignment check enable (EL0).
            /// When set to true, if a load or store instruction executed at EL0 uses the SP as the base address
            /// and the SP is not aligned to a 16-byte boundary, then an SP alignment fault exception is generated.
            SA0: bool = true, // bit 4
            /// CP15BEN when FEAT_AA32EL0 is implemented
            _reserved5: u1 = 0, // bit 5
            /// nAA when FEAT_LSE2 is implemented
            _reserved6: u1 = 0, // bit 6
            /// ITD when FEAT_AA32EL0 is implemented
            _reserved7: u1 = 0, // bit 7
            /// SED when FEAT_AA32EL0 is implemented
            _reserved8: u1 = 0, // bit 8
            /// User Mask Access. Traps EL0 execution of MSR and MRS instructions that access the PSTATE.{D, A, I, F} masks to EL1,
            /// or to EL2 when it is implemented and enabled for the current Security state and HCR_EL2.TGE is 1, from AArch64 state only, reported using EC syndrome value 0x18.
            /// It is a mask, "false" means the trap is enabled, "true" means that the trap is masked.
            uma: bool = false, // bit 9
            /// EnRCTX when FEAT_SPECRES is implemented
            _reserved10: u1 = 0, // bit 10
            /// EOS when FEAT_ExS is implemented
            _reserved11: u1 = 0, // bit 11
            /// Stage 1 instruction access Cacheability control, for accesses at EL0 and EL1:
            /// *If the value of SCTLR_EL1.M is 0, instruction accesses from stage 1 of the EL1&0 translation regime are to Normal, Outer Shareable, Inner Non-cacheable, Outer Non-cacheable memory.*
            I: enum(u1) { // bit 12
                /// All instruction access to Stage 1 Normal memory from EL0 and EL1 are Stage 1 Non-cacheable.
                non_cacheable = 0b00,
                /// This control has no effect on the Stage 1 Cacheability of instruction access to Stage 1 Normal memory from EL0 and EL1.
                no_effect = 0b01,
            } = .no_effect,
            /// EnDB wWhen FEAT_PAuth is implemented
            _reserved13: u1 = 0, // bit 13
            /// Traps EL0 execution of the following instructions to EL1, or to EL2 when it is implemented and enabled for the current Security state and HCR_EL2.TGE is 1, from AArch64 state only, reported using EC syndrome value 0x18:
            ///
            /// - DC ZVA.
            /// - If FEAT_MTE is implemented, DC GVA and DC GZVA.
            /// - If FEAT_MTETC is implemented, DC GBVA and DC ZGBVA.
            ///
            /// Traps EL0 execution of DC ZVA instructions to EL1, or to EL2 when it is implemented and enabled for the current Security state and HCR_EL2.TGE is 1, from AArch64 state only, reported using EC syndrome value 0x18.
            DZE: enum(u1) { // bit 14
                /// Any attempt to execute an instruction that this trap applies to at EL0 using AArch64 is trapped.
                trapped = 0b0,
                /// This control does not cause any instructions to be trapped.
                not_trapped = 0b1,
            } = .trapped,
            /// Traps EL0 accesses to the CTR_EL0 to EL1, or to EL2 when it is implemented and enabled for the current Security state and HCR_EL2.TGE is 1, from AArch64 state only, reported using EC syndrome value 0x18.
            UCT: enum(u1) { // bit 15
                /// Accesses to the CTR_EL0 from EL0 using AArch64 are trapped.
                trapped = 0b0,
                /// This control does not cause any instructions to be trapped.
                not_trapped = 0b1,
            } = .trapped,
            /// Traps EL0 execution of WFI instructions to EL1, or to EL2 when it is implemented and enabled for the current Security state and HCR_EL2.TGE is 1, from both Execution states, reported using EC syndrome value 0x01.
            nTWI: enum(u1) { // bit 16
                /// Any attempt to execute a WFI instruction at EL0 is trapped, if the instruction would otherwise have caused the PE to enter a low-power state.
                trapped = 0b0,
                /// This control does not cause any instructions to be trapped.
                not_trapped = 0b1,
            } = .trapped,
            _reserved17: u1 = 0, // bit 17
            /// Traps EL0 execution of WFE instructions to EL1, or to EL2 when it is implemented and enabled for the current Security state and HCR_EL2.TGE is 1, from both Execution states, reported using EC syndrome value 0x01.
            nTWE: enum(u1) { // bit 18
                /// Any attempt to execute a WFE instruction at EL0 is trapped, if the instruction would otherwise have caused the PE to enter a low-power state.
                trapped = 0b0,
                /// This control does not cause any instructions to be trapped.
                not_trapped = 0b1,
            } = .trapped,
            /// Write permission implies XN (Execute-never). For the EL1&0 translation regime, this bit can restrict execute permissions on writeable pages.
            WXN: bool = false, // bit 19
            /// TODO
            _todo: u44 = 0, // bit 20-63

            pub fn load() @This() {
                return asm volatile ("mrs %[output], sctlr_el1"
                    : [output] "=r" (-> @This()),
                );
            }

            pub fn store(self: @This()) void {
                asm volatile ("msr sctlr_el1, %[input]"
                    :
                    : [input] "r" (self),
                );
            }
        };

        /// AArch64 Processor Feature Register 0
        pub const ID_AA64PFR0_EL1 = packed struct(u64) {
            /// EL0 Exception level handling.
            el0: enum(u4) { // bit 0-3
                aa64_only = 0b0001,
                aa32_and_aa64 = 0b0010,
            },
            /// EL1 Exception level handling.
            el1: enum(u4) { // bit 4-7
                aa64_only = 0b0001,
                aa32_and_aa64 = 0b0010,
            },
            /// EL2 Exception level handling.
            el2: enum(u4) { // bit 8-11
                not_implemented = 0b0000,
                aa64_only = 0b0001,
                aa32_and_aa64 = 0b0010,
            },
            /// EL3 Exception level handling.
            el3: enum(u4) { // bit 12-15
                not_implemented = 0b0000,
                aa64_only = 0b0001,
                aa32_and_aa64 = 0b0010,
            },
            /// Floating-point.
            fp: enum(u4) { // bit 16-19
                /// Floating-point is implemented, and includes support for:
                ///
                /// - Single-precision and double-precision floating-point types.
                /// - Conversions between single-precision and half-precision data types, and double-precision and half-precision data types.
                base_implementation = 0b0000,
                /// Also includes support for half-precision floating-point arithmetic.
                half_precision = 0b0001,
                not_implemented = 0b1111,
            },
            /// Advanced SIMD.
            adv_simd: enum(u4) { // bit 20-23
                /// Advanced SIMD is implemented, including support for the following SISD and SIMD operations:
                ///
                /// - Integer byte, halfword, word and doubleword element operations.
                /// - Single-precision and double-precision floating-point arithmetic.
                /// - Conversions between single-precision and half-precision data types, and double-precision and half-precision data types.base_implementation = 0b0000,
                base_implementation = 0b0000,
                /// Also includes support for half-precision floating-point arithmetic.
                half_precision = 0b0001,
                not_implemented = 0b1111,
            },
            gic: enum(u4) { // bit 24-27
                gic_cpu_not_implemented = 0b0000,
                gic_cpu_v3_v4 = 0b0001,
                gic_cpu_v4_1 = 0b0011,
            },
            /// RAS Extension version. TODO.
            ras: u4, // 28-31
            /// Scalable Vector Extension.
            sve: enum(u4) { // 32-35
                not_implemented = 0b0000,
                implemented = 0b0001,
            },
            _todo: u28, // bit 35-63

            pub fn load() @This() {
                return asm volatile ("mrs %[output], id_aa64pfr0_el1"
                    : [output] "=r" (-> @This()),
                );
            }
        };

        /// AArch64 Memory Model Feature Register 0 (EL1)
        pub const ID_AA64MMFR0_EL1 = packed struct(u64) {
            /// Physical Address range supported.
            pa_range: enum(u4) { // bit 0-3
                @"32bits_4gb" = 0b0000,
                @"36bits_64gb" = 0b0001,
                @"40bits_1tb" = 0b0010,
                @"42bits_4tb" = 0b0011,
                @"44bits_16tb" = 0b0100,
                @"48bits_256tb" = 0b0101,
                /// When FEAT_LPA is implemented
                @"52bits_4pb" = 0b0110,
                /// When FEAT_D128 is implemented
                @"56bits_64pb" = 0b0111,
            },
            _todo1: u4,
            _todo2: u4,
            _todo3: u4,
            _todo4: u4,
            _todo5: u4,
            _todo6: u4,
            _todo7: u4,
            _todo8: u4,
            _todo9: u4,
            _todo10: u4,
            _todo11: u4,
            _todo12: u4,
            _todo13: u4,
            _todo14: u4,
            _todo15: u4,

            pub fn load() @This() {
                return asm volatile ("mrs %[output], id_aa64mmfr0_el1"
                    : [output] "=r" (-> @This()),
                );
            }
        };

        pub const ID_AA64MMFR1_EL1 = packed struct(u64) {
            /// Hardware updates to Access flag and Dirty state in translation tables.
            hafdbs: enum(u4) { // bit 0-3
                /// Hardware update of the Access flag and dirty state are not supported.
                not_supported = 0b0000,
                /// Support for hardware update of the Access flag for Block and Page descriptors.
                base_support = 0b0001,
                /// As 0b0001, and adds support for hardware update of dirty state.
                dirty_state = 0b0010,
                /// As 0b0010, and adds support for hardware update of the Access flag for Table descriptors.
                access_flag_table_desc = 0b0011,
                /// As 0b0011, and adds support for hardware tracking of Dirty state Structure.
                track_dirty_state_struct = 0b0100,
            },
            /// Number of VMID bits.
            vmid_bits: enum(u4) { // bit 4-7
                /// 8 bits.
                u8 = 0b0000,
                /// 16 bits.
                u16 = 0b0010,
            },
            /// Virtualization Host Extensions.
            vh: enum(u4) { // bit 8-11
                unsupported = 0b0000,
                supported = 0b0001,
            },

            _todo3: u4,
            _todo4: u4,
            _todo5: u4,
            _todo6: u4,
            _todo7: u4,
            _todo8: u4,
            _todo9: u4,
            _todo10: u4,
            _todo11: u4,
            _todo12: u4,
            _todo13: u4,
            _todo14: u4,
            _todo15: u4,

            pub fn load() @This() {
                return asm volatile ("mrs %[output], id_aa64mmfr1_el1"
                    : [output] "=r" (-> @This()),
                );
            }
        };

        pub const ID_AA64MMFR2_EL1 = packed struct(u64) {
            _todo0: u4,
            _todo1: u4,
            _todo2: u4,
            _todo3: u4,
            _todo4: u4,
            _todo5: u4,
            _todo6: u4,
            _todo7: u4,
            _todo8: u4,
            _todo9: u4,
            _todo10: u4,
            _todo11: u4,
            _todo12: u4,
            _todo13: u4,
            _todo14: u4,
            _todo15: u4,

            pub fn load() @This() {
                return asm volatile ("mrs %[output], id_aa64mmfr2_el1"
                    : [output] "=r" (-> @This()),
                );
            }
        };

        pub const ID_AA64MMFR3_EL1 = packed struct(u64) {
            /// TCR Extension. Indicates support for extension of TCR_ELx.
            tcrx: enum(u4) {
                /// TCR2_EL1, TCR2_EL2, and their associated trap controls are not implemented.
                not_implemented = 0b0000,
                /// TCR2_EL1, TCR2_EL2, and their associated trap controls are implemented.
                implemented = 0b0001,
            },

            /// SCTLR Extension. Indicates support for extension of SCTLR_ELx.
            sctlrx: enum(u4) {
                /// SCTLR2_EL1, SCTLR2_EL2, SCTLR2_EL3 registers, and their associated trap controls are not implemented.
                not_implemented = 0b0000,
                /// SCTLR2_EL1, SCTLR2_EL2, SCTLR2_EL3 resisters, and their associated trap controls are implemented.
                implemented = 0b0001,
            },

            /// Stage 1 Permission Indirection. Indicates support for Permission Indirection at stage 1.
            s1pie: enum(u4) {
                not_supported = 0b0000,
                supported = 0b0001,
            },

            _todo3: u4,
            _todo4: u4,
            _todo5: u4,
            _todo6: u4,
            _todo7: u4,
            _todo8: u4,
            _todo9: u4,
            _todo10: u4,
            _todo11: u4,
            _todo12: u4,
            _todo13: u4,
            _todo14: u4,
            _todo15: u4,

            pub fn load() @This() {
                return asm volatile ("mrs %[output], id_aa64mmfr3_el1"
                    : [output] "=r" (-> @This()),
                );
            }
        };

        /// Saved Program Status Register (EL1)
        pub const SPSR_EL1 = packed struct(u64) {
            /// AArch64 Exception level and selected Stack Pointer.
            mode: enum(u4) { // bit 0-3
                el0 = 0b0000,
                el1t = 0b0100,
                el1h = 0b0101,
                // TODO. there's two others
            },
            es: u1 = 0, // bit 4,
            _reserved0: u1 = 0, // bit 5
            f: bool = false, // bit 6
            i: bool = false, // bit 7
            a: bool = false, // bit 8
            d: bool = false, // bit 9
            _reserved1: u18 = 0, // bit 10-17
            v: u1 = 0, // bit 28
            c: u1 = 0, // bit 29
            z: u1 = 0, // bit 30
            n: u1 = 0, // bit 31
            _reserved2: u32 = 0, // bit 32-63

            pub fn load() @This() {
                return asm volatile ("mrs %[output], spsr_el1"
                    : [output] "=r" (-> @This()),
                );
            }

            pub fn store(self: @This()) void {
                asm volatile ("msr spsr_el1, %[input]"
                    :
                    : [input] "r" (self),
                );
            }
        };

        /// Saved Program Status Register (EL2)
        pub const SPSR_EL2 = packed struct(u64) {
            /// AArch64 Exception level and selected Stack Pointer.
            mode: enum(u4) { // bit 0-3
                el0 = 0b0000,
                el1t = 0b0100,
                el1h = 0b0101,
                el2t = 0b1000,
                el2h = 0b1001,
            },
            es: u1 = 0, // bit 4,
            _reserved0: u1 = 0, // bit 5
            f: bool = false, // bit 6
            i: bool = false, // bit 7
            a: bool = false, // bit 8
            d: bool = false, // bit 9
            _reserved1: u18 = 0, // bit 10-17
            v: u1 = 0, // bit 28
            c: u1 = 0, // bit 29
            z: u1 = 0, // bit 30
            n: u1 = 0, // bit 31
            _reserved2: u32 = 0, // bit 32-63

            pub fn load() @This() {
                return asm volatile ("mrs %[output], spsr_el2"
                    : [output] "=r" (-> @This()),
                );
            }

            pub fn store(self: @This()) void {
                asm volatile ("msr spsr_el2, %[input]"
                    :
                    : [input] "r" (self),
                );
            }
        };

        pub const HCR_EL2 = packed struct(u64) {
            /// Enable Stage 2 address translation for EL0&EL1
            vm: bool = false, // bit 0
            /// Set/Way Invalidation Override
            swio: bool = true, // bit 1
            /// Protected Table Walk
            ptw: bool = false, // bit 2
            /// Physical FIQ Routing.
            fmo: bool = false, // bit 3
            /// Physical IRQ Routing.
            imo: bool = false, // bit 4
            /// Physical SError exception routing.
            amo: bool = false, // bit 5
            /// Virtual FIQ Interrupt.
            vf: bool = false, // bit 6
            /// Virtual IRQ Interrupt.
            vi: bool = false, // bit 7
            /// Virtual SError exception.
            vse: bool = false, // bit 8
            fb: u1 = 0, // bit 9
            /// Barrier Shareability upgrade.
            bsu: enum(u2) { // bit 10-11
                no_effect = 0b00,
                inner_shareable = 0b01,
                outer_shareable = 0b10,
                full_system = 0b11,
            } = .no_effect,
            /// Default Cacheability.
            default_cacheability: bool = false, // bit 12
            /// Traps EL0 and EL1 execution of WFI instructions to EL2
            twi: bool = false, // bit 13
            /// Traps EL0 and EL1 execution of WFE instructions to EL2
            twe: bool = false, // bit 14
            tid0: bool = false, // bit 15
            tid1: bool = false, // bit 16
            tid2: bool = false, // bit 17
            tid3: bool = false, // bit 18
            /// Trap SMC instruction.
            tsc: bool = false, // bit 19
            /// Trap IMPLEMENTATION DEFINED functionality.
            tidcp: bool = false, // bit 20
            /// Trap Auxiliary Control Registers.
            tacr: bool = false, // bit 21
            /// Trap data or unified cache maintenance instructions that operate by Set/Way.
            tsw: bool = false, // bit 22
            /// Trap data or unified cache maintenance instructions that operate to the Point of Coherency, Persistence, or Physical Storage.
            tpcp: bool = false, // bit 23
            /// Trap cache maintenance instructions that operate to the Point of Unification.
            tpu: bool = false, // bit 24
            /// Trap TLB maintenance instructions.
            ttlb: bool = false, // bit 25
            /// Trap Virtual Memory controls.
            tvm: bool = false, // bit 26
            /// Trap General Exceptions, from EL0.
            tge: bool = false, // bit 27
            /// Traps EL0 and EL1 execution of the following instructions to EL2, when EL2 is enabled in the current Security state, from AArch64 state only, reported using EC syndrome value 0x18
            tdz: bool = false, // bit 28
            /// HVC instruction disable.
            /// When EL3 is not implemented
            hcd: bool = false, // bit 29
            /// Trap Reads of Virtual Memory controls.
            trvm: bool = false, // bit 30
            rw: enum(u1) { // bit 31
                lower_are_aa32 = 0b0,
                el1_is_aa64 = 0b1,
            } = .lower_are_aa32,
            /// Stage 2 Data access cacheability disable.
            cd: bool = false, // bit 32
            /// Stage 2 Instruction access cacheability disable.
            id: bool = false, // bit 33
            /// EL2 Host.
            /// When FEAT_VHE is implemented.
            e2h: enum(u1) { // bit 34
                disabled = 0b0,
                enabled = 0b1,
            } = .disabled,
            /// Trap LOR registers.
            /// When FEAT_LOR is implemented.
            tlor: bool = false, // bit 35
            /// Trap accesses of Error Record registers.
            /// When FEAT_RAS is implemented
            terr: bool = false, // bit 36
            /// Route synchronous External abort exceptions to EL2.
            /// When FEAT_RAS is implemented
            tea: bool = false, // bit 37
            _reserved0: u2 = 0, // bit 38-39
            /// Trap registers holding "key" values for Pointer Authentication.
            /// When FEAT_PAuth is implemented
            apk: bool = false, // bit 40
            /// Controls the use of instructions related to Pointer Authentication
            /// When FEAT_PAuth is implemented
            api: bool = false, // bit 41
            /// Nested Virtualization.
            /// When FEAT_NV2 is implemented
            /// When FEAT_NV is implemented
            nv: bool = false, // bit 42
            /// Nested Virtualization.
            /// When FEAT_NV2 is implemented
            /// When FEAT_NV is implemented
            nv1: bool = false, // bit 43
            /// Address Translation.
            /// When FEAT_NV is implemented
            at: bool = false, // bit 44
            /// Nested Virtualization.
            /// When FEAT_NV2 is implemented
            nv2: bool = false, // bit 45
            /// Forced Write-Back.
            /// When FEAT_S2FWB is implemented
            fwb: bool = false, // bit 46
            /// Fault Injection Enable
            /// When FEAT_RASv1p1 is implemented
            fien: bool = false, // bit 47
            /// Controls the reporting of Granule protection faults at EL0 and EL1.
            /// When FEAT_RME is implemented
            gpf: bool = false, // bit 48

            // TODO
            _todo: u15 = 0, // bit 49-63

            pub fn load() @This() {
                return asm volatile ("mrs %[output], hcr_el2"
                    : [output] "=r" (-> @This()),
                );
            }

            pub fn store(self: @This()) void {
                asm volatile ("msr hcr_el2, %[input]"
                    :
                    : [input] "r" (self),
                );
            }
        };

        pub const ESR_EL1 = packed struct(u64) {
            iss: packed union { // bits 0-24
                unknown_reason: packed struct(u25) { _reserved0: u25 },
                brk_aarch64: packed struct(u25) {
                    comment: u16, // bit 0-15
                    _reserved0: u9, // bit 16-24
                },
                svc_hvc: packed struct(u25) {
                    imm16: u16, // bit 0-15
                    _reserved0: u9, // bit 16-24
                },
                data_abort: packed struct(u25) {
                    /// Data Fault Status Code.
                    dfsc: enum(u6) { // bit 0-5
                        /// Address size fault, level 0 of translation or translation table base register.
                        address_size_fault_lv0 = 0b000000,
                        /// Address size fault, level 1.
                        address_size_fault_lv1 = 0b000001,
                        /// Address size fault, level 2.
                        address_size_fault_lv2 = 0b000010,
                        /// Address size fault, level 3.
                        address_size_fault_lv3 = 0b000011,

                        /// Translation fault, level 0.
                        translation_fault_lv0 = 0b000100,
                        /// Translation fault, level 1.
                        translation_fault_lv1 = 0b000101,
                        /// Translation fault, level 2.
                        translation_fault_lv2 = 0b000110,
                        /// Translation fault, level 3.
                        translation_fault_lv3 = 0b000111,

                        /// Translation fault, level 1.
                        access_flag_lv1 = 0b001001,
                        /// Translation fault, level 2.
                        access_flag_lv2 = 0b001010,
                        /// Translation fault, level 3.
                        access_flag_lv3 = 0b001011,
                        /// Translation fault, level 0.
                        /// When FEAT_LPA2 is implemented.
                        access_flag_lv0 = 0b001000,

                        /// Permission fault, level 0.
                        /// When FEAT_LPA2 is implemented
                        permission_fault_lv0 = 0b001100,
                        /// Permission fault, level 1.
                        permission_fault_lv1 = 0b001101,
                        /// Permission fault, level 2.
                        permission_fault_lv2 = 0b001110,
                        /// Permission fault, level 3.
                        permission_fault_lv3 = 0b001111,

                        /// Synchronous External abort, not on translation table walk or hardware update of translation table.
                        synchronous_external_abort = 0b010000,

                        // TODO ...

                        alignment_fault = 0b100001,

                        // TODO ...
                    },
                    /// Write not Read. Indicates whether a synchronous abort was caused by an instruction writing to a memory location, or by an instruction reading from a memory location.
                    wnr: enum(u1) { // bit 6
                        reading = 0b0,
                        writing = 0b1,
                    },
                    /// For a stage 2 fault, indicates whether the fault was a stage 2 fault on an access made for a stage 1 translation table walk.
                    s1ptw: enum(u1) { // bit 7
                        fault_not_on_a_stage_2 = 0b0,
                        fault_on_the_stage_2 = 0b01,
                    },
                    /// TODO.
                    cm: u1, // bit 8
                    ea: u1, // bit 9
                    /// FAR Not Valid.
                    fnv: enum(u1) { // bit 10
                        valid = 0b0,
                        not_valid = 0b1,
                    },
                    _bit11_12: u2, // bit 11-12
                    _reserved0: u1, // bit 13
                    _bit14: u1, // bit 14
                    _bit15: u1, // bit 15
                    _bit16_20: u5, // bit 16-20
                    sse: u1, // bit 21
                    sas: u2, // bit 22-23
                    isv: u1,
                },
            },
            il: enum(u1) { // bit 25
                b16 = 0b0,
                b32 = 0b1,
            },
            ec: enum(u6) { // bits 26-31
                /// ISS encoding for exceptions with an unknown reason ;
                /// ISS2 encoding for all other exceptions.
                unknown_reason = 0b000000,
                trapped_wfi_wfe = 0b000001,
                trapped_mcr_mrc_cp15 = 0b000011,
                trapped_mcrr_mrrc_cp15 = 0b000100,
                trapped_mcr_mrc_cp14 = 0b000101,
                trapped_ldc_stc = 0b000110,
                trapped_sme_sve_simd_fp = 0b000111,
                trapped_ptr_auth = 0b001001,
                trapped_uncovered = 0b001010,
                trapped_mrrc_cp14 = 0b001100,
                branch_target_exception = 0b001101,
                illegal_execution = 0b001110,
                svc_inst_aarch32 = 0b010001,
                trapped_msrr_mrrs_sys_uncovered_aarch64 = 0b010100,
                /// ISS encoding for an exception from HVC or SVC instruction execution ;
                /// ISS2 encoding for all other exceptions.
                svc_inst_aarch64 = 0b010101,
                trapped_msr_mrs_sys_uncovered_aarch64 = 0b011000,
                trapped_sve = 0b011001,
                trapped_eret_erteaa_erteab = 0b011010,
                trapped_tstart = 0b011011,
                pac_fail = 0b011100,
                trapped_sme = 0b011101,
                inst_abort_lower_el = 0b100000,
                inst_abort_same_el = 0b100001,
                pc_align_fault = 0b100010,
                /// ISS encoding for an exception from a Data Abort ;
                /// ISS2 encoding for an exception from a Data Abort.
                data_abort_lower_el = 0b100100,
                /// ISS encoding for an exception from a Data Abort ;
                /// ISS2 encoding for an exception from a Data Abort.
                data_abort_same_el = 0b100101,
                sp_align_fault = 0b100110,
                mem_op = 0b100111,
                trapped_fp_aarch32 = 0b101000,
                trapped_fp_aarch64 = 0b101100,
                gcs = 0b101101,
                serror = 0b101111,
                breakpoint_lower_el = 0b110000,
                breakpoint_same_el = 0b110001,
                software_step_lower_el = 0b110010,
                software_step_same_el = 0b110011,
                watchpoint_lower_el = 0b110100,
                watchpoint_same_el = 0b110101,
                bkpt_aarch32 = 0b111000,
                brk_aarch64 = 0b111100,
                profiling = 0b111101,
            },
            iss2: packed union { // bit 32-55
                // TODO ...
                all_others: packed struct(u24) { _reserved0: u24 },
            },
            _reserved0: u8, // bit 56-63

            pub fn load() @This() {
                return asm volatile ("mrs %[output], esr_el1"
                    : [output] "=r" (-> @This()),
                );
            }

            pub fn dump(self: @This()) void {
                std.log.info(
                    \\ 
                    \\ -------- ESR_EL1 --------
                    \\
                    \\ iss {}
                    \\ il {s}
                    \\ ec {s}
                    \\
                    \\ -------------------------
                , .{
                    self.iss,
                    @tagName(self.il),
                    @tagName(self.ec),
                });
            }
        };

        pub const CPACR_EL1 = packed struct(u64) {
            _reserved0: u16, // [0..15] Reserved (RES0)
            zen: u2, // [16..17] SVE access
            _reserved1: u2, // [18..19] Reserved (RES0)
            fpen: enum(u2) { // [20..21] Floating-point/SIMD access
                off = 0b00,
                el1 = 0b01,
                el0_el1 = 0b11,
            },
            smen: u2, // [22..23] SME (Scalable Matrix Extension) access
            _reserved2: u4, // [24..27] Reserved (RES0)
            tta: bool, // [28] Trace Trap Access
            _reserved3: u3, // [29..31] Reserved (RES0)
            _reserved4: u32, // [32..63] Reserved (RES0)

            pub fn load() @This() {
                return asm volatile ("mrs %[output], cpacr_el1"
                    : [output] "=r" (-> @This()),
                );
            }

            pub fn store(self: @This()) void {
                asm volatile ("msr cpacr_el1, %[input]"
                    :
                    : [input] "r" (self),
                );
            }
        };

        /// Multiprocessor Affinity Register (EL1)
        pub const MPIDR_EL1 = packed struct(u64) {
            aff0: u8, // bit 0-7
            aff1: u8, // bit 8-15
            aff2: u8, // bit 16-23
            mt: enum(u1) { // bit 24
                independent = 0b00,
                interdependent = 0b01,
            },
            _reserved0: u5, // bit 25-29
            u: enum(u1) { // bit 30
                multiprocessor = 0b00,
                uniprocessor = 0b01,
            },
            _reserved1: u1, // bit 31
            aff3: u8, // bit 32-39
            _reserved2: u24, // bit 40-63

            pub fn load() @This() {
                return asm volatile ("mrs %[output], mpidr_el1"
                    : [output] "=r" (-> @This()),
                );
            }
        };

        /// Architectural Feature Trap Register (EL2)
        pub const CPTR_EL2 = packed struct(u64) {
            _reserved0: u8 = 0b11111111, // bit 0-7
            /// Traps execution at EL2, EL1, and EL0 of SVE instructions and instructions that directly access the ZCR_EL2 or ZCR_EL1 System registers to EL2,
            /// when EL2 is enabled in the current Security state.
            ///
            /// When FEAT_SVE is implemented
            tz: bool = true, // bit 8
            _reserved1: u1 = 0b1, // bit 9
            /// Traps execution of instructions which access the Advanced SIMD and floating-point functionality, from both Execution states to EL2, when EL2 is enabled in the current Security state.
            tfp: bool = true, // bit 10
            _reserved2: u1 = 0, // bit 11
            _reserved3: u2 = 0b11, // bit 12-13
            _reserved4: u6 = 0, // bit 14-19
            /// Traps System register accesses to all implemented trace registers from both Execution states to EL2, when EL2 is enabled in the current Security state.
            tta: bool = true, // bit 20
            _reserved5: u9 = 0, // bit 21-29
            /// Trap Activity Monitor access.
            ///
            /// When FEAT_AMUv1 is implemented
            tam: bool = false, // bit 30
            tcpac: bool = false, // bit 31
            _reserved6: u32 = 0, // bit 32-63

            pub fn load() @This() {
                return asm volatile ("mrs %[output], cptr_el2"
                    : [output] "=r" (-> @This()),
                );
            }

            pub fn store(self: @This()) void {
                asm volatile ("msr cptr_el2, %[input]"
                    :
                    : [input] "r" (self),
                );
            }
        };
    };
};

pub const cpu = struct {
    pub fn halt() noreturn {
        while (true) {
            switch (builtin.cpu.arch) {
                .aarch64, .riscv64 => asm volatile ("wfi"),
                else => {},
            }
        }
    }
};
