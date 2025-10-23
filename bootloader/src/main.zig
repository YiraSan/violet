const builtin = @import("builtin");
const build_options = @import("build_options");
const std = @import("std");
const ark = @import("ark");

const uefi = std.os.uefi;

const Segment = struct {
    phys: usize,
    virt: usize,
    size: usize,
    flags: u32,
};

pub fn main() uefi.Status {
    std.log.info("bootloader v{s}", .{build_options.version});

    // get BootServices (0)

    const boot_services: *uefi.tables.BootServices = uefi.system_table.boot_services orelse {
        std.log.err("failed to load boot services", .{});
        return uefi.Status.unsupported;
    };

    // get "kernel.elf" (1)

    std.log.debug("loading kernel.elf file...", .{});

    var file_system: *uefi.protocol.SimpleFileSystem = undefined;

    var status = boot_services.locateProtocol(
        &uefi.protocol.SimpleFileSystem.guid,
        null,
        @ptrCast(&file_system),
    );
    if (status != .success) {
        std.log.err("unexpected status: {}", .{status});
        return status;
    }

    var root: *const uefi.protocol.File = undefined;
    status = file_system.openVolume(&root);
    if (status != .success) {
        std.log.err("unexpected status: {}", .{status});
        return status;
    }

    const kernel_file: []align(8) u8 = kfr: {
        var kernel_elf: *const uefi.protocol.File = undefined;
        status = root.open(&kernel_elf, std.unicode.utf8ToUtf16LeStringLiteral("kernel.elf"), uefi.protocol.File.efi_file_mode_read, 0);
        if (status != .success) {
            std.log.err("unexpected status: {}", .{status});
            return status;
        }

        var info_buf: [512]u8 align(8) = undefined;
        var size: usize = info_buf.len;
        status = kernel_elf.getInfo(&uefi.FileInfo.guid, &size, &info_buf);
        if (status != .success) {
            std.log.err("unexpected status: {}", .{status});
            return status;
        }

        const info: *uefi.FileInfo = @ptrCast(&info_buf);

        var buffer: [*]align(8) u8 = undefined;
        status = boot_services.allocatePool(uefi.tables.MemoryType.loader_data, info.file_size, &buffer);
        if (status != .success) {
            std.log.err("unexpected status: {}", .{status});
            return status;
        }

        var buffer_size: usize = info.file_size;
        status = kernel_elf.read(&buffer_size, buffer);
        if (status != .success) {
            std.log.err("unexpected status: {}", .{status});
            return status;
        }

        _ = kernel_elf.close();

        break :kfr buffer[0..info.file_size];
    };

    _ = root.close();

    std.log.debug("loaded kernel.elf. done.", .{});

    // load kernel to memory (2)

    std.log.debug("loading kernel into memory...", .{});

    const elf_header = std.elf.Header.parse(@ptrCast(kernel_file)) catch {
        std.log.err("couldn't parse ELF header", .{});
        return uefi.Status.compromised_data;
    };

    if (!elf_header.is_64) {
        std.log.err("kernel.elf should be 64bit", .{});
        return uefi.Status.compromised_data;
    }

    if (elf_header.endian != .little) {
        std.log.err("kernel.elf should be little endian", .{});
        return uefi.Status.compromised_data;
    }

    if (elf_header.type != .EXEC) {
        std.log.err("kernel.elf should be an executable", .{});
        return uefi.Status.compromised_data;
    }

    if (switch (builtin.cpu.arch) {
        .aarch64 => elf_header.machine != .AARCH64,
        .riscv64 => elf_header.machine != .RISCV,
        .x86_64 => elf_header.machine != .X86_64,
        else => unreachable,
    }) {
        std.log.err("kernel.elf should be '{s}'", .{@tagName(builtin.cpu.arch)});
        return uefi.Status.compromised_data;
    }

    var segments = std.ArrayList(Segment).init(uefi.pool_allocator);

    for (0..elf_header.phnum) |phi| {
        const ph: *std.elf.Elf64_Phdr = @alignCast(@ptrCast(kernel_file[elf_header.phoff + phi * @sizeOf(std.elf.Elf64_Phdr) ..]));
        if (ph.p_type != std.elf.PT_LOAD) continue;

        const mem_size = std.mem.alignForward(u64, ph.p_memsz, 0x1000);
        const page_count = mem_size / 0x1000;
        var physical_address: [*]align(0x1000) u8 = undefined;

        status = boot_services.allocatePages(.allocate_any_pages, .loader_data, page_count, &physical_address);
        if (status != .success) {
            std.log.err("unexpected status: {}", .{status});
            return status;
        }

        @memcpy(physical_address, kernel_file[ph.p_offset .. ph.p_offset + ph.p_filesz]);

        // Zero-fill BSS
        if (ph.p_memsz > ph.p_filesz) {
            @memset(physical_address[ph.p_filesz..ph.p_memsz], 0);
        }

        segments.append(.{
            .phys = @intFromPtr(physical_address),
            .virt = ph.p_vaddr,
            .size = ph.p_memsz,
            .flags = ph.p_flags,
        }) catch |err| {
            std.log.err("unexpected error: {}", .{err});
            return uefi.Status.aborted;
        };
    }

    const entry_address = elf_header.entry;

    std.log.debug("loaded kernel into memory. done.", .{});

    // setup virtual memory (3)

    std.log.debug("setting up virtual memory...", .{});

    const page_allocator = ark.mem.PageAllocator{
        .ctx = boot_services,
        ._alloc = &_alloc,
        ._free = &_free,
    };

    var vm = ark.mem.VirtualMemory.init(page_allocator) catch hcf();

    for (segments.items) |segment| {
        const reservation = vm.kernel_space.reserve(std.mem.alignForward(usize, segment.size, 0x1000) >> 12);
        if (reservation.address() != segment.virt) @panic("kernel bad-alignment");

        reservation.map_contiguous(page_allocator, segment.phys, .{
            .writable = (segment.flags & std.elf.PF_W) != 0,
            .executable = (segment.flags & std.elf.PF_X) != 0,
        });
    }

    var memory_map = getMemoryMap(boot_services);

    // configure HHDM
    var i: usize = 0;
    var limit: u64 = 0; 
    while (memory_map.get(i)) |entry| : (i+=1) {
        const size = entry.number_of_pages << 12;
        const end = entry.physical_start + size;
        if (end > limit) {
            limit = end;
        }
    }

    var reservation = vm.kernel_space.reserve(limit >> 12);
    const hhdm_base = reservation.address();

    i = 0;
    while (memory_map.get(i)) |entry| : (i+=1) {
        reservation.virt = hhdm_base + entry.physical_start;
        reservation.size = entry.number_of_pages;

        switch (entry.type) {
            .conventional_memory,
            .acpi_memory_nvs,
            .acpi_reclaim_memory,
            .loader_code,
            .boot_services_data,
                => reservation.map_contiguous(page_allocator, entry.physical_start, .{
                    .writable = true,
                }),
            .memory_mapped_io,
            .memory_mapped_io_port_space,
                => reservation.map_contiguous(page_allocator, entry.physical_start, .{
                    .device = true,
                    .writable = true,
                }),
            else => {}
        }
    }

    switch (builtin.cpu.arch) {
        .aarch64 => {
            const ttbr1_el1 = ark.cpu.armv8a_64.registers.TTBR1_EL1{ .l0_table = @intFromPtr(vm.kernel_space.l0_table) };

            ttbr1_el1.set();

            var mair_el1 = ark.cpu.armv8a_64.registers.MAIR_EL1.get();
            mair_el1.attr0 = ark.cpu.armv8a_64.registers.MAIR_EL1.DEVICE_nGnRnE;
            mair_el1.attr1 = ark.cpu.armv8a_64.registers.MAIR_EL1.NORMAL_NONCACHEABLE;
            mair_el1.attr2 = ark.cpu.armv8a_64.registers.MAIR_EL1.NORMAL_WRITETHROUGH_NONTRANSIENT;
            mair_el1.attr3 = ark.cpu.armv8a_64.registers.MAIR_EL1.NORMAL_WRITEBACK_NONTRANSIENT;
            mair_el1.attr4 = 0;
            mair_el1.attr5 = 0;
            mair_el1.attr6 = 0;
            mair_el1.attr7 = 0;
            mair_el1.set();

            var tcr_el1 = ark.cpu.armv8a_64.registers.TCR_EL1.get();

            tcr_el1.t0sz = 16;
            tcr_el1.epd0 = false;
            tcr_el1.irgn0 = .wb_ra_wa;
            tcr_el1.orgn0 = .wb_ra_wa;
            tcr_el1.sh0 = .inner_shareable;
            tcr_el1.tg0 = ._4kb;

            tcr_el1.a1 = .ttbr0_el1;

            tcr_el1.t1sz = 16;
            tcr_el1.epd1 = false;
            tcr_el1.irgn1 = .wb_ra_wa;
            tcr_el1.orgn1 = .wb_ra_wa;
            tcr_el1.sh1 = .inner_shareable;
            tcr_el1.tg1 = ._4kb;

            // tcr_el1.ips = 5;
            // tcr_el1.as = .u8;

            tcr_el1.tbi0 = .used;
            tcr_el1.tbi1 = .used;

            tcr_el1.set();

            asm volatile (
                \\ dsb sy
                \\ isb
            );

            ark.cpu.armv8a_64.pagging.flush_all();
        },
        else => unreachable,
    }

    std.log.debug("virtual memory setup. done.", .{});

    // TODO ACPI

    // exit BootServices (4)

    std.log.debug("exiting bootServices and jumping into kernel_entry...", .{});

    memory_map = getMemoryMap(boot_services);

    _ = boot_services.exitBootServices(uefi.handle, memory_map.map_key);

    // jump to kernel (5)

    const kernel_entry: *const fn (
        map: *anyopaque,
        map_size: u64,
        descriptor_size: u64,
        hhdm_base: u64,
        virt_base_alloc: u64,
    ) callconv(switch (builtin.cpu.arch) {
        .aarch64 => .{ .aarch64_aapcs = .{} },
        .riscv64 => .{ .riscv64_lp64 = .{} },
        else => unreachable,
    }) noreturn = @ptrFromInt(entry_address);

    kernel_entry(memory_map.map, memory_map.map_size, memory_map.descriptor_size, hhdm_base, vm.kernel_space.last_addr);

    hcf();
}

