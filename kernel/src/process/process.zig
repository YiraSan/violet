// --- imports --- //

const std = @import("std");
const builtin = @import("builtin");

const kernel = @import("root");
const mem = kernel.mem;
const arch = kernel.arch;

// --- Process Allocator --- //

pub const MAX_PROCESSES = std.math.maxInt(u16); // 65535 (0xFFFF)

var process_id_freelist: [MAX_PROCESSES]u16 linksection(".bss") = undefined;
var process_id_freelist_len: usize = 0;

fn init_process_id_allocator() void {
    var i: usize = 0;
    while (i < MAX_PROCESSES) : (i += 1) {
        // Push IDs in reverse order for easy pop
        process_id_freelist[i] = @intCast(MAX_PROCESSES - 1 - i);
    }
    process_id_freelist_len = MAX_PROCESSES;
}

pub fn alloc_process_id() ?u16 {
    if (process_id_freelist_len == 0)
        return null;
    process_id_freelist_len -= 1;
    return process_id_freelist[process_id_freelist_len];
}

pub fn free_process_id(id: u16) void {
    if (process_id_freelist_len >= MAX_PROCESSES) {
        @panic("process ID freelist overflow");
    }
    process_id_freelist[process_id_freelist_len] = id;
    process_id_freelist_len += 1;
}

// --- process.zig --- //

pub fn init() void {
    init_process_id_allocator();
}

pub const Process = struct {
    id: u16,
    address_space: mem.virt.AddressSpace,
    threads: [256]?*Thread,
    entry_point_virt: u64,

    /// initialize process structure and load executable
    pub fn load(elf_bytes: []align(4096) u8) !*@This() {
        if (elf_bytes.len < @sizeOf(std.elf.Elf64_Ehdr)) return error.InvalidELF;

        const process = @as(*@This(), @ptrFromInt(mem.hhdm_offset + try mem.phys.alloc_page(.l4K)));
        errdefer mem.phys.free_page(@intFromPtr(process) - mem.hhdm_offset, .l4K);
        process.id = alloc_process_id() orelse return error.TooMuchProcesses;
        process.address_space = try .init(null, 0);
        errdefer process.address_space.deinit();
        @memset(&process.threads, null);

        // ELF LOADER

        const header = try std.elf.Header.parse(@ptrCast(elf_bytes));

        if (!header.is_64) return error.InvalidELF;
        if (header.endian != .little) return error.InvalidELF;

        switch (builtin.cpu.arch) {
            .aarch64 => if (header.machine != .AARCH64) return error.InvalidELF,
            .x86_64 => if (header.machine != .X86_64) return error.InvalidELF,
            else => unreachable,
        }

        const ph_end = header.phoff + (header.phnum * header.phentsize);
        if (ph_end > elf_bytes.len) return error.InvalidELF;

        const sh_end = header.shoff + (header.shnum * header.shentsize);
        if (sh_end > elf_bytes.len) return error.InvalidELF;

        if (header.type != .EXEC) return error.InvalidELF; // TODO enable support for ET_DYN

        const phdrs: [*]std.elf.Elf64_Phdr = @alignCast(@ptrCast(elf_bytes[header.phoff..]));

        var min_vaddr: u64 = std.math.maxInt(u64);
        var max_vaddr: u64 = 0;

        for (0..header.phnum) |i| {
            const ph = phdrs[i];
            if (ph.p_type == std.elf.PT_LOAD) {
                if (ph.p_offset + ph.p_filesz > elf_bytes.len) return error.ElfTruncated;

                if ((ph.p_vaddr % ph.p_align) != (ph.p_offset % ph.p_align)) return error.InvalidELF;

                var seg_start = ph.p_vaddr;
                var seg_end = ph.p_vaddr + ph.p_memsz;

                seg_start = std.mem.alignBackward(u64, seg_start, 4096);
                seg_end = std.mem.alignForward(u64, seg_end, 4096);

                if (seg_start < min_vaddr) {
                    min_vaddr = seg_start;
                }

                if (seg_end > max_vaddr) {
                    max_vaddr = seg_end;
                }
            }
        }

        const total_size = max_vaddr - min_vaddr;
        const num_pages = std.math.divCeil(u64, total_size, 0x1000) catch unreachable;

        const vbase = 0x40000000;

        const range = process.address_space.allocate(num_pages, .l4K);
        if (range.base(&process.address_space) != 0x40000000) return error.VirtualAddressAllocationFailed;

        for (0..header.phnum) |i| {
            const ph = phdrs[i];
            if (ph.p_type == std.elf.PT_LOAD) {
                if (ph.p_vaddr < vbase) return error.InvalidELF;

                const seg_pages = std.math.divCeil(u64, ph.p_memsz, 0x1000) catch unreachable;

                const phys_addr = try mem.phys.alloc_contiguous_pages(seg_pages, .l4K, false);

                const seg_offset = ph.p_vaddr - range.base(&process.address_space);
                process.address_space.map_contiguous(range, seg_offset, phys_addr, seg_pages, .l4K, .{
                    .writable = (ph.p_flags & std.elf.PF_W) != 0,
                    .executable = (ph.p_flags & std.elf.PF_X) != 0,
                    .user = true,
                });

                const dest = @as([*]u8, @ptrFromInt(mem.hhdm_offset + phys_addr + seg_offset));
                const src = elf_bytes[ph.p_offset .. ph.p_offset + ph.p_filesz];

                @memcpy(dest[0..ph.p_filesz], src);

                if (ph.p_memsz > ph.p_filesz) {
                    @memset(dest[ph.p_filesz..ph.p_memsz], 0);
                }
            }
        }

        process.entry_point_virt = header.entry;

        return process;
    }

    pub fn new_thread(self: *Process) !*Thread {
        const thread: *Thread = @ptrFromInt(mem.hhdm_offset + try mem.phys.alloc_page(.l4K));
        errdefer mem.phys.free_page(@intFromPtr(thread) - mem.hhdm_offset, .l4K);

        thread.process = self;

        var defined = false;
        for (0..self.threads.len) |i| {
            if (self.threads[i] == null) {
                defined = true;
                thread.id = @truncate(i);
                break;
            }
        }

        if (!defined) return error.TooMuchThreads;

        @memset(&thread.tasks, null);

        switch (builtin.cpu.arch) {
            .aarch64 => {
                thread.context = .{
                    .sp_el1 = 0, // TODO configure sp_el1
                };
            },
            .x86_64 => {},
            else => unreachable,
        }

        return thread;
    }

    pub fn deinit(self: *@This()) void {
        // TODO free all unshared memory
        self.address_space.deinit();
        free_process_id(self.process_id);
        // TODO deinit threads
        mem.phys.free_page(@intFromPtr(self) - mem.hhdm_offset, .l4K);
    }

    comptime {
        if (@sizeOf(Process) > 0x1000) {
            @compileError("Process should be less than 4 KiB");
        }
    }
};

