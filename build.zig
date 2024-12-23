const std = @import("std");

pub fn build(b: *std.Build) !void {

    const device = 
        b.option(Device, "device", "target device")
        orelse @panic("-Ddevice missing");
    
    const kernel_dep = b.dependency("kernel", .{
        .device = device,
    });
    b.installArtifact(kernel_dep.artifact("kernel"));

    const iso_step = b.step("iso", "build a bootable iso");
    iso_step.dependOn(try buildIso(b));

    const run_cmd = try runIso(b, device.arch());
    run_cmd.dependOn(iso_step);

    const run_step = b.step("run", "run violet in qemu");
    run_step.dependOn(run_cmd);

}

pub fn buildIso(b: *std.Build) !*std.Build.Step {
    const limine_bin = b.dependency("limine_bin", .{});
    const limine_path = limine_bin.path(".");
    const target = b.standardTargetOptions(.{});

    const limine_exe = b.addExecutable(.{
        .name = "limine-deploy",
        .target = target,
        .optimize = .ReleaseSafe,
    });
    limine_exe.addCSourceFile(.{ .file = limine_bin.path("limine.c"), .flags = &[_][]const u8{"-std=c99"} });
    limine_exe.linkLibC();

    const limine_exe_run = b.addRunArtifact(limine_exe);

    const cmd = &[_][]const u8{
        // zig fmt: off
        "/bin/sh", "-c",
        try std.mem.concat(b.allocator, u8, &[_][]const u8{
            "mkdir -p zig-out/iso/root/EFI/BOOT && ",
            "cp zig-out/bin/kernel zig-out/iso/root && ",
            "cp build/limine.conf zig-out/iso/root && ",

            "cp ", limine_path.getPath(b), "/limine-bios.sys ",
                   limine_path.getPath(b), "/limine-bios-cd.bin ",
                   limine_path.getPath(b), "/limine-uefi-cd.bin ",
                   "zig-out/iso/root && ",

            "cp ", limine_path.getPath(b), "/BOOTX64.EFI ",
                   limine_path.getPath(b), "/BOOTAA64.EFI ",
                   limine_path.getPath(b), "/BOOTRISCV64.EFI ",
                   "zig-out/iso/root/EFI/BOOT && ",

            "xorriso -as mkisofs -R -r -J -b limine-bios-cd.bin ",
                "-no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus ",
                "-apm-block-size 2048 --efi-boot limine-uefi-cd.bin ",
                "-efi-boot-part --efi-boot-image --protective-msdos-label ",
                "zig-out/iso/root -o zig-out/iso/violet.iso"

        }),
        // zig fmt: on
    };

    const iso_cmd = b.addSystemCommand(cmd);
    iso_cmd.step.dependOn(b.getInstallStep());

    _ = limine_exe_run.addOutputFileArg("zig-out/iso/violet.iso");
    limine_exe_run.step.dependOn(&iso_cmd.step);

    return &iso_cmd.step;
}

fn edk2FileName(b: *std.Build, arch: std.Target.Cpu.Arch) ![]const u8 {
    return try std.mem.concat(b.allocator, u8, &[_][]const u8{ ".zig-cache/edk2-", @tagName(arch), ".fd" });
}

fn downloadEdk2(b: *std.Build, arch: std.Target.Cpu.Arch) !void {
    const link = switch (arch) {
        .x86_64 => "https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd",
        .aarch64 => "https://retrage.github.io/edk2-nightly/bin/RELEASEAARCH64_QEMU_EFI.fd",
        .riscv64 => "https://retrage.github.io/edk2-nightly/bin/RELEASERISCV64_VIRT_CODE.fd",
        else => return error.UnsupportedArchitecture,
    };

    const file_name = try edk2FileName(b, arch);

    {
        const cmd = &[_][]const u8{ "curl", link, "-Lo", file_name };
        var child_proc = std.process.Child.init(cmd, b.allocator);
        try child_proc.spawn();
        const ret_val = try child_proc.wait();
        try std.testing.expectEqual(ret_val, std.process.Child.Term { .Exited = 0 });
    }

    // dd if=/dev/zero of=OVMF.fd bs=1 count=0 seek=33554432
    if (arch == .riscv64) {
        const cmd = &[_][]const u8{ 
            "dd", 
            "if=/dev/zero", 
            b.fmt("of={s}", .{ file_name }),
            "bs=1",
            "count=0",
            "seek=33554432",
        };
        var child_proc = std.process.Child.init(cmd, b.allocator);
        try child_proc.spawn();
        const ret_val = try child_proc.wait();
        try std.testing.expectEqual(ret_val, std.process.Child.Term { .Exited = 0 });
    }

}

pub fn runIso(b: *std.Build, arch: std.Target.Cpu.Arch) !*std.Build.Step {
    _ = std.fs.cwd().statFile(try edk2FileName(b, arch)) catch try downloadEdk2(b, arch);

    const qemu_executable = switch (arch) {
        .x86_64 => "qemu-system-x86_64",
        .aarch64 => "qemu-system-aarch64",
        .riscv64 => "qemu-system-riscv64",
        else => return error.UnsupportedArchitecture,
    };

    const qemu_iso_args = switch (arch) {
        .x86_64 => &[_][]const u8{
            // zig fmt: off
            qemu_executable,
            "-cpu", "max",
            "-smp", "2",
            "-M", "q35,accel=kvm:whpx:hvf:tcg",
            "-m", "2G",
            "-cdrom", "zig-out/iso/violet.iso",
            "-bios", try edk2FileName(b, arch),
            "-boot", "d",
            "-serial", "stdio",
            "-no-reboot",
            "-no-shutdown",
            // zig fmt: on
        },
        .aarch64 => &[_][]const u8{
            // zig fmt: off
            qemu_executable,
            "-cpu", "max",
            "-smp", "2",
            "-M", "virt,accel=kvm:whpx:hvf:tcg",
            "-m", "2G",
            "-cdrom", "zig-out/iso/violet.iso",
            "-bios", try edk2FileName(b, arch),
            "-boot", "d",
            "-device", "ramfb",
            "-device", "qemu-xhci",
            "-device", "usb-kbd",
            "-serial", "stdio",
            "-no-reboot",
            "-no-shutdown",
            // zig fmt: on
        },
        .riscv64 => &[_][]const u8{
            // zig fmt: off
            qemu_executable,
            "-smp", "2",
            "-cpu", "rv64",
            "-M", "virt,accel=kvm:whpx:hvf:tcg",
            "-m", "2G",
            "-boot", "d",
            "-device", "ramfb",
            "-device", "qemu-xhci",
            "-device", "usb-kbd",
            "-drive", b.fmt("if=pflash,unit=0,format=raw,file={s}", .{try edk2FileName(b, arch)}),
            "-device", "virtio-scsi-pci,id=scsi",
            "-device", "scsi-cd,drive=cd0",
            "-drive", "id=cd0,format=raw,file=zig-out/iso/violet.iso",
            "-serial", "stdio",
            "-no-reboot",
            "-no-shutdown",
            // zig fmt: on
        },
        else => return error.UnsupportedArchitecture,
    };

    const qemu_iso_cmd = b.addSystemCommand(qemu_iso_args);
    return &qemu_iso_cmd.step;
}

const Device = enum(u8) {
    virt,
    q35,

    pub fn arch(self: Device) std.Target.Cpu.Arch {
        return switch (self) {
            .virt => .aarch64,
            .q35 => .x86_64,
        };
    }
};
