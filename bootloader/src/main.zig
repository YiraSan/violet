// --- dependencies --- //

const ark = @import("ark");
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const uefi = std.os.uefi;
const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;

// --- imports --- //

pub const mmap = @import("mmap.zig");
pub const phys = @import("phys.zig");
pub const virt = @import("virt.zig");

// --- main.zig --- //

pub fn main() uefi.Status {
    if (uefi.system_table.con_out) |con_out| {
        _ = con_out.reset(true);
        _ = con_out.clearScreen();
        _ = con_out.outputString(utf16("violetOS-bootloader v" ++ build_options.version ++ "\r\n"));
    }

    const boot_services: *uefi.tables.BootServices = uefi.system_table.boot_services orelse {
        return uefi.Status.unsupported;
    };

    virt.init(boot_services);

    var file_system: *uefi.protocol.SimpleFileSystem = undefined;

    var status = boot_services.locateProtocol(
        &uefi.protocol.SimpleFileSystem.guid,
        null,
        @ptrCast(&file_system),
    );
    if (status != .success) {
        return status;
    }

    var root: *const uefi.protocol.File = undefined;
    status = file_system.openVolume(&root);
    if (status != .success) {
        return status;
    }

    const kernel_file: []align(8) u8 = kfr: {
        var kernel_elf: *const uefi.protocol.File = undefined;
        status = root.open(&kernel_elf, std.unicode.utf8ToUtf16LeStringLiteral("kernel.elf"), uefi.protocol.File.efi_file_mode_read, 0);
        if (status != .success) {
            return status;
        }

        var info_buf: [512]u8 align(8) = undefined;
        var size: usize = info_buf.len;
        status = kernel_elf.getInfo(&uefi.FileInfo.guid, &size, &info_buf);
        if (status != .success) {
            return status;
        }

        const info: *uefi.FileInfo = @ptrCast(&info_buf);

        var buffer: [*]align(8) u8 = undefined;
        status = boot_services.allocatePool(uefi.tables.MemoryType.loader_data, info.file_size, &buffer);
        if (status != .success) {
            return status;
        }

        var buffer_size: usize = info.file_size;
        status = kernel_elf.read(&buffer_size, buffer);
        if (status != .success) {
            return status;
        }

        _ = kernel_elf.close();

        break :kfr buffer[0..info.file_size];
    };

    _ = root.close();

    const elf_header = std.elf.Header.parse(@ptrCast(kernel_file)) catch {
        return uefi.Status.compromised_data;
    };

    if (!elf_header.is_64) {
        return uefi.Status.compromised_data;
    }

    if (elf_header.endian != .little) {
        return uefi.Status.compromised_data;
    }

    if (elf_header.type != .EXEC) {
        return uefi.Status.compromised_data;
    }

    if (switch (builtin.cpu.arch) {
        .aarch64 => elf_header.machine != .AARCH64,
        .riscv64 => elf_header.machine != .RISCV,
        .x86_64 => elf_header.machine != .X86_64,
        else => unreachable,
    }) {
        return uefi.Status.compromised_data;
    }

    for (0..elf_header.phnum) |phi| {
        const ph: *std.elf.Elf64_Phdr = @alignCast(@ptrCast(kernel_file[elf_header.phoff + phi * @sizeOf(std.elf.Elf64_Phdr) ..]));
        if (ph.p_type != std.elf.PT_LOAD) continue;

        const mem_size = std.mem.alignForward(u64, ph.p_memsz, 0x1000);
        const page_count = mem_size / 0x1000;
        var physical_address: [*]align(0x1000) u8 = undefined;

        status = boot_services.allocatePages(.allocate_any_pages, .loader_data, page_count, &physical_address);
        if (status != .success) {
            return status;
        }

        @memcpy(physical_address, kernel_file[ph.p_offset .. ph.p_offset + ph.p_filesz]);

        // Zero-fill BSS
        if (ph.p_memsz > ph.p_filesz) {
            @memset(physical_address[ph.p_filesz..ph.p_memsz], 0);
        }

        const kernel_size = std.mem.alignForward(usize, ph.p_memsz, virt.PageLevel.l4K.size());
        const kernel_page_count = kernel_size >> virt.PageLevel.l4K.shift();
        const va_base = virt.last_high_addr;
        virt.last_high_addr += kernel_size;

        if (va_base != ph.p_vaddr) @panic("kernel bad-alignment");

        virt.mapContiguous(
            virt.table,
            va_base,
            @intFromPtr(physical_address),
            .l4K,
            .{
                .writable = (ph.p_flags & std.elf.PF_W) != 0,
                .executable = (ph.p_flags & std.elf.PF_X) != 0,
            },
            kernel_page_count,
        );
    }

    const entry_address = elf_header.entry;

    virt.last_high_addr = std.mem.alignForward(usize, virt.last_high_addr + 1, 0x1000);

    const kernel_stack_phys = phys.allocPages(16);
    const kernel_stack_virt = virt.last_high_addr;
    const kernel_stack_size: u64 = 16 * 0x1000; // 64 KiB
    const kernel_stack_top = kernel_stack_virt + kernel_stack_size;
    virt.last_high_addr += kernel_stack_size;

    virt.mapContiguous(
        virt.table,
        kernel_stack_virt,
        kernel_stack_phys,
        .l4K,
        .{ .writable = true },
        16,
    );

    var memory_map = mmap.get(boot_services);

    // configure HHDM
    var i: usize = 0;
    var limit: u64 = 0;
    while (memory_map.get(i)) |entry| : (i += 1) {
        const size = entry.number_of_pages << 12;
        const end = entry.physical_start + size;
        if (end > limit) {
            limit = end;
        }
    }

    virt.last_high_addr = std.mem.alignForward(usize, virt.last_high_addr + 1, 0x1000);
    const hhdm_base = virt.last_high_addr;
    virt.last_high_addr += limit;

    virt.last_high_addr = std.mem.alignForward(usize, virt.last_high_addr + 1, 0x1000);
    const hhdm_limit = virt.last_high_addr;

    i = 0;
    while (memory_map.get(i)) |entry| : (i += 1) {
        const va = hhdm_base + entry.physical_start;

        if (!std.mem.isAligned(va, 0x1000)) @panic("MemoryMapEntry has unaligned physical_start.");

        switch (entry.type) {
            .conventional_memory,
            .acpi_memory_nvs,
            .acpi_reclaim_memory,
            .loader_data,
            .boot_services_data,
            .runtime_services_data,
            => virt.mapContiguous(
                virt.table,
                va,
                entry.physical_start,
                .l4K,
                .{ .writable = true },
                entry.number_of_pages,
            ),
            .memory_mapped_io,
            .memory_mapped_io_port_space,
            => virt.mapContiguous(
                virt.table,
                va,
                entry.physical_start,
                .l4K,
                .{ .writable = true, .device = true },
                entry.number_of_pages,
            ),
            else => {},
        }
    }

    virt.last_high_addr = std.mem.alignForward(usize, virt.last_high_addr + 1, 0x1000);

    memory_map = mmap.get(boot_services);

    switch (builtin.cpu.arch) {
        .aarch64 => {
            const pfr0 = ark.armv8.registers.ID_AA64PFR0_EL1.load();

            if (pfr0.fp == .not_implemented) {
                @panic("FloatingPoint is required but not implemented on this CPU.");
            }

            if (pfr0.adv_simd == .not_implemented) {
                @panic("AdvSIMD is required but not implemented on this CPU.");
            }

            const mmfr1 = ark.armv8.registers.ID_AA64MMFR1_EL1.load();
            if (mmfr1.vh == .supported) {
                const hcr_el2 = ark.armv8.registers.HCR_EL2.load();
                if (hcr_el2.e2h == .enabled) {
                    @panic("VH extension is enabled but not supported on violetOS.");
                }
            }
        },
        else => unreachable,
    }

    _ = boot_services.exitBootServices(uefi.handle, memory_map.map_key);

    switch (builtin.cpu.arch) {
        .aarch64 => {
            var reg = ark.armv8.registers.CPACR_EL1.load();
            reg.fpen = .el0_el1;
            reg.store();

            var sctlr = ark.armv8.registers.SCTLR_EL1{
                .M = true,
                .A = false, // TODO fix kernel alignment
            };
            sctlr.store();

            const currentEL = asm volatile ("mrs %[out], currentEL"
                : [out] "=r" (-> u64),
            );

            if (currentEL == 0b1100) { // EL3
                unreachable;
            } else if (currentEL == 0b1000) { // EL2
                const mmfr1 = ark.armv8.registers.ID_AA64MMFR1_EL1.load();
                if (mmfr1.vh == .supported) {
                    const hcr_el2 = ark.armv8.registers.HCR_EL2.load();
                    if (hcr_el2.e2h == .enabled) {
                        // TODO support Kernel on EL2.
                        asm volatile ("b .");
                    }
                }

                var hcr_el2 = ark.armv8.registers.HCR_EL2{};
                hcr_el2.rw = .el1_is_aa64;
                hcr_el2.store();

                var spsr = ark.armv8.registers.SPSR_EL2{
                    .mode = .el1t,
                    .d = true,
                    .a = true,
                    .i = true,
                    .f = true,
                };
                spsr.store();

                var cptr = ark.armv8.registers.CPTR_EL2 {
                    .tz = false,
                    .tfp = false,
                    .tta = false,
                    .tam = false,
                    .tcpac = false,
                };
                cptr.store();

                asm volatile (
                    \\ mov x0, %[mmap_phys_ptr]
                    \\ mov x1, %[mmap_size]
                    \\ mov x2, %[mmap_desc_size]
                    \\
                    \\ mov x3, %[hhdm_base]
                    \\ mov x4, %[hhdm_limit]
                    \\
                    \\ mov x5, %[config_tables_phys_ptr]
                    \\ mov x6, %[config_tables_size]
                    \\
                    \\ msr ttbr1_el1, %[ttbr1]
                    \\ msr elr_el2, %[kernel_entry]
                    \\ msr sp_el0, %[stack_top]
                    \\
                    \\ ic iallu
                    \\ dsb sy
                    \\ isb
                    \\
                    \\ tlbi vmalle1
                    \\ dsb ish
                    \\ isb
                    \\
                    \\ eret
                    :
                    : [mmap_phys_ptr] "r" (memory_map.map),
                      [mmap_size] "r" (memory_map.map_size),
                      [mmap_desc_size] "r" (memory_map.descriptor_size),

                      [hhdm_base] "r" (hhdm_base),
                      [hhdm_limit] "r" (hhdm_limit),

                      [config_tables_phys_ptr] "r" (uefi.system_table.configuration_table),
                      [config_tables_size] "r" (uefi.system_table.number_of_table_entries),

                      [ttbr1] "r" (virt.table),
                      [kernel_entry] "r" (entry_address),
                      [stack_top] "r" (kernel_stack_top),
                    : "memory", "x0", "x1", "x2", "x3", "x4", "x5", "x6"
                );
            } else if (currentEL == 0b0100) { // EL1
                asm volatile (
                    \\ mov x0, %[mmap_phys_ptr]
                    \\ mov x1, %[mmap_size]
                    \\ mov x2, %[mmap_desc_size]
                    \\
                    \\ mov x3, %[hhdm_base]
                    \\ mov x4, %[hhdm_limit]
                    \\
                    \\ mov x5, %[config_tables_phys_ptr]
                    \\ mov x6, %[config_tables_size]
                    \\
                    \\ msr ttbr1_el1, %[ttbr1]
                    \\ dsb ish
                    \\ isb
                    \\
                    \\ tlbi vmalle1
                    \\ dsb ish
                    \\ isb
                    \\
                    \\ mov x7, #0
                    \\ msr spsel, x7
                    \\ mov sp, %[stack_top]
                    \\ dsb ish
                    \\ isb
                    \\
                    \\ dsb sy
                    \\ isb
                    \\
                    \\ br %[kernel_entry]
                    :
                    : [mmap_phys_ptr] "r" (memory_map.map),
                      [mmap_size] "r" (memory_map.map_size),
                      [mmap_desc_size] "r" (memory_map.descriptor_size),

                      [hhdm_base] "r" (hhdm_base),
                      [hhdm_limit] "r" (hhdm_limit),

                      [config_tables_phys_ptr] "r" (uefi.system_table.configuration_table),
                      [config_tables_size] "r" (uefi.system_table.number_of_table_entries),

                      [kernel_entry] "r" (entry_address),

                      [ttbr1] "r" (virt.table),

                      [stack_top] "r" (kernel_stack_top),
                    : "memory", "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7"
                );
            } else { // EL0
                unreachable;
            }
        },
        else => unreachable,
    }

    ark.cpu.halt();
}
