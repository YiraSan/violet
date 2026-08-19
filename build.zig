// Copyright (c) 2024-2026 YiraSan
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

const std = @import("std");
const basalt = @import("basalt");

const Arch = std.Target.Cpu.Arch;

pub fn build(b: *std.Build) void {
    const board = b.option(Board, "board", "The target board");
    const arch = if (board) |bo| bo.getSoC().getArch() else b.option(Arch, "arch", "The target arch") orelse b.graph.host.result.cpu.arch;
    const tier = b.option(basalt.GenericTier, "tier", "The target tier") orelse .v1;

    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = if (board) |bo|
            bo.getSoC().getCpuModel()
        else
            tier.getCpuModel(arch) },
    });

    const optimize = b.standardOptimizeOption(.{});

    const img_root = createImgRoot(b, arch);
    {
        const kernel_dep = b.dependency("kernel", .{
            .target = target,
            .optimize = optimize,
            .drivers = if (board) |bo| bo.getSoC().getDrivers() else null,
        });
        const kernel_exe = kernel_dep.artifact("kernel");

        _ = img_root.addCopyFile(kernel_exe.getEmittedBin(), "core/kernel.elf");
    }

    setupFirmware(b, img_root, board);

    const make_img = b.addRunArtifact(makeImageExe(b));
    make_img.step.dependOn(&img_root.step);

    make_img.addDirectoryArg(img_root.getDirectory());

    const violet_img = b.addInstallFile(
        make_img.addOutputFileArg2("violet.img", .{}),
        if (board) |bo|
            b.fmt("violet-{s}.img", .{@tagName(bo)})
        else
            b.fmt("violet-{s}.img", .{@tagName(arch)}),
    );
    b.getInstallStep().dependOn(&violet_img.step);

    make_img.addArgs(&.{ "--label", "VIOLET", "--volume-label", "VIOLET" });

    const run_cmd = runCmd(b, arch, violet_img.source);

    const run_step = b.step("run", "Boot violetOS in QEMU");
    if (board == null) run_step.dependOn(&run_cmd.step);
}

fn createImgRoot(b: *std.Build, arch: Arch) *std.Build.Step.WriteFile {
    const root = b.addWriteFiles();

    _ = root.addCopyFile(b.path("LICENSE"), "LICENSE");
    _ = root.addCopyFile(b.path("NOTICE.md"), "NOTICE.md");

    const limine_binary = b.dependency("limine_binary", .{});

    _ = root.addCopyFile(b.path("build/limine.conf"), "limine.conf");

    const efi_file_name = switch (arch) {
        .aarch64 => "BOOTAA64.EFI",
        .riscv64 => "BOOTRISCV64.EFI",
        .x86_64 => "BOOTX64.EFI",
        else => unreachable,
    };

    _ = root.addCopyFile(limine_binary.path(efi_file_name), b.fmt("EFI/BOOT/{s}", .{efi_file_name}));

    return root;
}

fn setupFirmware(b: *std.Build, img_root: *std.Build.Step.WriteFile, board: ?Board) void {
    if (board) |bo| switch (bo) {
        .raspberry_pi3 => {
            const rpi3_uefi = b.dependency("rpi3_uefi", .{});
            _ = img_root.addCopyDirectory(rpi3_uefi.path("."), ".", .{ .exclude_extensions = &.{"md"} });
        },
        .raspberry_pi4 => {
            const rpi4_uefi = b.dependency("rpi4_uefi", .{});
            _ = img_root.addCopyDirectory(rpi4_uefi.path("."), ".", .{ .exclude_extensions = &.{"md"} });
        },
        else => @panic("This board is not supported yet."),
    };
}

fn makeImageExe(b: *std.Build) *std.Build.Step.Compile {
    const make_img = b.createModule(.{
        .target = b.graph.host,
        .optimize = .safe,
        .link_libc = true,
    });

    const fatfs = b.dependency("fatfs", .{});
    const fatfs_src = b.addWriteFiles();
    _ = fatfs_src.addCopyFile(b.path("build/ffconf.h"), "ffconf.h");
    _ = fatfs_src.addCopyFile(fatfs.path("source/ff.c"), "ff.c");
    _ = fatfs_src.addCopyFile(fatfs.path("source/ff.h"), "ff.h");
    _ = fatfs_src.addCopyFile(fatfs.path("source/diskio.h"), "diskio.h");
    _ = fatfs_src.addCopyFile(fatfs.path("source/ffunicode.c"), "ffunicode.c");

    const fatfs_dir = fatfs_src.getDirectory();

    make_img.addCSourceFile(.{
        .file = b.path("build/make_img.c"),
        .flags = &.{"-std=c11"},
    });

    make_img.addCSourceFile(.{
        .file = fatfs_dir.path(b, "ff.c"),
        .flags = &.{"-std=c89"},
    });

    make_img.addCSourceFile(.{
        .file = fatfs_dir.path(b, "ffunicode.c"),
        .flags = &.{"-std=c89"},
    });

    make_img.addIncludePath(fatfs_dir);

    return b.addExecutable(.{
        .name = "make_img",
        .root_module = make_img,
    });
}

