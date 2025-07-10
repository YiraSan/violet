const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    _ = b.addModule("basalt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
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
    });
    const basalt_mod = basalt.module("basalt");

    const mod = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = target,
        .optimize = options.optimize,
    });

    mod.addImport("basalt", basalt_mod);
    basalt_mod.addImport("mod", mod);

    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = basalt_mod,
        .use_llvm = true,
    });

    exe.pie = true;
    exe.entry = .disabled;
    exe.out_filename = b.fmt("{s}.elf", .{options.name});

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
    q35,
    virt,
    raspi4b,

    pub fn arch(self: Platform) std.Target.Cpu.Arch {
        return switch (self) {
            .q35 => .x86_64,
            .virt => .aarch64,
            .raspi4b => .aarch64,
        };
    }
};
