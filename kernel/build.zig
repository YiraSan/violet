const std = @import("std");

pub fn build(b: *std.Build) void {

    const device = 
        b.option(Device, "device", "target device")
        orelse unreachable;
    
    var target_query = b.standardTargetOptionsQueryOnly(.{});
    target_query.cpu_arch = device.arch();
    target_query.os_tag = .freestanding;
    target_query.abi = .none;

    switch (target_query.cpu_arch.?) {
        .x86_64 => {
            const Features = std.Target.x86.Feature;
            target_query.cpu_features_sub.addFeature(@intFromEnum(Features.mmx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Features.sse));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Features.sse2));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Features.avx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Features.avx2));
            target_query.cpu_features_add.addFeature(@intFromEnum(Features.soft_float));
        },
        .aarch64 => {},
        .riscv64 => {},
        else => unreachable,
    }

    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = switch (target.result.cpu.arch) {
            .aarch64 => .small,
            .x86_64 => .kernel,
            .riscv64 => .medium,
            else => unreachable,
        },
    });

    kernel.pie = true;
    kernel.want_lto = false;

    kernel.root_module.stack_protector = false;
    kernel.root_module.stack_check = false;
    kernel.root_module.red_zone = false;

    kernel.setLinkerScript(switch (target.result.cpu.arch) {
        .aarch64 => b.path("build/aarch64.ld"),
        .x86_64 => b.path("build/x86_64.ld"),
        .riscv64 => b.path("build/riscv64.ld"),
        else => unreachable,
    });

    kernel.addAssemblyFile(b.path("src/arch/aarch64/vector_table.s"));

    const build_options = b.addOptions();
    build_options.addOption(Device, "device", device);
    kernel.root_module.addOptions("build_options", build_options);

    b.installArtifact(kernel);

}

const Device = enum(u8) {
    virt,
    raspi4b,
    q35,

    pub fn arch(self: Device) std.Target.Cpu.Arch {
        return switch (self) {
            .virt, .raspi4b => .aarch64,
            .q35 => .x86_64,
        };
    }
};
