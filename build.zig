const std = @import("std");
const dimmer = @import("dimmer");
const basalt = @import("basalt");

pub fn build(b: *std.Build) !void {
    const platform = b.option(basalt.Platform, "platform", "aarch64_qemu, riscv64_qemu, ...") orelse .aarch64_qemu;
    const optimize = b.standardOptimizeOption(.{});

    // dependencies

    const kernel_dep = b.dependency("kernel", .{
        .platform = platform,
        .optimize = optimize,
    });
    const kernel_exe = kernel_dep.artifact("kernel");
    b.installArtifact(kernel_exe);

    const bootloader_dep = b.dependency("bootloader", .{
        .platform = platform,
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
        else => unreachable,
    };

    const qemu_run = switch (platform) {
        .aarch64_qemu => b.addSystemCommand(&[_][]const u8{
            // zig fmt: off
            "qemu-system-aarch64",
            "-cpu", "max",
            "-machine", "virt",
            "-m", "4G",
            "-smp", "4",
            "-bios", ".zig-cache/AA64_OVMF.fd",
            "-cdrom", "zig-out/disk.img",
            "-device", "ramfb",
            // "-device", "virtio-gpu-pci", // TODO first support ramfb then virtio-gpu-pci
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
