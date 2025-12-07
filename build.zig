// Copyright (c) 2025 The violetOS authors
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
const dimmer = @import("dimmer");
const basalt = @import("basalt");

pub fn build(b: *std.Build) !void {
    const platform = b.option(basalt.Platform, "platform", "aarch64_qemu, riscv64_qemu, ...") orelse .aarch64_qemu;
    const use_uefi = b.option(bool, "use_uefi", "The image will be configured for UEFI.") orelse true;
    const optimize = b.standardOptimizeOption(.{});

    // dependencies

    const kernel_dep = b.dependency("kernel", .{
        .platform = platform,
        .use_uefi = use_uefi,
        .optimize = optimize,
    });
    const kernel_exe = kernel_dep.artifact("kernel");
    b.installArtifact(kernel_exe);

    const bootloader_dep = b.dependency("bootloader", .{
        .platform = platform,
        .use_uefi = use_uefi,
        .optimize = optimize,
    });
    const bootloader_exe = bootloader_dep.artifact("bootloader");
    b.installArtifact(bootloader_exe);

    // Disk

    var bootfs = dimmer.BuildInterface.FileSystemBuilder.init(b);
    {
        bootfs.mkdir("/EFI");
        bootfs.mkdir("/EFI/BOOT");

        bootfs.copyFile(bootloader_exe.getEmittedBin(), switch (platform.arch()) {
            .aarch64 => "/EFI/BOOT/BOOTAA64.EFI",
            .riscv64 => "/EFI/BOOT/BOOTRISCV64.EFI",
            else => unreachable,
        });

        bootfs.copyFile(kernel_exe.getEmittedBin(), "/kernel.elf");

        switch (platform) {
            .rpi4 => {
                const rpi4_uefi_dep = b.dependency("rpi4_uefi", .{});
                bootfs.copyDirectory(rpi4_uefi_dep.path("."), "/");
            },
            else => {},
        }
    }

    const disk_image_dep = b.dependency("dimmer", .{ .release = true });
    const disk_image_tools = dimmer.BuildInterface.init(b, disk_image_dep);

    const disk_image = disk_image_tools.createDisk(128 * dimmer.BuildInterface.MiB, .{
        .gpt_part_table = .{
            .partitions = &.{
                .{
                    .type = .{ .name = .@"bios-boot" },
                    .name = "BIOS Bootloader",
                    .size = 0x8000,
                    .offset = 0x5000,
                    .data = .empty,
                },
                .{
                    .type = .{ .name = .@"efi-system" },
                    .name = "EFI System",
                    .offset = 0xD000,
                    .size = 33 * dimmer.BuildInterface.MiB,
                    .data = .{
                        .vfat = .{
                            .format = .fat32,
                            .label = "UEFI",
                            .tree = bootfs.finalize(),
                        },
                    },
                },
            },
        },
    });

    const install_disk_image = b.addInstallFile(disk_image, "disk.img");
    b.getInstallStep().dependOn(&install_disk_image.step);

    // QEMU

    const download_fd = switch (platform) {
        // .x86_64_q35 => b.addSystemCommand(&[_][]const u8{
        //     "sh", "-c",
        //     \\[ -f .zig-cache/X64_OVMF.fd ] || curl -L -o .zig-cache/X64_OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd
        // }),
        .aarch64_qemu => b.addSystemCommand(&[_][]const u8{
            "sh", "-c",
            \\[ -f .zig-cache/AA64_OVMF.fd ] || curl -L -o .zig-cache/AA64_OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASEAARCH64_QEMU_EFI.fd
        }),
        .riscv64_qemu => b.addSystemCommand(&[_][]const u8{
            "sh", "-c",
            \\[ -f .zig-cache/RISCV64_OVMF.fd ] || curl -L -o .zig-cache/RISCV64_OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASERISCV64_VIRT.fd
        }),
        else => b.addSystemCommand(&[_][]const u8{""}),
    };

    const qemu_run = switch (platform) {
        .aarch64_qemu => b.addSystemCommand(&[_][]const u8{
            // zig fmt: off
            "qemu-system-aarch64",

            "-accel", "kvm",
            "-accel", "hvf",
            "-accel", "tcg",

            "-cpu", "host",

            "-machine", "virt,secure=off,virtualization=off",

            "-m", "4G",
            "-smp", "4",
            "-bios", ".zig-cache/AA64_OVMF.fd",

            "-device", "virtio-blk-pci,drive=disk0,disable-legacy=on",
            "-drive", "file=zig-out/disk.img,if=none,id=disk0,format=raw",

            "-device", "virtio-gpu-pci",

            "-serial", "stdio",
            "-boot", "d",
            "-no-reboot",
            "-no-shutdown",
            "-d", "int",
            "-D", "debug.log",
            // zig fmt: on
        }),
        .rpi4, .rpi3 => b.addSystemCommand(&[_][]const u8 {"echo", "QEMU doesn't support a good enough emulation of raspberry pi"}),
        else => unreachable,
    };

    qemu_run.step.dependOn(&download_fd.step);
    qemu_run.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "run violetOS with qemu");

    run_step.dependOn(&qemu_run.step);
}
