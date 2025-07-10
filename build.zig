const std = @import("std");
const basalt = @import("basalt");

pub fn build(b: *std.Build) !void {
    const platform = b.option(basalt.Platform, "platform", "q35, virt, ..") orelse .q35;
    const optimize = b.standardOptimizeOption(.{});

    const kernel_dep = b.dependency("kernel", .{
        .platform = platform,
        .optimize = optimize,
    });
    const kernel_exe = kernel_dep.artifact("kernel");
    b.installArtifact(kernel_exe);

    const system_dep = b.dependency("system", .{
        .platform = platform,
        .optimize = optimize,
    });
    const system_exe = system_dep.artifact("system");
    b.installArtifact(system_exe);

    // FAT image

    const limine_bin = b.dependency("limine_bin", .{});
    const limine_path = limine_bin.path(".");
    const target = b.standardTargetOptions(.{});

    const limine_exe = b.addExecutable(.{
        .name = "limine",
        .target = target,
        .optimize = .ReleaseSafe,
    });

    limine_exe.addCSourceFile(.{ .file = limine_bin.path("limine.c"), .flags = &[_][]const u8{"-std=c99"} });
    limine_exe.linkLibC();

    const limine_exe_run = b.addRunArtifact(limine_exe);

    const create_fat_img = b.addSystemCommand(&[_][]const u8{
        // zig fmt: off
        "/bin/sh", "-c",
        try std.mem.concat(b.allocator, u8, &[_][]const u8{
            "mkdir -p zig-out/root/EFI/BOOT/ && ",
            "cp zig-out/bin/kernel.elf zig-out/root/ && ",
            "cp zig-out/bin/system.elf zig-out/root/ && ",
            "cp build/limine.conf zig-out/root/ && ",

            "cp ", limine_path.getPath(b), "/limine-bios.sys ",
                   limine_path.getPath(b), "/limine-bios-cd.bin ",
                   limine_path.getPath(b), "/limine-uefi-cd.bin ",
                   "zig-out/root/ && ",

            "cp ", limine_path.getPath(b), "/BOOTX64.EFI ",
                   limine_path.getPath(b), "/BOOTAA64.EFI ",
                   limine_path.getPath(b), "/BOOTRISCV64.EFI ",
                   "zig-out/root/EFI/BOOT/ && ",
            
            "xorriso -as mkisofs -R -r -J -b limine-bios-cd.bin ",
                "-no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus ",
                "-apm-block-size 2048 --efi-boot limine-uefi-cd.bin ",
                "-efi-boot-part --efi-boot-image --protective-msdos-label ",
                "zig-out/root/ -o zig-out/violet.iso && ",

            "qemu-img resize zig-out/violet.iso 16m"
        }),
        // zig fmt: on
    });

    create_fat_img.step.dependOn(&kernel_exe.step);
    create_fat_img.step.dependOn(&system_exe.step);

    _ = limine_exe_run.addArg("bios-install");
    _ = limine_exe_run.addFileArg(b.path("zig-out/violet.iso"));
    limine_exe_run.step.dependOn(&create_fat_img.step);

    b.default_step.dependOn(&limine_exe_run.step);

    // download .fd

    const download_fd = switch (platform) {
        .q35 => b.addSystemCommand(&[_][]const u8{
            "sh", "-c",
            \\[ -f .zig-cache/X64_OVMF.fd ] || curl -L -o .zig-cache/X64_OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd
        }),
        .virt => b.addSystemCommand(&[_][]const u8{
            "sh", "-c",
            \\[ -f .zig-cache/AA64_OVMF.fd ] || curl -L -o .zig-cache/AA64_OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASEAARCH64_QEMU_EFI.fd
        }),
        .raspi4b => b.addSystemCommand(&[_][]const u8{
            "sh", "-c",
            \\[ -f .zig-cache/RPi4_UEFI/RPI_EFI.fd ] || curl -L -o .zig-cache/RPi4_UEFI.zip https://github.com/pftf/RPi4/releases/download/v1.42/RPi4_UEFI_Firmware_v1.42.zip
            \\[ -f .zig-cache/RPi4_UEFI/RPI_EFI.fd ] || unzip .zig-cache/RPi4_UEFI.zip -d .zig-cache/RPi4_UEFI/
            \\[ -f .zig-cache/RPi4_UEFI/RPI_EFI.fd ] || rm -rf .zig-cache/RPi4_UEFI.zip
        }),
    };

    // Run QEMU

    const run = switch (platform) {
        .q35 => b.addSystemCommand(&[_][]const u8{
            "qemu-system-x86_64",
            "-bios", ".zig-cache/X64_OVMF.fd",
            "-cdrom", "zig-out/violet.iso",
            "-m", "2G",
            "-smp", "4",
            "-serial", "mon:stdio",
            "-no-shutdown",
            "-no-reboot",
        }),
        .raspi4b => b.addSystemCommand(&[_][]const u8{
            "qemu-system-aarch64",
            "-cpu", "cortex-a72",
            "-M", "raspi4b",
            "-m", "2G",
            "-smp", "4",
            "-bios", ".zig-cache/RPi4_UEFI/RPI_EFI.fd",
            "-drive", "if=sd,format=raw,file=zig-out/violet.iso",
            "-serial", "mon:stdio",
            "-d", "int,cpu_reset",
            "-device", "usb-kbd",
            "-no-shutdown",
            "-no-reboot",
        }),
        .virt => b.addSystemCommand(&[_][]const u8{
            "qemu-system-aarch64",
            "-cpu", "max",
            "-m", "2G",
            "-smp", "4",
            "-M", "virt",
            "-bios", ".zig-cache/AA64_OVMF.fd",
            "-cdrom", "zig-out/violet.iso",
            "-boot", "d",
            "-device", "ramfb",
            "-device", "qemu-xhci",
            "-device", "usb-kbd",
            "-serial", "stdio",
            "-no-reboot",
            "-no-shutdown",
            "-d", "int",
            "-D", "debug.log",
        }),
    };

    run.step.dependOn(b.default_step);
    run.step.dependOn(&download_fd.step);
    b.step("run", "Run Violet in QEMU").dependOn(&run.step);
}