pub const Thread = struct {
    id: u8,
    process: *Process,
    context: arch.ThreadContext,
    tasks: [256]?*Task,

    pub fn new_task(self: *Thread, entry_point_virt: u64) !*Task {
        const task: *Task = @ptrFromInt(mem.hhdm_offset + try mem.phys.alloc_page(.l4K));
        errdefer mem.phys.free_page(@intFromPtr(task) - mem.hhdm_offset, .l4K);

        task.thread = self;
        task.state = .ready;

        var defined = false;
        for (0..self.tasks.len) |i| {
            if (self.tasks[i] == null) {
                defined = true;
                task.id = @truncate(i);
                break;
            }
        }

        if (!defined) return error.TooMuchTasks;

        const phys_addr = try mem.phys.alloc_page(.l4K);

        const range = self.process.address_space.allocate(1, .l4K);

        self.process.address_space.map_contiguous(range, 0, phys_addr, 1, .l4K, .{
            .writable = true,
            .user = true,
        });

        switch (builtin.cpu.arch) {
            .aarch64 => {
                task.context = .{
                    .spsr_el1 = .{
                        .mode = .el0t,
                        .ss = false,
                        .il = false,
                        .f = false,
                        .i = false,
                        .a = false,
                        .d = false,
                    },
                    .elr_el1 = entry_point_virt,
                    .sp_el0 = range.base(&self.process.address_space) + 0x1000,
                    .tpidr_el1 = @intFromPtr(task),
                    .tpidrro_el0 = .{}, // TODO setup TaskInfo
                };
            },
            .x86_64 => {},
            else => unreachable,
        }

        return task;
    }

    comptime {
        if (@sizeOf(Thread) > 0x1000) {
            @compileError("Thread should be less than 4 KiB");
        }
    }
};

pub const Task = struct {
    id: u8,
    thread: *Thread,
    state: enum(u8) {
        ready = 0,
        running = 1,
        waiting = 2,
    },
    context: arch.TaskContext,

    pub fn jump(self: *Task) void {
        switch (builtin.cpu.arch) {
            .aarch64 => {
                asm volatile (
                    \\ mov x0, %[task_ptr]
                    \\ svc #0
                    :
                    : [task_ptr] "r" (self),
                    : "x0", "memory"
                );
            },
            .x86_64 => {},
            else => unreachable,
        }
    }

    comptime {
        if (@sizeOf(Task) > 0x1000) {
            @compileError("Task should be less than 4 KiB");
        }
    }
};

pub const TaskInfo = packed struct(u64) {
    _: u64 = 0,
};
