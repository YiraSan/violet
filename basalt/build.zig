const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("basalt_main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("basalt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}

pub fn addExecutable(b: *std.Build, options: ExecutableOptions) *std.Build.Step.Compile {
    const target_query = std.Target.Query{
        .cpu_arch = options.platform.arch(),
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
    };

    const target = b.resolveTargetQuery(target_query);

    const basalt = b.dependency("basalt", .{
        .target = target,
        .optimize = options.optimize,
    });
    const basalt_mod = basalt.module("basalt");
    const basalt_main_mod = basalt.module("basalt_main");

    const mod = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = target,
        .optimize = options.optimize,
    });

    mod.addImport("basalt", basalt_mod);
    basalt_main_mod.addImport("mod", mod);

    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = basalt_main_mod,
        .use_llvm = true,
    });

    exe.entry = .disabled;
    // TODO works only with 0.15+
    // exe.out_filename = b.fmt("{s}.elf", .{options.name});

    exe.setLinkerScript(basalt.path("linker.lds"));

    return exe;
}

pub const ExecutableOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    platform: Platform,
    optimize: std.builtin.OptimizeMode = .Debug,
};

pub const Platform = enum {
    aarch64_qemu,
    riscv64_qemu,

    rpi4,
    rpi3,

    pub fn arch(self: Platform) std.Target.Cpu.Arch {
        return switch (self) {
            .aarch64_qemu, .rpi4, .rpi3 => .aarch64,
            .riscv64_qemu => .riscv64,
        };
    }
};
