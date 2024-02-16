const std = @import("std");

const Arch = std.Target.Cpu.Arch;

// keep up to date with build.zig.zon !
const violet_version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

pub fn buildKernel(b: *std.Build, cpu_arch: Arch) !void {
    
    // dependencies

    const limine = b.dependency("limine", .{});

    // build kernel

    var target = std.zig.CrossTarget {
        .cpu_arch = cpu_arch,
        .os_tag = .freestanding,
        .abi = .none,
    };

    switch (target.cpu_arch.?) {
        .x86_64 => {
            const Features = std.Target.x86.Feature;
            target.cpu_features_sub.addFeature(@intFromEnum(Features.mmx));
            target.cpu_features_sub.addFeature(@intFromEnum(Features.sse));
            target.cpu_features_sub.addFeature(@intFromEnum(Features.sse2));
            target.cpu_features_sub.addFeature(@intFromEnum(Features.avx));
            target.cpu_features_sub.addFeature(@intFromEnum(Features.avx2));
            target.cpu_features_add.addFeature(@intFromEnum(Features.soft_float));
        },
        .aarch64 => {},
        else => return error.UnsupportedTarget,
    }

    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = "kernel/main.zig" },
        .target = b.resolveTargetQuery(target),
        .optimize = optimize,
        .code_model = switch (target.cpu_arch.?) {
            .aarch64 => .small,
            .x86_64 => .kernel,
            .riscv64 => .medium,
            else => return error.UnsupportedTarget,
        },
    });

    kernel.pie = true;

    kernel.setLinkerScriptPath(.{
        .path = switch (target.cpu_arch.?) {
            .aarch64 => "kernel/aarch64/kernel.ld",
            .x86_64 => "kernel/x86_64/kernel.ld",
            .riscv64 => "kernel/riscv64/kernel.ld",
            else => return error.UnsupportedArchitecture,
        },
    });

    kernel.root_module.addImport("limine", limine.module("limine"));

    b.installArtifact(kernel);

}

pub fn buildIso(b: *std.Build) !*std.Build.Step.Run {
    
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
            "cp limine.cfg zig-out/iso/root && ",
            "cp ", limine_path.getPath(b), "/limine-bios.sys ",
                   limine_path.getPath(b), "/limine-bios-cd.bin ",
                   limine_path.getPath(b), "/limine-uefi-cd.bin ",
                   "zig-out/iso/root && ",
            "cp ", limine_path.getPath(b), "/BOOTX64.EFI ",
                   limine_path.getPath(b), "/BOOTAA64.EFI ",
                   limine_path.getPath(b), "/BOOTRISCV64.EFI ",
                   "zig-out/iso/root/EFI/BOOT && ",
            "xorriso -as mkisofs -quiet -b limine-bios-cd.bin ",
                "-no-emul-boot -boot-load-size 4 -boot-info-table ",
                "--efi-boot limine-uefi-cd.bin ",
                "-efi-boot-part --efi-boot-image --protective-msdos-label ",
                "zig-out/iso/root -o zig-out/iso/violet.iso",
        }),
        // zig fmt: on
    };

    const iso_cmd = b.addSystemCommand(cmd);
    iso_cmd.step.dependOn(b.getInstallStep());

    _ = limine_exe_run.addOutputFileArg("violet.iso");
    limine_exe_run.step.dependOn(&iso_cmd.step);

    const iso_step = b.step("iso", "build a bootable iso");
    iso_step.dependOn(&limine_exe_run.step);

    return iso_cmd;

}

fn downloadEdk2(b: *std.Build, cpu_arch: Arch) !void {
    const link = switch (cpu_arch) {
        .x86_64 => "https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd",
        .aarch64 => "https://retrage.github.io/edk2-nightly/bin/RELEASEAARCH64_QEMU_EFI.fd",
        .riscv64 => "https://retrage.github.io/edk2-nightly/bin/RELEASERISCV64_VIRT.fd",
        else => return error.UnsupportedArchitecture,
    };

    const cmd = &[_][]const u8{ "curl", link, "-Lo", try edk2FileName(b, cpu_arch) };
    var child_proc = std.ChildProcess.init(cmd, b.allocator);
    try child_proc.spawn();
    const ret_val = try child_proc.wait();
    try std.testing.expectEqual(ret_val, std.ChildProcess.Term{ .Exited = 0 });
}

fn edk2FileName(b: *std.Build, cpu_arch: Arch) ![]const u8 {
    return std.mem.concat(b.allocator, u8, &[_][]const u8{ "zig-cache/edk2-", @tagName(cpu_arch), ".fd" });
}

fn runIsoQemu(b: *std.Build, iso: *std.Build.Step.Run, cpu_arch: Arch) !*std.Build.Step.Run {
    _ = std.fs.cwd().statFile(try edk2FileName(b, cpu_arch)) catch try downloadEdk2(b, cpu_arch);

    const qemu_executable = switch (cpu_arch) {
        .x86_64 => "qemu-system-x86_64",
        .aarch64 => "qemu-system-aarch64",
        .riscv64 => "qemu-system-riscv64",
        else => return error.UnsupportedArchitecture,
    };

    const qemu_iso_args = switch (cpu_arch) {
        .x86_64 => &[_][]const u8{
            // zig fmt: off
            "sudo",
            qemu_executable,
            "-cpu", "max",
            "-smp", "2",
            "-M", "q35,accel=kvm:whpx:hvf:tcg",
            "-m", "2G",
            "-cdrom", "zig-out/iso/violet.iso",
            "-bios", try edk2FileName(b, cpu_arch),
            "-boot", "d",
            "-serial", "stdio",
            "-no-reboot",
            "-no-shutdown",
            // zig fmt: on
        },
        .aarch64 => &[_][]const u8{
            // zig fmt: off
            "sudo",
            qemu_executable,
            "-cpu", "max",
            "-smp", "2",
            "-M", "virt,accel=kvm:whpx:hvf:tcg",
            "-m", "2G",
            "-cdrom", "zig-out/iso/violet.iso",
            "-bios", try edk2FileName(b, cpu_arch),
            "-boot", "d",
            "-device", "ramfb",
            "-serial", "stdio",
            "-no-reboot",
            "-no-shutdown",
            // zig fmt: on
        },
        else => return error.UnsupportedArchitecture,
    };

    const qemu_iso_cmd = b.addSystemCommand(qemu_iso_args);
    qemu_iso_cmd.step.dependOn(&iso.step);

    const qemu_iso_step = b.step("run", "Boot ISO in QEMU");
    qemu_iso_step.dependOn(&qemu_iso_cmd.step);

    return qemu_iso_cmd;
}


pub fn build(b: *std.Build) !void {

    const cpu_arch = b.option(Arch, "arch", "target architecture") orelse .x86_64;

    try buildKernel(b, cpu_arch);
    _ = try runIsoQemu(b, try buildIso(b), cpu_arch);

}
