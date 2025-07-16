const std = @import("std");
const basalt = @import("basalt");

pub fn build(b: *std.Build) !void {
    const platform = b.option(basalt.Platform, "platform", "x86_64_q35, aarch64_virt, riscv64_virt") orelse .x86_64_q35;
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

    const limine_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    limine_mod.addCSourceFile(.{ .file = limine_bin.path("limine.c"), .flags = &[_][]const u8{"-std=c99"} });

    const limine_exe = b.addExecutable(.{
        .name = "limine",
        .root_module = limine_mod,
    });

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
                "zig-out/root/ -o zig-out/violet.iso ",
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
        .x86_64_q35 => b.addSystemCommand(&[_][]const u8{
            "sh", "-c",
            \\[ -f .zig-cache/X64_OVMF.fd ] || curl -L -o .zig-cache/X64_OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd
        }),
        .aarch64_virt => b.addSystemCommand(&[_][]const u8{
            "sh", "-c",
            \\[ -f .zig-cache/AA64_OVMF.fd ] || curl -L -o .zig-cache/AA64_OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASEAARCH64_QEMU_EFI.fd
        }),
        .riscv64_virt => b.addSystemCommand(&[_][]const u8{
            "sh", "-c",
            \\[ -f .zig-cache/RISCV64_OVMF.fd ] || curl -L -o .zig-cache/RISCV64_OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASERISCV64_VIRT.fd
        }),
    };

    // Run QEMU

    const run = switch (platform) {
        .x86_64_q35 => b.addSystemCommand(&[_][]const u8{
            "qemu-system-x86_64",
            "-bios", ".zig-cache/X64_OVMF.fd",
            "-cdrom", "zig-out/violet.iso",
            "-m", "2G",
            "-smp", "4",
            "-serial", "mon:stdio",
            "-no-shutdown",
            "-no-reboot",
            "-d", "int",
            "-D", "debug.log",
        }),
        .aarch64_virt => b.addSystemCommand(&[_][]const u8{
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
            "-serial", "mon:stdio",
            "-no-reboot",
            "-no-shutdown",
            "-d", "int",
            "-D", "debug.log",
        }),
        else => unreachable,
    };

    run.step.dependOn(b.default_step);
    run.step.dependOn(&download_fd.step);
    b.step("run", "Run Violet in QEMU").dependOn(&run.step);
}
