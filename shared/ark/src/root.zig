const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;

pub const cpu = struct {
    pub fn halt() noreturn {
        while (true) {
            switch (builtin.cpu.arch) {
                .aarch64, .riscv64 => asm volatile ("wfi"),
                else => {},
            }
        }
    }

    pub const armv8a_64 = struct {
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
                    : [out] "={x0}" (-> u64)
                    : [in0] "{x0}" (self.x0), [in1] "{x1}" (self.x1), 
                      [in2] "{x2}" (self.x2), [in3] "{x3}" (self.x3), 
                      [in4] "{x4}" (self.x4), [in5] "{x5}" (self.x5),
                      [in6] "{x6}" (self.x6), [in7] "{x7}" (self.x7),
                    : "memory"
                );
            }

            pub fn secureMonitorCall(self: *@This()) u64 {
                _ = self;
                unreachable;
                // return asm volatile (
                //     \\ smc #0
                //     : [out] "={x0}" (-> u64)
                //     : [in0] "{x0}" (self.x0), [in1] "{x1}" (self.x1), 
                //       [in2] "{x2}" (self.x2), [in3] "{x3}" (self.x3), 
                //       [in4] "{x4}" (self.x4), [in5] "{x5}" (self.x5),
                //       [in6] "{x6}" (self.x6), [in7] "{x7}" (self.x7),
                //     : "memory"
                // );
            }
        };

        pub const registers = struct {
            pub const TTBR0_EL1 = packed struct(u64) {
                l0_table: u64,

                pub fn get() @This() {
                    const ttbr0_el1: u64 = asm volatile (
                        \\ mrs %[result], ttbr0_el1
                        : [result] "=r" (-> u64),
                    );

                    return .{ .l0_table = ttbr0_el1 };
                }

                pub fn set(self: @This()) void {
                    asm volatile (
                        \\ msr ttbr0_el1, %[input]
                        :
                        : [input] "r" (self.l0_table),
                        : "memory"
                    );
                }
            };

            pub const TTBR1_EL1 = packed struct(u64) {
                l0_table: u64,

                pub fn get() @This() {
                    const ttbr1_el1: u64 = asm volatile (
                        \\ mrs %[result], ttbr1_el1
                        : [result] "=r" (-> u64),
                    );

                    return .{ .l0_table = ttbr1_el1 };
                }

                pub fn set(self: @This()) void {
                    asm volatile (
                        \\ msr ttbr1_el1, %[input]
                        :
                        : [input] "r" (self.l0_table),
                        : "memory"
                    );
                }
            };

            /// Translation Control Register (EL1)
            pub const TCR_EL1 = packed struct(u64) {
                /// The size offset of the memory region addressed by TTBR0_EL1. The region size is 2(64-t0sz) bytes.
                t0sz: u6, // bit 0-5
                _reserved0: u1, // bit 6
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
                    _4kb = 0b00,
                    _64kb = 0b01,
                    _16kb = 0b10,
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
                    _16kb = 0b01,
                    _4kb = 0b10,
                    _64kb = 0b11,
                },
                /// TODO
                ips: u3, // bit 32-34
                _reserved1: u1, // bit 35
                /// ASID Size.
                as: enum(u1) { // bit 36
                    /// The upper 8 bits of TTBR0_EL1 and TTBR1_EL1 are ignored by hardware for every purpose except reading back the register,
                    /// and are treated as if they are all zeros for when used for allocation and matching entries in the TLB.
                    u8 = 0b0,
                    /// The upper 16 bits of TTBR0_EL1 and TTBR1_EL1 are used for allocation and matching in the TLB.
                    u16 = 0b1,
                },
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
                /// TODO not exactly reserved, since it corresponds to optional features.
                _reserved2: u25, // bit 39-63

                pub fn get() @This() {
                    const tcr_el1: TCR_EL1 = asm volatile (
                        \\ mrs %[result], tcr_el1
                        : [result] "=r" (-> TCR_EL1),
                    );

                    return tcr_el1;
                }

                pub fn set(self: @This()) void {
                    asm volatile (
                        \\ msr tcr_el1, %[input]
                        :
                        : [input] "r" (self),
                        : "memory"
                    );
                }
            };

            /// Memory Attribute Indirection Register (EL1)
            pub const MAIR_EL1 = packed struct(u64) {
                attr0: u8,
                attr1: u8,
                attr2: u8,
                attr3: u8,
                attr4: u8,
                attr5: u8,
                attr6: u8,
                attr7: u8,

                pub const DEVICE_nGnRnE = 0b0000_00_00;
                pub const DEVICE_nGnRE = 0b0000_01_00;
                pub const DEVICE_nGRE = 0b0000_10_00;
                pub const DEVICE_GRE = 0b0000_11_00;

                pub const NORMAL_WRITEBACK_TRANSIENT = 0b0111_0111;
                pub const NORMAL_WRITEBACK_NONTRANSIENT = 0b1111_1111;
                pub const NORMAL_WRITETHROUGH_TRANSIENT = 0b0011_0011;
                pub const NORMAL_WRITETHROUGH_NONTRANSIENT = 0b1011_1011;
                pub const NORMAL_NONCACHEABLE = 0b0100_0100;

                pub fn get() @This() {
                    const mair_el1: @This() = asm volatile (
                        \\ mrs %[result], mair_el1
                        : [result] "=r" (-> @This()),
                    );

                    return mair_el1;
                }

                pub fn set(self: @This()) void {
                    asm volatile (
                        \\ msr mair_el1, %[input]
                        :
                        : [input] "r" (self),
                        : "memory"
                    );
                }
            };

            /// System ConTroL Register (EL1)
            pub const SCTLR_EL1 = packed struct(u64) {
                /// MMU enable for EL1&0 stage 1 address translation.
                M: bool, // bit 0
                /// Alignment check enable. This is the enable bit for Alignment fault checking at EL1 and EL0.
                A: bool, // bit 1
                /// Stage 1 Cacheability control, for data accesses.
                C: bool, // bit 2
                /// SP Alignment check enable (EL1).
                /// When set to true, if a load or store instruction executed at EL1 uses the SP as the base address
                /// and the SP is not aligned to a 16-byte boundary, then an SP alignment fault exception is generated.
                SA: bool, // bit 3
                /// SP Alignment check enable (EL0).
                /// When set to true, if a load or store instruction executed at EL0 uses the SP as the base address
                /// and the SP is not aligned to a 16-byte boundary, then an SP alignment fault exception is generated.
                SA0: bool, // bit 4
                /// CP15BEN when FEAT_AA32EL0 is implemented
                _reserved5: u1, // bit 5
                /// nAA when FEAT_LSE2 is implemented
                _reserved6: u1, // bit 6
                /// ITD when FEAT_AA32EL0 is implemented
                _reserved7: u1, // bit 7
                /// SED when FEAT_AA32EL0 is implemented
                _reserved8: u1, // bit 8
                /// User Mask Access. Traps EL0 execution of MSR and MRS instructions that access the PSTATE.{D, A, I, F} masks to EL1,
                /// or to EL2 when it is implemented and enabled for the current Security state and HCR_EL2.TGE is 1, from AArch64 state only, reported using EC syndrome value 0x18.
                /// It is a mask, "false" means the trap is enabled, "true" means that the trap is masked.
                uma: bool, // bit 9
                /// EnRCTX when FEAT_SPECRES is implemented
                _reserved10: u1, // bit 10
                /// EOS when FEAT_ExS is implemented
                _reserved11: u1, // bit 11
                /// Stage 1 instruction access Cacheability control, for accesses at EL0 and EL1:
                /// *If the value of SCTLR_EL1.M is 0, instruction accesses from stage 1 of the EL1&0 translation regime are to Normal, Outer Shareable, Inner Non-cacheable, Outer Non-cacheable memory.*
                I: enum(u1) { // bit 12
                    /// All instruction access to Stage 1 Normal memory from EL0 and EL1 are Stage 1 Non-cacheable.
                    non_cacheable = 0b00,
                    /// This control has no effect on the Stage 1 Cacheability of instruction access to Stage 1 Normal memory from EL0 and EL1.
                    no_effect = 0b01,
                },
                /// EnDB wWhen FEAT_PAuth is implemented
                _reserved13: u1, // bit 13
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
                },
                /// Traps EL0 accesses to the CTR_EL0 to EL1, or to EL2 when it is implemented and enabled for the current Security state and HCR_EL2.TGE is 1, from AArch64 state only, reported using EC syndrome value 0x18.
                UCT: enum(u1) { // bit 15
                    /// Accesses to the CTR_EL0 from EL0 using AArch64 are trapped.
                    trapped = 0b0,
                    /// This control does not cause any instructions to be trapped.
                    not_trapped = 0b1,
                },
                /// Traps EL0 execution of WFI instructions to EL1, or to EL2 when it is implemented and enabled for the current Security state and HCR_EL2.TGE is 1, from both Execution states, reported using EC syndrome value 0x01.
                nTWI: enum(u1) { // bit 16
                    /// Any attempt to execute a WFI instruction at EL0 is trapped, if the instruction would otherwise have caused the PE to enter a low-power state.
                    trapped = 0b0,
                    /// This control does not cause any instructions to be trapped.
                    not_trapped = 0b1,
                },
                _reserved17: u1, // bit 17
                /// Traps EL0 execution of WFE instructions to EL1, or to EL2 when it is implemented and enabled for the current Security state and HCR_EL2.TGE is 1, from both Execution states, reported using EC syndrome value 0x01.
                nTWE: enum(u1) { // bit 18
                    /// Any attempt to execute a WFE instruction at EL0 is trapped, if the instruction would otherwise have caused the PE to enter a low-power state.
                    trapped = 0b0,
                    /// This control does not cause any instructions to be trapped.
                    not_trapped = 0b1,
                },
                /// Write permission implies XN (Execute-never). For the EL1&0 translation regime, this bit can restrict execute permissions on writeable pages.
                WXN: bool, // bit 19
                /// TODO
                _todo: u44, // bit 20-63

                pub fn get() @This() {
                    const sctlr_el1: @This() = asm volatile (
                        \\ mrs %[result], sctlr_el1
                        : [result] "=r" (-> @This()),
                    );

                    return sctlr_el1;
                }

                pub fn set(self: @This()) void {
                    asm volatile (
                        \\ msr sctlr_el1, %[input]
                        :
                        : [input] "r" (self),
                        : "memory"
                    );
                }
            };

            /// Vector Base Address Register (EL1)
            pub const VBAR_EL1 = packed struct(u64) {
                vba: u64,

                pub fn get() @This() {
                    const vbar_el1: @This() = asm volatile (
                        \\ mrs %[result], vbar_el1
                        : [result] "=r" (-> @This()),
                    );

                    return vbar_el1;
                }

                pub fn set(self: @This()) void {
                    asm volatile (
                        \\ msr vbar_el1, %[input]
                        :
                        : [input] "r" (self),
                        : "memory"
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

                pub fn get() @This() {
                    const id_aa64pfr0_el1: @This() = asm volatile (
                        \\ mrs %[result], id_aa64pfr0_el1
                        : [result] "=r" (-> @This()),
                    );

                    return id_aa64pfr0_el1;
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

                pub fn get() @This() {
                    const spsr_el1: @This() = asm volatile (
                        \\ mrs %[result], spsr_el1
                        : [result] "=r" (-> @This()),
                    );

                    return spsr_el1;
                }

                pub fn set(self: @This()) void {
                    asm volatile (
                        \\ msr spsr_el1, %[input]
                        :
                        : [input] "r" (self),
                        : "memory"
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

                pub fn get() @This() {
                    const esr_el1: @This() = asm volatile (
                        \\ mrs %[result], esr_el1
                        : [result] "=r" (-> @This()),
                    );
                    return esr_el1;
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

                pub fn get() @This() {
                    const cpacr_el1: @This() = asm volatile (
                        \\ mrs %[result], cpacr_el1
                        : [result] "=r" (-> @This()),
                    );

                    return cpacr_el1;
                }

                pub fn set(self: @This()) void {
                    asm volatile (
                        \\ msr cpacr_el1, %[input]
                        :
                        : [input] "r" (self),
                        : "memory"
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

                pub fn get() @This() {
                    const mpidr_el1: @This() = asm volatile (
                        \\ mrs %[result], mpidr_el1
                        : [result] "=r" (-> @This()),
                    );

                    return mpidr_el1;
                }
            };

            pub const FAR_EL1 = packed struct(u64) {
                address: u64,

                pub fn get() @This() {
                    const far_el1: @This() = asm volatile (
                        \\ mrs %[result], far_el1
                        : [result] "=r" (-> @This()),
                    );

                    return far_el1;
                }
            };

            pub const TPIDR_EL0 = packed struct(u64) {
                value: u64,

                pub fn get() @This() {
                    const tpidr_el0: @This() = asm volatile (
                        \\ mrs %[result], tpidr_el0
                        : [result] "=r" (-> @This()),
                    );

                    return tpidr_el0;
                }

                pub fn set(self: @This()) void {
                    asm volatile (
                        \\ msr tpidr_el0, %[input]
                        :
                        : [input] "r" (self),
                        : "memory"
                    );
                }
            };

            pub const TPIDR_EL1 = packed struct(u64) {
                value: u64,

                pub fn get() @This() {
                    const tpidr_el1: @This() = asm volatile (
                        \\ mrs %[result], tpidr_el1
                        : [result] "=r" (-> @This()),
                    );

                    return tpidr_el1;
                }

                pub fn set(self: @This()) void {
                    asm volatile (
                        \\ msr tpidr_el1, %[input]
                        :
                        : [input] "r" (self),
                        : "memory"
                    );
                }
            };

            pub const TPIDRRO_EL0 = packed struct(u64) {
                value: u64,

                pub fn get() @This() {
                    const tpidrro_el0: @This() = asm volatile (
                        \\ mrs %[result], tpidrro_el0
                        : [result] "=r" (-> @This()),
                    );

                    return tpidrro_el0;
                }

                pub fn set(self: @This()) void {
                    asm volatile (
                        \\ msr tpidrro_el0, %[input]
                        :
                        : [input] "r" (self),
                        : "memory"
                    );
                }
            };
        };

        pub const pagging = struct {
            const BlockDescriptor = packed struct(u64) {
                valid: bool = true, // bit 0
                block_type: enum(u1) { // bit 1
                    block = 0,
                    table_page = 1,
                },
                attr_index: enum(u3) { // bit 2-4
                    device = 0,
                    non_cacheable = 1,
                    writethrough = 2,
                    writeback = 3,
                } = .writeback,
                non_secure: bool = true, // bit 5
                ap: enum(u2) { // bit 6-7
                    rw_el1 = 0b00,
                    rw_el0 = 0b01,
                    ro_el1 = 0b10,
                    ro_el0 = 0b11,
                } = .rw_el1,
                sh: enum(u2) { // bit 8-9
                    non_shareable = 0b00,
                    _reserved = 0b01,
                    outer_shareable = 0b10,
                    inner_shareable = 0b11,
                } = .outer_shareable,
                access_flag: bool = true, // bit 10
                not_global: bool = false, // bit 11
                output_addr: u36 = 0, // bit 12-47
                _reserved1: u3 = 0, // bit 48-50
                dbm: bool = true, // bit 51
                contiguous: bool = false, // bit 52
                pxn: bool = false, // bit 53
                uxn: bool = false, // bit 54
                _os_available: u4 = 0, // bit 55-58
                impl_def: u4 = 0, // bit 59-62
                _reserved3: u1 = 0, // bit 63
            };

            fn get_table(table_addr: u64, index: u64) ?u64 {
                const entry: *BlockDescriptor = @ptrFromInt(table_addr + index * 8);

                if (entry.valid and entry.block_type == .table_page) {
                    return entry.output_addr << 12;
                }

                return null;
            }

            fn ensure_table(page_allocator: mem.PageAllocator, table_addr: u64, index: u64) u64 {
                const entry: *BlockDescriptor = @ptrFromInt(table_addr + index * 8);

                if (entry.valid and entry.block_type == .table_page) {
                    return entry.output_addr << 12;
                }

                const new_table = page_allocator.alloc(1) catch @panic("unable to allocate a page_table");
                @memset(new_table[0..4096], 0);

                entry.* = BlockDescriptor{
                    .block_type = .table_page,
                    .output_addr = @truncate(@intFromPtr(new_table) >> 12),
                };

                return @intFromPtr(new_table);
            }

            pub fn free_table_recursive(page_allocator: mem.PageAllocator, table_addr: u64, level: u8) void {
                for (0..512) |i| {
                    const e_ptr: *BlockDescriptor = @ptrFromInt(table_addr + i * 8);
                    const entry = e_ptr.*;

                    if (!entry.valid) continue;

                    if (entry.block_type == .table_page and level != 3) {
                        free_table_recursive(page_allocator, entry.output_addr << 12, level + 1);
                    } else {
                        page_allocator.free(@ptrFromInt(entry.output_addr << 12), 1);
                    }
                }

                page_allocator.free(@ptrFromInt(table_addr), 1);
            }

            pub fn map_page(
                page_allocator: mem.PageAllocator,
                space: *mem.VirtualSpace,
                virt_addr: u64,
                phys_addr: u64,
                page_level: mem.PageLevel,
                flags: mem.MemoryFlags,
                /// hint
                contiguous_segment: bool,
            ) void {
                const l0 = (virt_addr >> 39) & 0x1FF;
                const l1 = (virt_addr >> 30) & 0x1FF;
                const l2 = (virt_addr >> 21) & 0x1FF;
                const l3 = (virt_addr >> 12) & 0x1FF;

                var block_descriptor = BlockDescriptor{
                    .block_type = .table_page,
                    .attr_index = if (flags.device) .device else if (flags.writethrough) .writethrough else .writeback,
                    .ap = if (flags.writable and !flags.user) .rw_el1 else if (flags.writable and flags.user) .rw_el0 else if (!flags.writable and !flags.user) .ro_el1 else .ro_el0,
                    .output_addr = @truncate(phys_addr >> 12),
                    .pxn = !flags.executable or flags.user,
                    .uxn = !flags.executable or !flags.user,
                    .contiguous = contiguous_segment,
                };

                var tp = @intFromPtr(space.l0_table);
                tp = ensure_table(page_allocator, tp, l0);
                switch (page_level) {
                    .l1G => {
                        const p: *BlockDescriptor = @ptrFromInt(tp + l1 * 8);
                        if (p.valid and p.block_type == .table_page) {
                            free_table_recursive(page_allocator, p.output_addr << 12, 1);
                        }
                        block_descriptor.block_type = .block;
                        p.* = block_descriptor;
                    },
                    .l2M => {
                        tp = ensure_table(page_allocator, tp, l1);
                        const p: *BlockDescriptor = @ptrFromInt(tp + l2 * 8);
                        if (p.valid and p.block_type == .table_page) {
                            free_table_recursive(page_allocator, p.output_addr << 12, 2);
                        }
                        block_descriptor.block_type = .block;
                        p.* = block_descriptor;
                    },
                    .l4K => {
                        tp = ensure_table(page_allocator, tp, l1);
                        tp = ensure_table(page_allocator, tp, l2);
                        const p: *BlockDescriptor = @ptrFromInt(tp + l3 * 8);
                        p.* = block_descriptor;
                    },
                }

                asm volatile (
                    \\ dsb sy
                    \\ isb
                );
            }

            pub fn flush(virt_addr: u64) void {
                const va = virt_addr >> mem.PageLevel.l4K.shift();

                asm volatile (
                    \\ tlbi vae1is, %[va]
                    \\ dsb ish
                    \\ isb
                    :
                    : [va] "r" (va),
                    : "memory"
                );
            }

            pub fn flush_all() void {
                asm volatile (
                    \\ dsb ish
                    \\ tlbi vmalle1
                    \\ dsb ish
                    \\ isb
                    ::: "memory");
            }
        };
    };
};

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

    /// Do not use as std.heap.PageAllocator
    pub const PageAllocator = struct {
        pub const AllocError = error{OutOfMemory};

        ctx: *anyopaque,
        _alloc: *const fn (ctx: *anyopaque, count: usize) AllocError![*]align(0x1000) u8,
        _free: *const fn (ctx: *anyopaque, addr: [*]align(0x1000) u8, count: usize) void,

        pub fn alloc(self: PageAllocator, count: usize) AllocError![*]align(0x1000) u8 {
            return self._alloc(self.ctx, count);
        }

        pub fn free(self: PageAllocator, addr: [*]align(0x1000) u8, count: usize) void {
            return self._free(self.ctx, addr, count);
        }
    };

    pub const VirtualReservation = struct {
        space: *VirtualSpace,
        virt: u64,
        size: usize,

        pub fn address(self: VirtualReservation) u64 {
            return self.space.base() | self.virt;
        }

        pub fn unreserve(self: VirtualReservation) void {
            _ = self;
            unreachable;
        }

        pub fn map_contiguous(self: @This(), page_allocator: mem.PageAllocator, phys_addr: u64, flags: MemoryFlags) void {
            const virt_addr = self.address();

            var offset: usize = 0;
            for (0..self.size) |_| {
                const virta = virt_addr + offset;
                const physa = phys_addr + offset;
                switch (builtin.cpu.arch) {
                    .aarch64 => cpu.armv8a_64.pagging.map_page(page_allocator, self.space, virta, physa, .l4K, flags, false), // TODO implement contiguous mapping
                    else => unreachable,
                }
                offset += 0x1000;
            }
        }

        // pub fn map_noncontiguous(self: @This(), virt_offset: u64, pages: []u64, level: phys.PageLevel, flags: MapFlags) void {
        //     std.debug.assert(std.mem.isAligned(virt_offset, level.size()));
        //     std.debug.assert((pages.len << level.shift()) + virt_offset <= range.len());

        //     const virt_base = range.base(self);

        //     var offset: usize = virt_offset;
        //     for (0..pages.len) |i| {
        //         arch.map_page(self, virt_base + offset, pages[i], level, flags, false);
        //         offset += level.size();
        //     }
        // }
    };

    /// NOTE The virtual-address allocator is rudimentary. Since the space is enormous a bump allocator is enough for dev purpose, but will probably be replaced by a RBtree.
    pub const VirtualSpace = struct {
        pub const MemoryLocation = enum { lower, higher };

        half: MemoryLocation,
        l0_table: [*]align(0x1000) u8,
        last_addr: u64,

        pub fn init(half: MemoryLocation, l0_table: [*]align(0x1000) u8) @This() {
            return .{
                .half = half,
                .l0_table = l0_table,
                .last_addr = if (half == .lower) 0x1000 else 0,
            };
        }

        pub fn base(self: *VirtualSpace) u64 {
            return switch (self.half) {
                .higher => 0xFFFF_8000_0000_0000,
                .lower => 0x0000_0000_0000_0000,
            };
        }

        pub fn reserve(self: *VirtualSpace, count: usize) VirtualReservation {
            const reservation = VirtualReservation{
                .space = self,
                .virt = self.last_addr,
                .size = count,
            };

            self.last_addr = std.mem.alignForward(u64, self.last_addr + (count << 12), 0x1000);

            return reservation;
        }
    };

    pub const VirtualMemory = struct {
        user_space: *VirtualSpace,
        kernel_space: VirtualSpace,

        pub fn init(page_allocator: PageAllocator) !@This() {
            const virt_mem = @This(){
                .user_space = @constCast(&VirtualSpace.init(.lower, switch (builtin.cpu.arch) {
                    .aarch64 => @ptrFromInt(cpu.armv8a_64.registers.TTBR0_EL1.get().l0_table),
                    else => unreachable,
                })),
                .kernel_space = VirtualSpace.init(.higher, switch (builtin.cpu.arch) {
                    .aarch64 => try page_allocator.alloc(1),
                    else => unreachable,
                }),
            };

            return virt_mem;
        }

        pub fn switchUser(self: *@This(), user_space: *VirtualSpace) void {
            _ = self;
            _ = user_space;
            // NOTE The idea on x86_64 is to automatically referentiate the kernel_space into user_space in this procedure.
        }

        pub fn update(self: *@This()) void {
            _ = self;
        }
    };
};