fn edk2File(b: *std.Build, arch: Arch) std.Build.LazyPath {
    const download_cmd = b.addSystemCommand(&.{ "curl", "-L", "-o" });

    const fd_path = download_cmd.addOutputFileArg2(b.fmt("edk2-{s}-raw.fd", .{@tagName(arch)}), .{});

    download_cmd.addArg(switch (arch) {
        .aarch64 => "https://retrage.github.io/edk2-nightly/bin/RELEASEAARCH64_QEMU_EFI.fd",
        .riscv64 => "https://retrage.github.io/edk2-nightly/bin/RELEASERISCV64_VIRT.fd",
        .x86_64 => "https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd",
        else => unreachable,
    });

    const pad_exe = b.addExecutable(.{
        .name = "pad_exe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/pad.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });

    const pad_cmd = b.addRunArtifact(pad_exe);
    pad_cmd.addFileArg2(fd_path, .{});
    const padded_path = pad_cmd.addOutputFileArg2(b.fmt("edk2-{s}.fd", .{@tagName(arch)}), .{});

    switch (arch) {
        .aarch64 => pad_cmd.addArg(b.fmt("{d}", .{64 * 1024 * 1024})), // 64 MiB
        .riscv64 => pad_cmd.addArg(b.fmt("{d}", .{32 * 1024 * 1024})), // 32 MiB
        else => return fd_path,
    }

    return padded_path;
}

fn runCmd(b: *std.Build, arch: Arch, violet_img: std.Build.LazyPath) *std.Build.Step.Run {
    const qemu_exe = switch (arch) {
        .aarch64 => "qemu-system-aarch64",
        .riscv64 => "qemu-system-riscv64",
        .x86_64 => "qemu-system-x86_64",
        else => @panic("Architecture not supported yet"),
    };

    const run_cmd = b.addSystemCommand(&.{qemu_exe});

    // Machine Config
    {
        switch (arch) {
            .aarch64 => run_cmd.addArgs(&.{ "-machine", "virt,secure=off,virtualization=off", "-cpu", "cortex-a72" }),
            .riscv64 => run_cmd.addArgs(&.{ "-machine", "virt", "-cpu", "max" }),
            .x86_64 => run_cmd.addArgs(&.{ "-machine", "q35", "-cpu", "max" }),
            else => unreachable,
        }

        run_cmd.addArgs(&.{ "-m", "2G", "-smp", "4" });
        run_cmd.addArgs(&.{ "-device", "ramfb", "-serial", "stdio" });
        run_cmd.addArgs(&.{ "-no-reboot", "-no-shutdown" });
    }

    // EDK2
    switch (arch) {
        .aarch64, .riscv64 => {
            run_cmd.addArg("-drive");
            run_cmd.addFileArg2(edk2File(b, arch), .{ .prefix = "if=pflash,format=raw,readonly=on,file=" });
        },
        .x86_64 => {
            run_cmd.addArg("-bios");
            run_cmd.addFileArg2(edk2File(b, arch), .{});
        },
        else => unreachable,
    }

    // violet.img
    {
        run_cmd.addArgs(&.{ "-device", "virtio-blk-pci,drive=disk0,disable-legacy=on", "-drive" });
        run_cmd.addFileArg2(violet_img, .{
            .prefix = "if=none,id=disk0,format=raw,file=",
        });
    }

    const debug_mode = b.option(bool, "debug", "QEMU debug mode") orelse false;

    if (debug_mode) {
        run_cmd.addArgs(&.{ "-s", "-S" });
    }

    const int_mode = b.option(bool, "int", "Verbose interrupts into debug.log") orelse false;

    if (int_mode) {
        run_cmd.addArgs(&.{ "-d", "int", "-D", "debug.log" });
    }

    return run_cmd;
}

pub const SoC = enum {
    // aarch64
    bcm2837,
    bcm2711,
    rk3588,

    // riscv64
    jh7110,

    pub fn getArch(self: SoC) Arch {
        return switch (self) {
            .bcm2837, .bcm2711, .rk3588 => .aarch64,
            .jh7110 => .riscv64,
        };
    }

    pub fn getDrivers(self: SoC) []const u8 {
        return switch (self) {
            else => "",
        };
    }

    pub fn getCpuModel(self: SoC) *const std.Target.Cpu.Model {
        return switch (self) {
            .bcm2837 => &bcm2837_cpu_model,
            .bcm2711 => &bcm2711_cpu_model,
            .jh7110 => &std.Target.riscv.cpu.sifive_u74,
            else => unreachable,
        };
    }

    const bcm2837_cpu_model: std.Target.Cpu.Model = .{
        .name = "cortex_a53",
        .llvm_name = "cortex-a53",
        .features = std.Target.aarch64.featureSet(&[_]std.Target.aarch64.Feature{
            .balance_fp_ops,
            .crc,
            .fuse_adrp_add,
            .perfmon,
            .use_postra_scheduler,
            .use_wzr_to_vec_move,
            .v8a,
        }),
    };

    const bcm2711_cpu_model: std.Target.Cpu.Model = .{
        .name = "cortex_a72",
        .llvm_name = "cortex-a72",
        .features = std.Target.aarch64.featureSet(&[_]std.Target.aarch64.Feature{
            .addr_lsl_slow_14,
            .crc,
            .enable_select_opt,
            .fuse_adrp_add,
            .fuse_literals,
            .perfmon,
            .predictable_select_expensive,
            .v8a,
        }),
    };
};

pub const Board = enum {
    // aarch64
    raspberry_pi3,
    raspberry_pi4,
    radxa_rock5b,
    orange_pi5_plus,

    // riscv64
    vision_five2,

    pub fn getSoC(self: Board) SoC {
        return switch (self) {
            .raspberry_pi3 => .bcm2837,
            .raspberry_pi4 => .bcm2711,
            .radxa_rock5b, .orange_pi5_plus => .rk3588,
            .vision_five2 => .jh7110,
        };
    }

    pub fn getModules(self: Board) []const u8 {
        return switch (self) {
            else => "",
        };
    }
};

pub const Module = enum {
    virtio,
};