fn _alloc(ctx: *anyopaque, count: usize) ark.mem.PageAllocator.AllocError![*]align(0x1000) u8 {
    const boot_services: *uefi.tables.BootServices = @alignCast(@ptrCast(ctx));
    var physical_address: [*]align(0x1000) u8 = undefined;
    _ = boot_services.allocatePages(.allocate_any_pages, .loader_data, count, &physical_address);
    return physical_address;
}

fn _free(ctx: *anyopaque, addr: [*]align(0x1000) u8, count: usize) void {
    const boot_services: *uefi.tables.BootServices = @alignCast(@ptrCast(ctx));
    _ = boot_services.freePages(addr, count);
}

const MemoryTable = struct {
    map: *anyopaque,
    map_key: usize,
    map_size: usize,
    descriptor_size: usize,

    pub fn get(self: MemoryTable, index: usize) ?*uefi.tables.MemoryDescriptor {
        const i = self.descriptor_size * index;
        if (i > (self.map_size - self.descriptor_size)) return null;
        return @ptrFromInt(@intFromPtr(self.map) + i);
    }
};

fn getMemoryMap(boot_services: *uefi.tables.BootServices) MemoryTable {
    var map: ?[*]uefi.tables.MemoryDescriptor = null;
    var map_size: usize = 0;
    var map_key: usize = 0;

    var descriptor_size: usize = 0;
    var descriptor_version: u32 = undefined;

    var status = boot_services.getMemoryMap(
        &map_size,
        map,
        &map_key,
        &descriptor_size,
        &descriptor_version,
    );

    if (status != .buffer_too_small) {
        std.log.err("unexpected return status: {}", .{status});
        unreachable;
    }

    while (true) {
        map_size += descriptor_size;
        const buffer = uefi.pool_allocator.alloc(u8, map_size) catch unreachable;
        map = @alignCast(@ptrCast(buffer.ptr));

        status = boot_services.getMemoryMap(
            &map_size,
            map,
            &map_key,
            &descriptor_size,
            &descriptor_version,
        );

        if (status == .success) break;
        if (status == .buffer_too_small) {
            uefi.pool_allocator.free(buffer);
            continue;
        }

        std.log.err("unexpected return status: {}", .{status});
        unreachable;
    }

    return .{
        .map = @ptrCast(map.?),
        .map_key = map_key,
        .map_size = map_size,
        .descriptor_size = descriptor_size,
    };
}

// --- zig std features --- //

fn hcf() noreturn {
    while (true) {
        switch (builtin.cpu.arch) {
            .aarch64, .riscv64 => asm volatile ("wfi"),
            else => unreachable,
        }
    }
}

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = return_address;
    std.log.err("bootloader panic: {s}", .{message});
    hcf();
}

const log = @import("log.zig");

pub fn logFn(comptime level: std.log.Level, comptime _: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    const prefix = "[bootloader] " ++ switch (level) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    } ++ ": ";
    log.print(prefix ++ format ++ "\n", args);
}

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};
