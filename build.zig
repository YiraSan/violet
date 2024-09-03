const std = @import("std");

const Arch = std.Target.Cpu.Arch;

// keep up to date with build.zig.zon !
const violet_version = std.SemanticVersion {
    .major = 0,
    .minor = 1,
    .patch = 0,
};

const Device = enum {
    qemu,
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
        // .riscv64 => {},
        else => return error.UnsupportedTarget,
    }

    const optimize = b.standardOptimizeOption(.{});
    const exe_options = b.addOptions();

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("kernel/kernel.zig"),
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
    kernel.root_module.stack_protector = false;
    kernel.root_module.stack_check = false;
    kernel.root_module.red_zone = false;
    kernel.want_lto = false;

    kernel.setLinkerScriptPath(switch (target.cpu_arch.?) {
        .aarch64 => b.path("kernel/arch/linker-aarch64.ld"),
        .x86_64 => b.path("kernel/arch/linker-x86_64.ld"),
        // .riscv64 => b.path("kernel/arch/linker-riscv64.ld"),
        else => unreachable,
    });

    // From https://github.com/zigtools/zls
    const version = v: {
        const version_string = b.fmt("{d}.{d}.{d}", .{ violet_version.major, violet_version.minor, violet_version.patch });
        const build_root_path = b.build_root.path orelse ".";

        var code: u8 = undefined;
        const git_describe_untrimmed = b.runAllowFail(&[_][]const u8{
            "git", "-C", build_root_path, "describe", "--match", "*.*.*", "--tags",
        }, &code, .Ignore) catch break :v version_string;

        const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");

        switch (std.mem.count(u8, git_describe, "-")) {
            0 => {
                // Tagged release version (e.g. 0.10.0).
                std.debug.assert(std.mem.eql(u8, git_describe, version_string)); // tagged release must match version string
                break :v version_string;
            },
            2 => {
                // Untagged development build (e.g. 0.10.0-dev.216+34ce200).
                var it = std.mem.split(u8, git_describe, "-");
                const tagged_ancestor = it.first();
                const commit_height = it.next().?;
                const commit_id = it.next().?;

                const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
                std.debug.assert(violet_version.order(ancestor_ver) == .gt); // version must be greater than its previous version
                std.debug.assert(std.mem.startsWith(u8, commit_id, "g")); // commit hash is prefixed with a 'g'

                break :v b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
            },
            else => {
                std.debug.print("Unexpected 'git describe' output: '{s}'\n", .{git_describe});
                std.process.exit(1);
            },
        }
    };

    exe_options.addOption([:0]const u8, "version", b.allocator.dupeZ(u8, version) catch "0.1.0-dev");
    exe_options.addOption(Device, "device", .qemu);
    kernel.root_module.addOptions("build_options", exe_options);
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
            "cp kernel/boot/limine.conf zig-out/iso/root && ",
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
        // .riscv64 => "https://retrage.github.io/edk2-nightly/bin/RELEASERISCV64_VIRT_CODE.fd",
        else => return error.UnsupportedArchitecture,
    };

    {
        const cmd = &[_][]const u8{ "curl", link, "-Lo", try edk2FileName(b, cpu_arch) };
        var child_proc = std.process.Child.init(cmd, b.allocator);
        try child_proc.spawn();
        const ret_val = try child_proc.wait();
        std.debug.print("{}", .{ret_val});
        try std.testing.expectEqual(ret_val, std.process.Child.Term{ .Exited = 0 });
    }

    // dd if=/dev/zero of=OVMF.fd bs=1 count=0 seek=33554432
    if (cpu_arch == .riscv64) {
        const cmd = &[_][]const u8{ 
            "dd", 
            "if=/dev/zero", 
            b.fmt("of={s}", .{try edk2FileName(b, cpu_arch)}),
            "bs=1",
            "count=0",
            "seek=33554432",
        };
        var child_proc = std.process.Child.init(cmd, b.allocator);
        try child_proc.spawn();
        const ret_val = try child_proc.wait();
        try std.testing.expectEqual(ret_val, std.process.Child.Term{ .Exited = 0 });
    }

}

fn edk2FileName(b: *std.Build, cpu_arch: Arch) ![]const u8 {
    return std.mem.concat(b.allocator, u8, &[_][]const u8{ ".zig-cache/edk2-", @tagName(cpu_arch), ".fd" });
}

fn runIsoQemu(b: *std.Build, iso: *std.Build.Step.Run, cpu_arch: Arch) !*std.Build.Step.Run {
    _ = std.fs.cwd().statFile(try edk2FileName(b, cpu_arch)) catch try downloadEdk2(b, cpu_arch);

    const qemu_executable = switch (cpu_arch) {
        .x86_64 => "qemu-system-x86_64",
        .aarch64 => "qemu-system-aarch64",
        // .riscv64 => "qemu-system-riscv64",
        else => return error.UnsupportedArchitecture,
    };

    const qemu_iso_args = switch (cpu_arch) {
        .x86_64 => &[_][]const u8 {
            // zig fmt: off
            qemu_executable,
            "-cpu", "max",
            "-smp", "4",
            "-M", "q35,accel=kvm:whpx:hvf:tcg",
            "-m", "2G",
            "-cdrom", "zig-out/iso/violet.iso",
            "-bios", try edk2FileName(b, cpu_arch),
            "-boot", "d",
            "-serial", "stdio",
            "-no-reboot",
            "-no-shutdown"
            // zig fmt: on
        },
        .aarch64 => &[_][]const u8 {
            // zig fmt: off
            qemu_executable,
            "-cpu", "max",
            "-smp", "4",
            "-M", "virt,accel=kvm:whpx:hvf:tcg",
            "-m", "2G",
            "-cdrom", "zig-out/iso/violet.iso",
            "-bios", try edk2FileName(b, cpu_arch),
            "-boot", "d",
            "-device", "ramfb",
            "-device", "qemu-xhci",
            "-device", "usb-kbd",
            "-serial", "stdio",
            "-no-reboot",
            "-no-shutdown",
            // zig fmt: on
        },
        // .riscv64 => &[_][]const u8 {
        //     // zig fmt: off
        //     qemu_executable,
        //     "-smp", "4",
        //     "-cpu", "rv64",
        //     "-M", "virt,accel=kvm:whpx:hvf:tcg",
        //     "-m", "2G",
        //     "-boot", "d",
        //     "-device", "ramfb",
        //     "-device", "qemu-xhci",
        //     "-device", "usb-kbd",
        //     "-drive", b.fmt("if=pflash,unit=0,format=raw,file={s}", .{try edk2FileName(b, cpu_arch)}),
        //     "-device", "virtio-scsi-pci,id=scsi",
        //     "-device", "scsi-cd,drive=cd0",
        //     "-drive", "id=cd0,format=raw,file=zig-out/iso/violet.iso",
        //     "-serial", "stdio",
        //     "-no-reboot",
        //     "-no-shutdown",
        //     // zig fmt: on
        // },
        else => return error.UnsupportedArchitecture,
    };

    const qemu_iso_cmd = b.addSystemCommand(qemu_iso_args);
    qemu_iso_cmd.step.dependOn(&iso.step);

    const qemu_iso_step = b.step("run", "Boot ISO in QEMU");
    qemu_iso_step.dependOn(&qemu_iso_cmd.step);

    return qemu_iso_cmd;
}

const Board = enum {
    qemu,
};

pub fn build(b: *std.Build) !void {

    const cpu_arch = b.option(Arch, "arch", "target architecture") orelse .x86_64;

    try buildKernel(b, cpu_arch);
    _ = try runIsoQemu(b, try buildIso(b), cpu_arch);

}
